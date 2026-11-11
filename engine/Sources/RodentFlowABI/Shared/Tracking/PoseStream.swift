// PoseStream.swift — pose keypoints written to disk while the model runs (Mac long-video runs).
//
// A run folder holds
//   pose_stream.json        PoseStreamManifest: video fingerprint, model, settings, finished segments
//   segment_000000.csv …    one row per analysed frame, in segments of `segmentSeconds` of video
//   segment_00000N.csv.partial   the segment being written (rows are appended and flushed every
//                           ~2 s, so a crash, power cut or force quit loses at most the last seconds)
//   pose.mpt                the finished PoseTrack (same file the iPhone / iPad writes), written once
//                           every frame is analysed and — with two animals — A / B were resolved over
//                           the whole video (IdentityResolver)
//
// A stopped or crashed run continues where it stopped: finished segments are kept, the complete
// rows of the partial segment are kept (a half-written last line is dropped), and with two animals
// the identity tracker is re-seeded with the last written frame.
//
// Rows hold the online tracker's order (as the phone's track before IdentityResolver); keypoints
// are written with the shortest text that reads back as the same Float, so `pose.mpt` assembled
// from the rows is bit-identical to the track the run computed.
//
// Foundation only (tested on the command line).

import Foundation

struct PoseStreamManifest: Codable, Equatable {
    static let fileName = "pose_stream.json"
    static let currentFormat = 3
    static let poseFileName = "pose.mpt"

    struct Segment: Codable, Equatable {
        var index: Int
        var file: String
        var records: Int
        var firstTime: Double
        var lastTime: Double
        /// Frames where the model failed twice (written as "no animal", flagged in the row).
        var failedFrames: Int
    }

    var format = PoseStreamManifest.currentFormat
    var sourceFile: String
    var sourceSize: UInt64
    var sourceModification: Double
    var sourceFingerprint: String
    var modelName: String
    var animalCount: Int
    var appearanceDims: Int
    /// Model settings of the run (stride, grayscale, time range, tracked region).
    var settings: InferenceSettings
    /// The region given to the model (normalized upright frame; nil = whole frame).
    var roi: NRect?
    var fps: Double
    var frameWidth: Double
    var frameHeight: Double
    var videoDuration: Double
    var segmentSeconds: Double
    /// Scale at which the frames were decoded (PoseFrame.decodeScale, e.g. 0.39 for a 4K region); nil = full
    /// size. Folders written before the Mac used reduced decoding have none and are continued at full size, so
    /// one run never mixes two decode sizes. Not part of `continues`.
    var decodeScale: Double?
    /// Frame number of the first decoded frame (its time × fps); frame numbers count every decoded frame.
    var frameOffset: Int?
    var completed: [Segment] = []
    /// Every frame of the range was analysed and pose.mpt was written.
    var finished = false
    var startedAt: Date = Date()
    var finishedAt: Date?

    var recordCount: Int { completed.reduce(0) { $0 + $1.records } }
    var failedCount: Int { completed.reduce(0) { $0 + $1.failedFrames } }

    static func segmentName(_ index: Int) -> String { String(format: "segment_%06d.csv", index) }
    static func partialName(_ index: Int) -> String { segmentName(index) + ".partial" }

    static func load(_ folder: URL) throws -> PoseStreamManifest {
        // Dates in the default (exact) encoding, so a manifest compares equal after reading it back.
        try JSONDecoder().decode(PoseStreamManifest.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }

    func save(to folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The same video, model and model settings (a folder can only be continued by the same run).
    func continues(_ o: PoseStreamManifest) -> Bool {
        format == o.format && sourceFile == o.sourceFile && sourceSize == o.sourceSize
            && sourceModification == o.sourceModification && sourceFingerprint == o.sourceFingerprint
            && modelName == o.modelName && animalCount == o.animalCount && appearanceDims == o.appearanceDims
            && settings.sameModelSettings(as: o.settings) && roi == o.roi
            && abs(segmentSeconds - o.segmentSeconds) < 1e-9 && abs(videoDuration - o.videoDuration) < 0.001
    }
}

enum PoseStreamFormat {
    struct Row: Equatable {
        var frame: Int
        var time: Double
        var failed: Bool
        var poses: [AnimalPose]
        var appearance: [[Float]]

        static func == (a: Row, b: Row) -> Bool {
            guard a.frame == b.frame, a.time == b.time, a.failed == b.failed, a.poses.count == b.poses.count else { return false }
            for (p, q) in zip(a.poses, b.poses) {
                if p.detected != q.detected { return false }
                if p.detected && (p.conf != q.conf || p.x != q.x || p.y != q.y || p.kconf != q.kconf) { return false }
            }
            guard a.appearance.count == b.appearance.count else { return false }
            for (u, v) in zip(a.appearance, b.appearance) {
                guard u.count == v.count else { return false }
                for (x, y) in zip(u, v) where !(x == y || (x.isNaN && y.isNaN)) { return false }
            }
            return true
        }
    }

    enum ReadError: LocalizedError {
        case badHeader(String)
        var errorDescription: String? {
            switch self {
            case .badHeader(let f): return "Unexpected columns in " + f
            }
        }
    }

    static func animalPrefix(_ a: Int, count: Int) -> String {
        count > 2 ? "m\(a + 1)_" : (count > 1 ? (a == 0 ? "A_" : "B_") : "")
    }

    static func header(animalCount n: Int, appearanceDims d: Int) -> String {
        var cols = ["frame", "time_s", "inference_failed"]
        for a in 0..<n {
            let p = animalPrefix(a, count: n)
            cols.append(p + "conf")
            for name in kKeypointNames { cols += [p + name + "_x", p + name + "_y", p + name + "_conf"] }
        }
        for a in 0..<n where d > 0 {
            for k in 0..<d { cols.append(animalPrefix(a, count: n) + "appearance_\(k)") }
        }
        return cols.joined(separator: ",") + "\n"
    }

    static func columnCount(animalCount n: Int, appearanceDims d: Int) -> Int {
        3 + n * (1 + 3 * kKeypointCount) + n * d
    }

    /// Shortest decimal text that reads back as the same Float.
    @inline(__always) private static func text(_ v: Float) -> String { v.isFinite ? "\(v)" : "" }

    static func row(frame: Int, time: Double, failed: Bool, poses: [AnimalPose], appearance: [[Float]],
                    animalCount n: Int, appearanceDims d: Int) -> String {
        var s = String(frame) + "," + "\(time)" + "," + (failed ? "1" : "0")
        for a in 0..<n {
            let p = a < poses.count ? poses[a] : .missing
            if p.detected {
                s += "," + text(p.conf)
                for k in 0..<kKeypointCount { s += "," + text(p.x[k]) + "," + text(p.y[k]) + "," + text(p.kconf[k]) }
            } else {
                s += ",0" + String(repeating: ",,,", count: kKeypointCount)
            }
        }
        if d > 0 {
            for a in 0..<n {
                let v = a < appearance.count && appearance[a].count == d ? appearance[a] : []
                for k in 0..<d { s += "," + (k < v.count ? text(v[k]) : "") }
            }
        }
        return s + "\n"
    }

    static func parse(_ line: Substring, animalCount n: Int, appearanceDims d: Int) -> Row? {
        let c = line.split(separator: ",", omittingEmptySubsequences: false)
        guard c.count == columnCount(animalCount: n, appearanceDims: d),
              let frame = Int(c[0]), let time = Double(c[1]) else { return nil }
        var poses: [AnimalPose] = []
        var i = 3
        for _ in 0..<n {
            let conf = Float(c[i]) ?? 0
            var p = AnimalPose.missing
            if conf > 0 {
                p.conf = conf
                for k in 0..<kKeypointCount {
                    p.x[k] = Float(c[i + 1 + 3 * k]) ?? 0
                    p.y[k] = Float(c[i + 2 + 3 * k]) ?? 0
                    p.kconf[k] = Float(c[i + 3 + 3 * k]) ?? 0
                }
            }
            poses.append(p)
            i += 1 + 3 * kKeypointCount
        }
        var appearance: [[Float]] = []
        if d > 0 {
            for _ in 0..<n {
                appearance.append((0..<d).map { Float(c[i + $0]) ?? .nan })
                i += d
            }
        }
        return Row(frame: frame, time: time, failed: c[2] == "1", poses: poses, appearance: appearance)
    }

    /// Complete rows of a segment file (a half-written last line is ignored) and the byte length of
    /// those complete lines (header included).
    static func read(_ url: URL, animalCount n: Int, appearanceDims d: Int) throws -> (rows: [Row], validBytes: Int) {
        let data = try Data(contentsOf: url)
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], 0) }
        let valid = data.prefix(through: lastNewline)
        let text = String(decoding: valid, as: UTF8.self)
        var rows: [Row] = []
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if first {
                first = false
                guard line + "\n" == header(animalCount: n, appearanceDims: d) else { throw ReadError.badHeader(url.lastPathComponent) }
                continue
            }
            if let r = parse(line, animalCount: n, appearanceDims: d) { rows.append(r) }
        }
        return (rows, valid.count)
    }

    // MARK: Resume

    /// Where an interrupted run continues: the partial segment (complete rows only) and the last row
    /// written anywhere (to re-seed the identity tracker and skip frames already done).
    struct ResumePoint {
        var partialIndex: Int?
        var partialRows: Int = 0
        var partialFailed: Int = 0
        var partialFirstTime: Double?
        var partialValidBytes: Int = 0
        var lastRow: Row?
    }

    static func resumePoint(_ m: PoseStreamManifest, folder: URL) throws -> ResumePoint {
        var out = ResumePoint()
        let done = Set(m.completed.map(\.index))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let partials = names.compactMap { name -> Int? in
            guard name.hasPrefix("segment_"), name.hasSuffix(".csv.partial") else { return nil }
            return Int(name.dropFirst("segment_".count).prefix(6))
        }.filter { !done.contains($0) && $0 > (m.completed.map(\.index).max() ?? -1) }.sorted()
        if let index = partials.last {
            let r = try read(folder.appendingPathComponent(PoseStreamManifest.partialName(index)),
                             animalCount: m.animalCount, appearanceDims: m.appearanceDims)
            out.partialIndex = index
            out.partialRows = r.rows.count
            out.partialFailed = r.rows.filter(\.failed).count
            out.partialFirstTime = r.rows.first?.time
            out.partialValidBytes = r.validBytes
            out.lastRow = r.rows.last
        }
        if out.lastRow == nil, let last = m.completed.max(by: { $0.index < $1.index }) {
            out.lastRow = try read(folder.appendingPathComponent(last.file), animalCount: m.animalCount,
                                   appearanceDims: m.appearanceDims).rows.last
        }
        return out
    }

    // MARK: Assembly

    /// The whole run as a PoseTrack (rows of every finished segment, in order), before identity resolution.
    static func assemble(_ m: PoseStreamManifest, folder: URL) throws -> PoseTrack {
        var track = PoseTrack(animalCount: m.animalCount, fps: m.fps, frameWidth: m.frameWidth, frameHeight: m.frameHeight,
                              frameStride: m.settings.stride, appearanceDims: m.appearanceDims)
        track.reserveCapacity(additionalFrames: m.recordCount)
        var last = -Double.infinity
        for seg in m.completed.sorted(by: { $0.index < $1.index }) {
            let rows = try read(folder.appendingPathComponent(seg.file), animalCount: m.animalCount,
                                appearanceDims: m.appearanceDims).rows
            for r in rows where r.time > last {
                track.append(frame: r.frame, time: r.time, animals: r.poses, appearance: r.appearance)
                last = r.time
            }
        }
        track.processedUntil = track.time.last ?? 0
        return track
    }
}
