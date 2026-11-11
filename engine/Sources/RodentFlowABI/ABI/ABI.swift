// ABI.swift — the flat C entry points of RodentFlowABI.dll.
//
// Everything crossing the boundary is a scalar, a raw buffer, or UTF-8 JSON. Strings returned by
// this library are owned by the caller until `rf_string_free`.
//
// Keep this file, `engine/include/rodentflow.h` and `src/RodentFlow.Engine/RodentFlowNative.cs`
// in step: they are three views of the same contract.
//
// A tracking run, as the host drives it:
//
//   rf_run_open(requestJson)                    → handle, plus what the loop needs
//   for each decoded frame, in order:
//     rf_run_filter(handle, time, &frameNumber)  → 1 analyse, 0 skip, -1 before, -2 stop
//     if 1:  (host crops, letterboxes, runs ONNX)
//            rf_run_frame(handle, frameNumber, time, tensor, …) → 0 ok
//   rf_run_finish(handle, msPerFrame)           → pose.mpt written
//   rf_run_close(handle)
//
// Then: rf_analyze(requestJson) → metrics and the export files.

import Foundation

// MARK: - Library

@_cdecl("rf_version")
public func rf_version() -> UnsafeMutablePointer<CChar> {
    rfMakeCString(RFJSON.ok([
        "app": AppInfo.label,
        "version": AppInfo.version,
        "build": AppInfo.build,
        "abi": 1,
        "keypoints": kKeypointNames,
        "models": PoseModels.all,
    ]))
}

/// Releases a string this library returned. Every `char *` out of this ABI must come back here.
@_cdecl("rf_string_free")
public func rf_string_free(_ p: UnsafeMutablePointer<CChar>?) {
    p?.deallocate()
}

/// 0 = English, 1 = Chinese. Set it before analysing; the engine renders report text in it.
@_cdecl("rf_set_language")
public func rf_set_language(_ chinese: Int32) {
    Lang.isChinese = chinese != 0
}

/// The task catalogue, keypoints and model names, for the host's task list.
@_cdecl("rf_catalogue")
public func rf_catalogue() -> UnsafeMutablePointer<CChar> {
    rfMakeCString(RFJSON.ok(AnalysisRun.paradigms()))
}

// MARK: - Tracking run

/// Opens or continues a run folder. Returns JSON: `{ok, handle, …}` or `{ok:false, error}`.
@_cdecl("rf_run_open")
public func rf_run_open(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_run_open: no request"))
    }
    do {
        let request = try RFCoding.decode(TrackingRun.Request.self, from: text)
        let run = try TrackingRun(request)
        let handle = RFRunTable.shared.insert(run)
        var info = run.openInfo
        info["handle"] = Int(handle)   // JSONSerialization on corelibs-foundation does not take Int32
        return rfMakeCString(RFJSON.ok(info))
    } catch {
        return rfMakeCString(RFJSON.failure(describe(error)))
    }
}

/// Call for every decoded frame, in presentation order, before running the model.
/// Returns an `RFStatus`: 1 analyse this frame (and `frameNumberOut` is set), 0 skip,
/// -1 before the range, -2 past the range (stop decoding), < -9 error.
@_cdecl("rf_run_filter")
public func rf_run_filter(_ handle: Int32, _ time: Double,
                          _ frameNumberOut: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let run = RFRunTable.shared.get(handle) else { return RFStatus.badHandle.rawValue }
    do {
        let (status, frameNumber) = try run.filter(time: time)
        if status == .analyze { frameNumberOut?.pointee = Int32(clamping: frameNumber) }
        return status.rawValue
    } catch {
        return RFStatus.writeFailed.rawValue
    }
}

/// One analysed frame.
///
/// - tensor: the model's end-to-end output as Float32, or NULL when the model failed on this frame
///   (the row is then written as "no animal", as the apps do after two Vision failures).
/// - detections / fields / detectionStride / fieldStride: the shape and strides of that output,
///   in elements. For the usual `[1, 300, 24]` contiguous buffer: 300, 24, 24, 1.
/// - crop*: the region given to the model, in pixels of the upright whole frame.
/// - bgra: the decoded upright frame as 32-bit BGRA, for reading fur colour with two animals;
///   pass NULL for one animal or a group.
/// - posesJSONOut: optional; receives the poses written (for a live preview) or the error message.
///
/// Returns 0 on success, or a negative `RFStatus`.
@_cdecl("rf_run_frame")
public func rf_run_frame(_ handle: Int32,
                         _ frameNumber: Int32, _ time: Double,
                         _ tensor: UnsafePointer<Float>?, _ tensorCount: Int32,
                         _ detections: Int32, _ fields: Int32,
                         _ detectionStride: Int32, _ fieldStride: Int32,
                         _ cropX: Double, _ cropY: Double, _ cropW: Double, _ cropH: Double,
                         _ bgra: UnsafePointer<UInt8>?, _ bgraWidth: Int32, _ bgraHeight: Int32,
                         _ bgraRowBytes: Int32,
                         _ posesJSONOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    guard let run = RFRunTable.shared.get(handle) else {
        posesJSONOut?.pointee = rfMakeCString(RFJSON.failure("Unknown run handle"))
        return RFStatus.badHandle.rawValue
    }
    do {
        let poses = try run.analyse(frameNumber: Int(frameNumber), time: time,
                                    tensor: tensor, tensorCount: Int(max(0, tensorCount)),
                                    detections: Int(detections), fields: Int(fields),
                                    detectionStride: Int(detectionStride), fieldStride: Int(fieldStride),
                                    cropX: cropX, cropY: cropY, cropW: cropW, cropH: cropH,
                                    bgra: bgra, bgraWidth: Int(bgraWidth), bgraHeight: Int(bgraHeight),
                                    bgraRowBytes: Int(bgraRowBytes))
        if posesJSONOut != nil {
            posesJSONOut?.pointee = rfMakeCString(RFJSON.ok(["poses": TrackingRun.posesJSON(poses)]))
        }
        return 0
    } catch let e as RFError {
        posesJSONOut?.pointee = rfMakeCString(RFJSON.failure(describe(e)))
        if case .failed = e { return RFStatus.tooManyFailures.rawValue }
        return RFStatus.badArgument.rawValue
    } catch {
        posesJSONOut?.pointee = rfMakeCString(RFJSON.failure(describe(error)))
        return RFStatus.writeFailed.rawValue
    }
}

/// How far the run has got, for a progress bar.
@_cdecl("rf_run_progress")
public func rf_run_progress(_ handle: Int32) -> UnsafeMutablePointer<CChar> {
    guard let run = RFRunTable.shared.get(handle) else {
        return rfMakeCString(RFJSON.failure("Unknown run handle"))
    }
    return rfMakeCString(RFJSON.ok(run.progress))
}

/// Every frame of the range is in: writes pose.mpt (A / B resolved over the whole video for two
/// animals). `msPerFrame` is the host's measured model time, recorded in the track.
@_cdecl("rf_run_finish")
public func rf_run_finish(_ handle: Int32, _ msPerFrame: Double) -> UnsafeMutablePointer<CChar> {
    guard let run = RFRunTable.shared.get(handle) else {
        return rfMakeCString(RFJSON.failure("Unknown run handle"))
    }
    do {
        return rfMakeCString(RFJSON.ok(try run.finish(msPerFrame: msPerFrame)))
    } catch {
        return rfMakeCString(RFJSON.failure(describe(error)))
    }
}

/// Stops and forgets the run. Rows already written are kept, so the folder can be continued.
@_cdecl("rf_run_close")
public func rf_run_close(_ handle: Int32) {
    RFRunTable.shared.remove(handle)?.stop()
}

// MARK: - Analysis

/// pose.mpt + a session → the task's metrics and the export files. See AnalysisRun.Request.
@_cdecl("rf_analyze")
public func rf_analyze(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_analyze: no request"))
    }
    do {
        let request = try RFCoding.decode(AnalysisRun.Request.self, from: text)
        return rfMakeCString(RFJSON.ok(try AnalysisRun.run(request)))
    } catch {
        return rfMakeCString(RFJSON.failure(describe(error)))
    }
}

// MARK: - Reading a finished track

/// Header of a pose.mpt: frames, animals, frame rate, size, identity summary.
@_cdecl("rf_track_info")
public func rf_track_info(_ poseFile: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let path = rfReadCString(poseFile) else {
        return rfMakeCString(RFJSON.failure("rf_track_info: no path"))
    }
    do {
        let track = try TrackCache.shared.track(path)
        return rfMakeCString(RFJSON.ok([
            "frames": track.count,
            "animalCount": track.animalCount,
            "fps": RFJSON.number(track.fps),
            "frameWidth": RFJSON.number(track.frameWidth),
            "frameHeight": RFJSON.number(track.frameHeight),
            "frameStride": track.frameStride,
            "complete": track.complete,
            "processedUntil": RFJSON.number(track.processedUntil),
            "msPerFrame": RFJSON.number(track.msPerFrame),
            "appearanceDims": track.appearanceDims,
            "firstTime": RFJSON.number(track.time.first ?? 0),
            "lastTime": RFJSON.number(track.time.last ?? 0),
            "identityUncertainFrames": track.flags.count == track.count ? track.flags.filter { $0 != 0 }.count : 0,
        ]))
    } catch {
        return rfMakeCString(RFJSON.failure(describe(error)))
    }
}

/// `count` frames of a pose.mpt from index `from`, for drawing the skeleton while scrubbing.
/// The last file read stays in memory, so scrubbing does not re-read it.
@_cdecl("rf_track_frames")
public func rf_track_frames(_ poseFile: UnsafePointer<CChar>?, _ from: Int32, _ count: Int32) -> UnsafeMutablePointer<CChar> {
    guard let path = rfReadCString(poseFile) else {
        return rfMakeCString(RFJSON.failure("rf_track_frames: no path"))
    }
    do {
        let track = try TrackCache.shared.track(path)
        let lo = max(0, Int(from))
        let hi = min(track.count, lo + max(0, Int(count)))
        var frames: [[String: Any]] = []
        frames.reserveCapacity(max(0, hi - lo))
        for i in lo..<max(lo, hi) {
            var animals: [[String: Any]] = []
            for a in 0..<track.animalCount {
                animals.append(contentsOf: TrackingRun.posesJSON([track.pose(i, a)]))
            }
            frames.append([
                "index": i,
                "frame": i < track.frameIndex.count ? Int(track.frameIndex[i]) : i,
                "time": RFJSON.number(track.time[i]),
                "flags": i < track.flags.count ? Int(track.flags[i]) : 0,
                "animals": animals,
            ])
        }
        return rfMakeCString(RFJSON.ok(["from": lo, "frames": frames]))
    } catch {
        return rfMakeCString(RFJSON.failure(describe(error)))
    }
}

/// One decoded pose.mpt kept in memory, so the review UI can scrub without re-reading the file.
final class TrackCache {
    static let shared = TrackCache()
    private let lock = NSLock()
    private var path: String?
    private var cached: PoseTrack?

    func track(_ path: String) throws -> PoseTrack {
        lock.lock(); defer { lock.unlock() }
        if self.path == path, let cached { return cached }
        let track = try PoseTrack.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
        self.path = path
        cached = track
        return track
    }

    /// Forget a file that was rewritten (an A / B swap), so the next read sees the new track.
    func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        if self.path == path {
            self.path = nil
            cached = nil
        }
    }
}

// MARK: - Errors

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}
