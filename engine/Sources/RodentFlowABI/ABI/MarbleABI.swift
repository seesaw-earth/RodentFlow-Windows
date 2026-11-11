// MarbleABI.swift — where to read the marbles of a marble-burying session (rf_marble_plan).
//
// On the Mac and the phone, MarbleSampler (Shared/Vision/MarbleSampler.swift) reads each marble's brightness and the
// bedding's around it from the video with AVFoundation. That file is not part of this library (no AVFoundation on
// Windows); the host reads the pixels with ffmpeg (RodentFlow.Core/Marbles/MarbleSampling.cs). What to read is engine
// code and comes from here: the marble centres in upright pixels and their radius (MarbleGrid.pixelCenters), the
// sampling interval (AnalysisParams.mbSampleInterval) and the key the readings are cached under
// (MarbleSampler.key(for:), copied below: MarbleGrid.sampleKey over the whole video). The readings go back to the
// engine as rf_analyze's "marbles" (MarbleSamples).

import Foundation

enum MarbleABI {
    /// MarbleSampler.key(for:) — copied from Shared/Vision/MarbleSampler.swift; keep the two in step.
    static func key(for s: Session) -> String? {
        guard s.paradigm == .marbleBurying else { return nil }
        let frame = s.video.frameSize
        guard !MarbleGrid.pixelCenters(s.calibration, params: s.params, frameSize: frame).centers.isEmpty else { return nil }
        return MarbleGrid.sampleKey(s.calibration, params: s.params, frameSize: frame, videoName: s.videoName, range: (0, 0))
    }

    static func plan(_ s: Session) -> [String: Any] {
        var d: [String: Any] = [:]
        guard let key = key(for: s) else {
            d["needed"] = false
            return d
        }
        let g = MarbleGrid.pixelCenters(s.calibration, params: s.params, frameSize: s.video.frameSize)
        var centers: [[Any]] = []
        for c in g.centers { centers.append([RFJSON.number(c.x), RFJSON.number(c.y)]) }
        d["needed"] = true
        d["key"] = key
        d["centers"] = centers
        d["radius"] = RFJSON.number(g.radius)
        d["interval"] = RFJSON.number(max(0.1, s.params.mbSampleInterval))
        d["frameWidth"] = RFJSON.number(s.video.frameSize.x)
        d["frameHeight"] = RFJSON.number(s.video.frameSize.y)
        return d
    }
}

/// A Session (as rf_analyze takes it) → `{ok, needed, key, centers: [[x, y], …], radius, interval, frameWidth, frameHeight}`;
/// `needed` is false when the session is not marble burying or its marble grid is not placed.
@_cdecl("rf_marble_plan")
public func rf_marble_plan(_ sessionJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(sessionJSON) else {
        return rfMakeCString(RFJSON.failure("rf_marble_plan: no session"))
    }
    do {
        let session = try RFCoding.decode(Session.self, from: text)
        return rfMakeCString(RFJSON.ok(MarbleABI.plan(session)))
    } catch {
        return rfMakeCString(RFJSON.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
    }
}
