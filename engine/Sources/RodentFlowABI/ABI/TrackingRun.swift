// TrackingRun.swift — one pose run over one video, driven frame by frame by the host app.
//
// This is the Mac app's `PoseStreamEngine.run` (macOS/.../Core/PoseStreamEngine.swift) turned
// inside out: there, one Swift function owns the loop and pulls frames from AVFoundation; here the
// host app (C#) owns the loop — it decodes the video and runs ONNX Runtime — and pushes each
// frame's raw model output in. Everything after the model is unchanged shared code:
//
//   host: decode → upright → crop to ROI → grayscale → letterbox 960 → ONNX
//   here: PoseDecoding.decode → ArenaROI.uncrop → OnlineIdentityTracker / GroupIdentityTracker
//         → AppearanceSampler → PoseStreamFormat.row → segment files → manifest
//         → PoseStreamFormat.assemble → IdentityResolver → pose.mpt
//
// So the run folder a Windows run writes has the same layout, the same CSV rows and the same
// pose.mpt as a Mac run (PoseStream.swift), and the frame-skipping, resume and failure rules stay
// in one place.
//
// Not thread-safe: one instance per run, called from one thread (as on the Mac).

import Foundation

final class TrackingRun {
    /// Video seconds per segment file. Same as the Mac (`PoseStreamEngine.segmentSeconds`).
    static let segmentSeconds: Double = 60
    static let flushSeconds: Double = 2
    static let flushBytes = 64 * 1024
    /// UltralyticsYOLO defaults, as `DirectPoseModel` uses them.
    static let defaultConfidence: Float = 0.25
    static let maxDetections = 30

    // MARK: Request

    struct Request: Decodable {
        /// File name only (stored in the manifest, as on the Mac).
        var videoName: String
        /// Run folder; created if missing.
        var destination: String
        /// One of `PoseModels.all`.
        var modelName: String
        var settings: InferenceSettings
        var roi: NRect?
        var fps: Double
        var frameWidth: Double
        var frameHeight: Double
        var videoDuration: Double
        var sourceSize: UInt64
        var sourceModification: Double
        /// Computed by the host (see RodentFlow.Inference/VideoFingerprint.cs). Only used to refuse
        /// continuing a folder that belongs to another file, so it never has to match the Mac's.
        var sourceFingerprint: String
        /// Reduced decode size the host is using, or nil for full size.
        var decodeScale: Double?
        /// The model's input, in pixels (960 × 960 for every RodentFlow pose model).
        var modelInputWidth: Int
        var modelInputHeight: Int
    }

    // MARK: State

    private let fm = FileManager.default
    private let dest: URL
    private var manifest: PoseStreamManifest
    private let animalCount: Int
    private let appearanceDims: Int
    private let header: String
    private let modelSize: (width: Int, height: Int)
    private let threshold: Float
    private let roi: NRect?
    private let frameSize: V2

    private let rangeStart: Double
    private let rangeEnd: Double
    private let step: Int
    private let resumeAfter: Double?
    private let totalSegments: Int

    private var tracker: OnlineIdentityTracker
    private var groupTracker: GroupIdentityTracker

    private var segIndex: Int?
    private var handle: FileHandle?
    private var segRecords = 0
    private var segFailed = 0
    private var segFirst: Double?
    private var segLast: Double?
    private var buffer = Data()
    private var lastFlush = Date().timeIntervalSinceReferenceDate

    private var seq: Int?
    private var consecutiveFailures = 0
    private(set) var analysedFrames = 0
    private(set) var finished = false

    // MARK: Open

    /// Creates or continues the run folder. Throws when the folder belongs to another run.
    init(_ r: Request) throws {
        guard r.frameWidth >= 1, r.frameHeight >= 1 else { throw RFError.badArgument("Invalid frame size") }
        guard r.videoDuration.isFinite, r.videoDuration > 0 else { throw RFError.badArgument("Invalid video duration") }
        guard r.fps > 0 else { throw RFError.badArgument("Invalid frame rate") }
        guard r.modelInputWidth > 0, r.modelInputHeight > 0 else { throw RFError.badArgument("Invalid model input size") }
        guard PoseModels.all.contains(r.modelName) else { throw RFError.badArgument("Unknown model " + r.modelName) }

        dest = URL(fileURLWithPath: r.destination, isDirectory: true)
        modelSize = (width: r.modelInputWidth, height: r.modelInputHeight)
        frameSize = V2(r.frameWidth, r.frameHeight)
        roi = r.roi

        // Animals per frame: the group model takes it from the session, the others from the model.
        let n = r.modelName == kGroupModelName
            ? min(kGroupMaxAnimals, max(1, r.settings.animalCount))
            : PoseModels.animalCount(of: r.modelName)
        animalCount = n
        appearanceDims = n == 2 ? AppearanceSampler.dims : 0

        var settings = r.settings
        settings.animalCount = n
        // The manifest names the coat colour of the model that runs (PoseModels.swift).
        settings.coat = PoseModels.coat(of: r.modelName) ?? settings.coat
        settings.roi = r.roi

        var fresh = PoseStreamManifest(sourceFile: r.videoName, sourceSize: r.sourceSize,
                                       sourceModification: r.sourceModification, sourceFingerprint: r.sourceFingerprint,
                                       modelName: r.modelName, animalCount: n, appearanceDims: appearanceDims,
                                       settings: settings, roi: r.roi, fps: r.fps,
                                       frameWidth: r.frameWidth, frameHeight: r.frameHeight,
                                       videoDuration: r.videoDuration, segmentSeconds: Self.segmentSeconds)
        if let s = r.decodeScale, s < 1 { fresh.decodeScale = s }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.appendingPathComponent(PoseStreamManifest.fileName).path) {
            let saved = try PoseStreamManifest.load(dest)
            guard saved.continues(fresh) else {
                throw RFError.failed("This run folder belongs to another video, model or tracking setting. Analyse again into a new folder.")
            }
            manifest = saved
        } else {
            let existing = try fm.contentsOfDirectory(atPath: dest.path).filter { !$0.hasPrefix(".") }
            guard existing.isEmpty else { throw RFError.failed("Choose an empty result folder.") }
            manifest = fresh
            try manifest.save(to: dest)
        }

        header = PoseStreamFormat.header(animalCount: n, appearanceDims: appearanceDims)
        tracker = OnlineIdentityTracker(frameSize: frameSize)
        groupTracker = GroupIdentityTracker(animals: max(2, n), frameSize: frameSize)
        threshold = n == 2 ? tracker.settings.lowScore : Self.defaultConfidence

        rangeStart = max(0, settings.startTime)
        rangeEnd = settings.endTime > 0 ? min(settings.endTime, r.videoDuration) : r.videoDuration
        step = max(1, settings.stride)
        totalSegments = max(1, Int(ceil((rangeEnd - rangeStart) / Self.segmentSeconds)))

        // Already complete: nothing left to feed.
        if manifest.finished && fm.fileExists(atPath: dest.appendingPathComponent(PoseStreamManifest.poseFileName).path) {
            finished = true
            resumeAfter = nil
            buffer.reserveCapacity(0)
            return
        }

        let resume = try PoseStreamFormat.resumePoint(manifest, folder: dest)
        resumeAfter = resume.lastRow?.time
        if n == 2, let last = resume.lastRow { tracker.seed(last.poses, time: last.time) }
        if n > 2, let last = resume.lastRow { groupTracker.seed(last.poses) }
        if let last = resume.lastRow, let offset = manifest.frameOffset { seq = last.frame - offset + 1 }

        buffer.reserveCapacity(Self.flushBytes + 4096)

        // The interrupted segment continues after its last complete row.
        if let index = resume.partialIndex {
            let url = dest.appendingPathComponent(PoseStreamManifest.partialName(index))
            let h = try FileHandle(forWritingTo: url)
            if resume.partialValidBytes == 0 {
                try h.truncate(atOffset: 0)
                try h.write(contentsOf: Data(header.utf8))
            } else {
                try h.truncate(atOffset: UInt64(resume.partialValidBytes))
            }
            try h.seekToEnd()
            handle = h
            segIndex = index
            segRecords = resume.partialRows
            segFailed = resume.partialFailed
            segFirst = resume.partialFirstTime
            segLast = resume.partialRows > 0 ? resume.lastRow?.time : nil
        }
    }

    /// What the host needs to drive the loop.
    var openInfo: [String: Any] {
        [
            "animalCount": animalCount,
            "appearanceDims": appearanceDims,
            "modelName": manifest.modelName,
            "confidenceThreshold": Double(threshold),
            "maxDetections": Self.maxDetections,
            "stride": step,
            "rangeStart": rangeStart,
            "rangeEnd": rangeEnd,
            "resumeAfter": resumeAfter.map { $0 as Any } ?? NSNull(),
            "decodeScale": manifest.decodeScale.map { $0 as Any } ?? NSNull(),
            "modelInputWidth": modelSize.width,
            "modelInputHeight": modelSize.height,
            "frameWidth": manifest.frameWidth,
            "frameHeight": manifest.frameHeight,
            "roi": roi.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as Any } ?? NSNull(),
            "grayscale": manifest.settings.grayscale,
            "completedSegments": manifest.completed.count,
            "totalSegments": totalSegments,
            "recordCount": manifest.recordCount,
            "alreadyFinished": finished,
        ]
    }

    // MARK: Frame filter

    /// Called for every decoded frame, in order, before the model runs. Mirrors the guards of the
    /// Mac read loop, so a Windows run analyses exactly the same frames.
    /// Returns the status and, for `.analyze`, the frame number to record.
    func filter(time pts: Double) throws -> (RFStatus, Int) {
        guard !finished else { return (.pastRange, 0) }
        guard pts.isFinite else { return (.skip, 0) }
        if let after = resumeAfter, pts <= after + 1e-4 { return (.skip, 0) }
        if pts < rangeStart - 1e-4 { return (.beforeRange, 0) }
        if pts > rangeEnd + 1e-4 { return (.pastRange, 0) }
        if manifest.frameOffset == nil {
            manifest.frameOffset = Int((pts * manifest.fps).rounded())
            try manifest.save(to: dest)
        }
        let i = seq ?? 0
        seq = i + 1
        guard i % step == 0 else { return (.skip, 0) }
        return (.analyze, (manifest.frameOffset ?? 0) + i)
    }

    // MARK: One analysed frame

    /// Decodes the model output, assigns identities and writes the row.
    ///
    /// - Parameters:
    ///   - tensor: the model's end-to-end output, `[1, detections, fields]` of Float32, or nil when
    ///     the model failed on this frame (the row is written as "no animal", as on the Mac).
    ///   - crop: the region given to the model, in upright whole-frame pixels. `PoseDecoding` needs
    ///     its size to undo the letterbox; `ArenaROI.uncrop` needs its origin.
    ///   - bgra: the decoded upright frame as 32-bit BGRA, used only to read fur colour for two
    ///     animals (pass nil otherwise). Its size may differ from the frame size (reduced decode);
    ///     `AppearanceSampler` scales accordingly.
    /// - Returns: the poses written, for the host's live preview.
    func analyse(frameNumber: Int, time pts: Double,
                 tensor: UnsafePointer<Float>?, tensorCount: Int,
                 detections: Int, fields: Int, detectionStride: Int, fieldStride: Int,
                 cropX: Double, cropY: Double, cropW: Double, cropH: Double,
                 bgra: UnsafePointer<UInt8>?, bgraWidth: Int, bgraHeight: Int, bgraRowBytes: Int) throws -> [AnimalPose] {
        guard !finished else { throw RFError.failed("This run is already finished") }
        guard cropW >= 1, cropH >= 1 else { throw RFError.badArgument("Invalid crop size") }

        let index = Int(max(0, pts - rangeStart) / Self.segmentSeconds)
        if segIndex != index {
            try closeSegment()
            try openSegment(index)
        }

        var poses = [AnimalPose](repeating: .missing, count: animalCount)
        var appearance: [[Float]] = []
        var failed = true

        if let tensor, detections > 0, fields >= 6 {
            let layout = PoseDecoding.Layout(detections: detections, fields: fields,
                                             detectionStride: detectionStride, fieldStride: fieldStride)
            let cropSize = CGSize(width: CGFloat(cropW), height: CGFloat(cropH))
            let buf = UnsafeBufferPointer(start: tensor, count: tensorCount)
            // Same call the apps make through DirectPoseModel.decode: inputSize and frameSize are both
            // the crop, so the keypoints come back in crop pixels and uncrop moves them to the frame.
            if let decoded = PoseDecoding.decode(buf, layout: layout, inputSize: cropSize, modelSize: modelSize,
                                                 frameSize: cropSize, threshold: threshold, limit: Self.maxDetections) {
                let found = ArenaROI.uncrop(decoded, originX: cropX, originY: cropY)
                failed = false
                if animalCount > 2 {
                    poses = groupTracker.update(found)
                } else if animalCount > 1 {
                    poses = tracker.update(found, time: pts)
                    if appearanceDims > 0, let bgra, bgraWidth > 0, bgraHeight > 0, bgraRowBytes >= bgraWidth * 4 {
                        // The host hands over an upright buffer, so the geometry is the identity and
                        // AppearanceSampler scales for a reduced decode size on its own.
                        let geometry = RawImageGeometry(width: bgraWidth, height: bgraHeight, orientation: .up)
                        let length = tracker.bodyLength
                        appearance = poses.map { pose in
                            AppearanceSampler.descriptor(pose, raw: geometry, frameSize: frameSize, bodyLength: length) { x, y in
                                let p = bgra + y * bgraRowBytes + x * 4   // B, G, R, A
                                return (r: Float(p[2]), g: Float(p[1]), b: Float(p[0]))
                            }
                        }
                    }
                } else {
                    poses = [bestPoseOf(found)]
                }
            }
        }

        if failed {
            consecutiveFailures += 1
            segFailed += 1
            if consecutiveFailures >= 5 || segFailed >= 30 {
                try? flush(sync: true)
                try? handle?.close()
                handle = nil
                throw RFError.failed(String(format: "Too many model failures near %.1f s (%d in this minute of video). The frames analysed so far are kept; analyse again to continue.", pts, segFailed))
            }
        } else {
            consecutiveFailures = 0
        }

        let line = PoseStreamFormat.row(frame: frameNumber, time: pts, failed: failed, poses: poses,
                                        appearance: appearance, animalCount: animalCount, appearanceDims: appearanceDims)
        buffer.append(contentsOf: line.utf8)
        segRecords += 1
        analysedFrames += 1
        if segFirst == nil { segFirst = pts }
        segLast = pts
        let now = Date().timeIntervalSinceReferenceDate
        if buffer.count >= Self.flushBytes || now - lastFlush >= Self.flushSeconds { try flush() }
        return poses
    }

    /// Highest-confidence detection — the rule `bestPose` applies in the apps (PoseVision.swift),
    /// repeated here because that file is Core ML only and is not part of this library.
    private func bestPoseOf(_ detections: [AnimalPose]) -> AnimalPose {
        var top = AnimalPose.missing
        for d in detections where d.detected && d.conf > top.conf { top = d }
        return top
    }

    // MARK: Segment files

    private func flush(sync: Bool = false) throws {
        guard let h = handle else { return }
        if !buffer.isEmpty {
            try h.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        if sync { try h.synchronize() }
        lastFlush = Date().timeIntervalSinceReferenceDate
    }

    private func openSegment(_ index: Int) throws {
        let url = dest.appendingPathComponent(PoseStreamManifest.partialName(index))
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: Data(header.utf8)) else {
            throw RFError.failed("Cannot write " + url.lastPathComponent)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        segIndex = index
        segRecords = 0; segFailed = 0; segFirst = nil; segLast = nil
    }

    private func closeSegment() throws {
        guard let index = segIndex, let h = handle else { return }
        try flush(sync: true)
        try h.close()
        handle = nil
        segIndex = nil
        let partial = dest.appendingPathComponent(PoseStreamManifest.partialName(index))
        guard segRecords > 0, let first = segFirst, let last = segLast else {
            try? fm.removeItem(at: partial)
            return
        }
        let name = PoseStreamManifest.segmentName(index)
        let final = dest.appendingPathComponent(name)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: partial, to: final)
        manifest.completed.removeAll { $0.index == index }
        manifest.completed.append(.init(index: index, file: name, records: segRecords, firstTime: first,
                                        lastTime: last, failedFrames: segFailed))
        manifest.completed.sort { $0.index < $1.index }
        try manifest.save(to: dest)
    }

    // MARK: Finish and stop

    /// Every frame of the range is in: assemble the rows, resolve A / B over the whole video and
    /// write pose.mpt. `msPerFrame` is the host's measured model time (recorded in the track).
    func finish(msPerFrame: Double) throws -> [String: Any] {
        guard !finished else {
            return ["poseFile": dest.appendingPathComponent(PoseStreamManifest.poseFileName).path,
                    "frames": manifest.recordCount, "alreadyFinished": true]
        }
        try closeSegment()
        var track = try PoseStreamFormat.assemble(manifest, folder: dest)
        guard track.count > 0 else { throw RFError.failed("No decodable frames in the analysed range") }
        track.complete = true
        track.processedUntil = max(track.processedUntil, rangeEnd)
        track.msPerFrame = msPerFrame
        if animalCount > 1 { track = IdentityResolver.resolve(track) }
        let poseURL = dest.appendingPathComponent(PoseStreamManifest.poseFileName)
        try track.encoded().write(to: poseURL, options: .atomic)
        manifest.finished = true
        manifest.finishedAt = Date()
        try manifest.save(to: dest)
        finished = true
        return [
            "poseFile": poseURL.path,
            "frames": track.count,
            "failedFrames": manifest.failedCount,
            "animalCount": track.animalCount,
            "identityUncertain": track.flags.count == track.count ? track.flags.filter { $0 != 0 }.count : 0,
            "processedUntil": track.processedUntil,
            "alreadyFinished": false,
        ]
    }

    /// Stopped by the user: the rows written so far are kept, as on the Mac.
    func stop() {
        try? flush(sync: true)
        try? handle?.close()
        handle = nil
    }

    var progress: [String: Any] {
        [
            "completedSegments": manifest.completed.count,
            "totalSegments": totalSegments,
            "currentSegment": segIndex ?? 0,
            "processedInSegment": segRecords,
            "sourceTime": segLast ?? rangeStart,
            "sourceDuration": rangeEnd,
            "analysedFrames": analysedFrames,
        ]
    }

    /// Poses as JSON for the host's live preview (whole-frame pixels).
    static func posesJSON(_ poses: [AnimalPose]) -> [[String: Any]] {
        poses.map { p in
            guard p.detected else { return ["detected": false] }
            return [
                "detected": true,
                "conf": RFJSON.number(p.conf),
                "x": p.x.map { RFJSON.number($0) },
                "y": p.y.map { RFJSON.number($0) },
                "kconf": p.kconf.map { RFJSON.number($0) },
            ]
        }
    }
}
