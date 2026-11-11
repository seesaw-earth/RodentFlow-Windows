// PoseTrack.swift — per-frame keypoints for one session (1 or 2 animals), compact binary storage
// and the raw keypoint CSV (same columns as MousePose 1.0 for a single animal).

import Foundation

/// Detections at or below this score are stored only for two-animal identity (low-score matches
/// that continue an animal already tracked); the analysis ignores them, as it always has.
let kAnalysisMinScore: Float = 0.25

/// One animal's detection in one frame: box confidence and 6 × (x px, y px, conf).
struct AnimalPose {
    var conf: Float
    var x: [Float]
    var y: [Float]
    var kconf: [Float]

    static let missing = AnimalPose(conf: 0, x: [Float](repeating: 0, count: kKeypointCount),
                                    y: [Float](repeating: 0, count: kKeypointCount),
                                    kconf: [Float](repeating: 0, count: kKeypointCount))

    var detected: Bool { conf > 0 && x.count == kKeypointCount && kconf.count == kKeypointCount }

    /// Mean of keypoint positions with confidence above `minConf` (used for identity matching).
    func centroid(minConf: Float = 0.3) -> V2? {
        guard detected else { return nil }
        var sx = 0.0, sy = 0.0, n = 0.0
        for k in 0..<kKeypointCount where kconf[k] >= minConf {
            sx += Double(x[k]); sy += Double(y[k]); n += 1
        }
        return n > 0 ? V2(sx / n, sy / n) : nil
    }
}

struct PoseTrack {
    static let stride = kKeypointCount * 3

    var animalCount: Int
    var fps: Double
    var frameWidth: Double
    var frameHeight: Double
    var frameStride: Int
    var frameIndex: [Int32] = []
    var time: [Double] = []
    /// Box confidence per frame per animal (0 = not detected).
    var detConf: [Float] = []
    /// Per frame, per animal: 6 × (x, y, conf), pixel coordinates of the upright frame.
    var kp: [Float] = []
    var processedUntil: Double = 0
    var complete = false
    var msPerFrame: Double = 0
    /// Per frame: `IdentityFlag` bits (two-animal mode; always 0 for one animal).
    var flags: [UInt8] = []
    /// Floats per animal per frame in `appearance` (0 = not recorded).
    var appearanceDims = 0
    /// Per frame, per animal: fur-colour descriptor used only to tell two animals apart (NaN = not read).
    var appearance: [Float] = []
    /// Result of the whole-video identity pass (nil = not run, e.g. files from older versions).
    var identity: IdentityInfo?

    init(animalCount: Int, fps: Double, frameWidth: Double, frameHeight: Double, frameStride: Int, appearanceDims: Int = 0) {
        self.animalCount = max(1, animalCount)
        self.fps = fps
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.frameStride = max(1, frameStride)
        self.appearanceDims = max(0, appearanceDims)
    }

    var count: Int { time.count }
    var frameSize: V2 { V2(frameWidth, frameHeight) }
    var lastFrameIndex: Int { frameIndex.last.map(Int.init) ?? -1 }

    // MARK: Access

    func conf(_ i: Int, _ a: Int = 0) -> Float { detConf[i * animalCount + a] }

    func pose(_ i: Int, _ a: Int = 0) -> AnimalPose {
        let base = (i * animalCount + a) * PoseTrack.stride
        var xs = [Float](repeating: 0, count: kKeypointCount)
        var ys = xs, cs = xs
        for k in 0..<kKeypointCount {
            xs[k] = kp[base + k * 3]
            ys[k] = kp[base + k * 3 + 1]
            cs[k] = kp[base + k * 3 + 2]
        }
        return AnimalPose(conf: conf(i, a), x: xs, y: ys, kconf: cs)
    }

    /// Raw pixel position and confidence of keypoint `k`.
    @inline(__always)
    func point(_ i: Int, _ a: Int, _ k: Int) -> (x: Float, y: Float, c: Float) {
        let base = (i * animalCount + a) * PoseTrack.stride + k * 3
        return (kp[base], kp[base + 1], kp[base + 2])
    }

    /// Avoids repeated reallocation of the growing arrays during a long run.
    mutating func reserveCapacity(additionalFrames n: Int) {
        let total = count + max(0, n)
        frameIndex.reserveCapacity(total)
        time.reserveCapacity(total)
        detConf.reserveCapacity(total * animalCount)
        kp.reserveCapacity(total * animalCount * PoseTrack.stride)
        flags.reserveCapacity(total)
        appearance.reserveCapacity(total * animalCount * appearanceDims)
    }

    /// `appearance`: one descriptor per animal (ignored when this track records none).
    mutating func append(frame: Int, time t: Double, animals: [AnimalPose], appearance app: [[Float]] = [], flags f: UInt8 = 0) {
        if flags.count != count { flags = [UInt8](repeating: 0, count: count) }
        frameIndex.append(Int32(clamping: frame))
        time.append(t)
        flags.append(f)
        for a in 0..<animalCount {
            let p = a < animals.count ? animals[a] : AnimalPose.missing
            let ok = p.detected
            detConf.append(ok ? p.conf : 0)
            for k in 0..<kKeypointCount {
                kp.append(ok ? p.x[k] : 0)
                kp.append(ok ? p.y[k] : 0)
                kp.append(ok ? p.kconf[k] : 0)
            }
            if appearanceDims > 0 {
                let v = ok && a < app.count && app[a].count == appearanceDims ? app[a] : [Float](repeating: .nan, count: appearanceDims)
                appearance.append(contentsOf: v)
            }
        }
    }

    /// Exchanges the stored data of animals 0 and 1 in frame `i`.
    mutating func swapAnimals(at i: Int) {
        guard animalCount == 2, i >= 0, i < count else { return }
        detConf.swapAt(2 * i, 2 * i + 1)
        let b0 = 2 * i * PoseTrack.stride, b1 = (2 * i + 1) * PoseTrack.stride
        for k in 0..<PoseTrack.stride { kp.swapAt(b0 + k, b1 + k) }
        let d = appearanceDims
        if d > 0, appearance.count >= (2 * i + 2) * d {
            for k in 0..<d { appearance.swapAt(2 * i * d + k, (2 * i + 1) * d + k) }
        }
    }

    /// Poses of frame `i` in the online tracker's order (stored A / B swaps undone).
    func trackerOrderPoses(_ i: Int) -> [AnimalPose] {
        var poses = (0..<animalCount).map { pose(i, $0) }
        if animalCount == 2, i < flags.count, flags[i] & IdentityFlag.swapped != 0 { poses.swapAt(0, 1) }
        return poses
    }

    @inline(__always)
    func flag(_ i: Int, _ bit: UInt8) -> Bool { i < flags.count && flags[i] & bit != 0 }

    /// Index of the processed frame closest to time `t` (binary search).
    func nearestIndex(to t: Double) -> Int? {
        guard !time.isEmpty else { return nil }
        var lo = 0, hi = time.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if time[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 && abs(time[lo - 1] - t) < abs(time[lo] - t) { return lo - 1 }
        return lo
    }

    // MARK: Summary

    func summary() -> PoseSummary {
        var s = PoseSummary()
        s.frames = count
        s.animalCount = animalCount
        var detected = 0
        var confSum = 0.0, confN = 0.0
        for i in 0..<count {
            var any = false
            for a in 0..<animalCount where conf(i, a) > kAnalysisMinScore {
                any = true
                confSum += Double(conf(i, a))
                confN += 1
            }
            if any { detected += 1 }
        }
        s.detectedFrames = detected
        s.meanConfidence = confN > 0 ? confSum / confN : 0
        s.msPerFrame = msPerFrame
        s.processedUntil = processedUntil
        s.complete = complete
        return s
    }

    // MARK: Binary storage

    // "MPT2": header, frame indices, times, detection confidences, keypoints.
    // "MPT3": the same, then identity flags (UInt8 per frame) and appearance descriptors.
    private struct Header: Codable {
        var version = 3
        var animalCount: Int
        var fps: Double
        var frameWidth: Double
        var frameHeight: Double
        var frameStride: Int
        var count: Int
        var processedUntil: Double
        var complete: Bool
        var msPerFrame: Double
        var appearanceDims: Int?
        var identity: IdentityInfo?
    }

    enum StorageError: LocalizedError {
        case badFile
        var errorDescription: String? { L10n.tr("姿态数据文件已损坏或版本不兼容") }
    }

    func encoded() throws -> Data {
        let dims = appearance.count == count * animalCount * appearanceDims ? appearanceDims : 0
        let header = Header(animalCount: animalCount, fps: fps, frameWidth: frameWidth, frameHeight: frameHeight,
                            frameStride: frameStride, count: count, processedUntil: processedUntil,
                            complete: complete, msPerFrame: msPerFrame, appearanceDims: dims, identity: identity)
        let h = try JSONEncoder().encode(header)
        var data = Data("MPT3".utf8)
        var len = UInt32(h.count).littleEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(h)
        frameIndex.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        time.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        detConf.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        kp.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        let f = flags.count == count ? flags : [UInt8](repeating: 0, count: count)
        f.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        if dims > 0 { appearance.withUnsafeBufferPointer { data.append(Data(buffer: $0)) } }
        return data
    }

    static func decode(_ data: Data) throws -> PoseTrack {
        guard data.count >= 8 else { throw StorageError.badFile }
        let magic = String(decoding: data.prefix(4), as: UTF8.self)
        guard magic == "MPT2" || magic == "MPT3" else { throw StorageError.badFile }
        var len: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &len) { data.copyBytes(to: $0, from: data.startIndex + 4 ..< data.startIndex + 8) }
        let hl = Int(UInt32(littleEndian: len))
        var offset = data.startIndex + 8
        guard data.endIndex - offset >= hl else { throw StorageError.badFile }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: offset ..< offset + hl))
        offset += hl
        let n = header.count, a = max(1, header.animalCount)

        func read<T>(_ count: Int, _ type: T.Type) throws -> [T] {
            let bytes = count * MemoryLayout<T>.stride
            guard bytes >= 0, data.endIndex - offset >= bytes else { throw StorageError.badFile }
            let out = [T](unsafeUninitializedCapacity: count) { buf, initialized in
                let raw = UnsafeMutableRawBufferPointer(buf)
                data.copyBytes(to: raw, from: offset ..< offset + bytes)
                initialized = count
            }
            offset += bytes
            return out
        }

        let dims = magic == "MPT3" ? max(0, header.appearanceDims ?? 0) : 0
        var t = PoseTrack(animalCount: a, fps: header.fps, frameWidth: header.frameWidth, frameHeight: header.frameHeight,
                          frameStride: header.frameStride, appearanceDims: dims)
        t.frameIndex = try read(n, Int32.self)
        t.time = try read(n, Double.self)
        t.detConf = try read(n * a, Float.self)
        t.kp = try read(n * a * PoseTrack.stride, Float.self)
        if magic == "MPT3" {
            t.flags = try read(n, UInt8.self)
            if dims > 0 { t.appearance = try read(n * a * dims, Float.self) }
            t.identity = header.identity
        } else {
            t.flags = [UInt8](repeating: 0, count: n)
        }
        t.processedUntil = header.processedUntil
        t.complete = header.complete
        t.msPerFrame = header.msPerFrame
        return t
    }

    // MARK: Raw keypoint CSV

    /// `frame,time_s,det_conf,<kp>_x,<kp>_y,<kp>_conf…` — pixel coordinates of the upright frame,
    /// origin top-left. Two animals: columns prefixed `m1_` / `m2_`.
    func rawCSV() -> Data {
        var header = ["frame", "time_s"]
        for a in 0..<animalCount {
            let pre = animalCount > 1 ? "m\(a + 1)_" : ""
            header.append("\(pre)det_conf")
            for n in kKeypointNames { header += ["\(pre)\(n)_x", "\(pre)\(n)_y", "\(pre)\(n)_conf"] }
        }
        var w = ByteWriter(capacity: (count + 1) * header.count * 7)
        w.row(header)
        for i in 0..<count {
            w.write(String(frameIndex[i])); w.comma()
            w.write(FastFormat.fixed(time[i], 3))
            for a in 0..<animalCount {
                let c = conf(i, a)
                w.comma(); w.write(FastFormat.fixed(Double(c), 3))
                for k in 0..<kKeypointCount {
                    if c > 0 {
                        let p = point(i, a, k)
                        w.comma(); w.write(FastFormat.fixed(Double(p.x), 1))
                        w.comma(); w.write(FastFormat.fixed(Double(p.y), 1))
                        w.comma(); w.write(FastFormat.fixed(Double(p.c), 3))
                    } else {
                        w.comma(); w.comma(); w.comma()
                    }
                }
            }
            w.newline()
        }
        return w.data
    }
}

// Identity assignment for two animals: see IdentityTracking.swift.
