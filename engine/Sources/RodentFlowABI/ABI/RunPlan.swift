// RunPlan.swift — what the host needs to know before it decodes a single frame: which model to
// load, which part of the frame to give it, and at what size to decode.
//
// All three answers are engine decisions, so they are answered here rather than reimplemented in
// the host app:
//   model   PoseModels.name(for:)                       — animals × coat colour
//   region  ArenaROI.region(for:calibration:frameSize:)  — the calibrated arena plus its margin
//   crop    NRect.pixelRect(in:)                         — that region in whole pixels
//
// The one exception is the decode size. `PoseFrame.decodeScale` lives in Shared/Vision/PoseVision.swift,
// which is Core ML / Core Image code and is not part of this library, so the arithmetic is repeated
// below. It is plain arithmetic with no dependencies; keep the two in step.

import Foundation

enum RunPlan {
    struct Request: Decodable {
        var settings: InferenceSettings
        var calibration: ArenaCalibration
        var frameWidth: Double
        var frameHeight: Double
    }

    /// Scale at which the decoder should deliver frames: 1 (full size) unless the analysed region is
    /// large (longer side above ~2000 px); then the region keeps at least 1.25 × the model's 960 px
    /// input. Copy of `PoseFrame.decodeScale(frameSize:roi:)` (PoseVision.swift).
    static func decodeScale(frameSize: V2, roi: NRect?) -> Double {
        var regionLong = max(frameSize.x, frameSize.y)
        if let roi, !roi.isFullFrame {
            let r = roi.pixelRect(in: frameSize)
            regionLong = Double(max(r.width, r.height))
        }
        guard regionLong > 0 else { return 1 }
        let needed = 960.0 * 1.25
        let s = needed / regionLong
        // Only worth it (and only used) when it removes more than ~40 % of the pixels per side.
        return s <= 0.6 ? s : 1
    }

    /// Even pixel size the decoder is asked for at `scale`, as `PoseFrame.readerOutputSettings` does
    /// it on the other platforms (decoders want even dimensions).
    static func decodeSize(_ v: Double, scale: Double) -> Int {
        max(2, Int((v * scale).rounded()) & ~1)
    }

    static func make(_ r: Request) throws -> [String: Any] {
        guard r.frameWidth >= 1, r.frameHeight >= 1 else { throw RFError.badArgument("Invalid frame size") }
        let frameSize = V2(r.frameWidth, r.frameHeight)
        let settings = r.settings
        let roi = ArenaROI.region(for: settings, calibration: r.calibration, frameSize: frameSize)
        let crop = (roi ?? NRect.full).pixelRect(in: frameSize)
        let scale = decodeScale(frameSize: frameSize, roi: roi)
        let model = PoseModels.name(for: settings)

        var out: [String: Any] = [
            "modelName": model,
            "animalCount": model == kGroupModelName
                ? min(kGroupMaxAnimals, max(1, settings.animalCount))
                : PoseModels.animalCount(of: model),
            "coat": settings.coat.rawValue,
            "grayscale": settings.grayscale,
            "stride": max(1, settings.stride),
            "roi": roi.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as Any } ?? NSNull(),
            // The region given to the model, in pixels of the upright whole frame.
            "crop": ["x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height],
            "decodeScale": scale < 1 ? scale : NSNull(),
        ]
        if scale < 1 {
            out["decodeWidth"] = decodeSize(r.frameWidth, scale: scale)
            out["decodeHeight"] = decodeSize(r.frameHeight, scale: scale)
        }
        return out
    }
}

/// Which model to load, which part of the frame to give it, and at what size to decode.
@_cdecl("rf_plan_run")
public func rf_plan_run(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_plan_run: no request"))
    }
    do {
        let request = try RFCoding.decode(RunPlan.Request.self, from: text)
        return rfMakeCString(RFJSON.ok(try RunPlan.make(request)))
    } catch {
        return rfMakeCString(RFJSON.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
    }
}
