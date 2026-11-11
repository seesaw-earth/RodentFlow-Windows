// ReviewABI.swift — what the frame-by-frame review needs from the engine.
//
//   qcEvents            moments to check, in the order of the track: no detection, an animal missing, low
//                       confidence, outside the calibrated arena, A / B to check, identity uncertain, animals
//                       overlapping. A port of TrackingReviewEventBuilder.short (RodentStudio/Core/
//                       TrackingReviewEvents.swift), which reads the Mac's run form; this reads the pose track
//                       itself. Returned with the report (rf_analyze, review.qc), because the outside-arena flags
//                       come from the analysis (ArenaBounds via Analyzer.run). They only point frames out.
//   rf_swap_identity    "Swap A / B from here" / "Swap A / B in a range" on a two-animal pose.mpt:
//                       IdentityResolver.correct(_:at:) / correct(_:from:to:), as PoseRunLoader.swapIdentity does
//                       on the Mac; pose.mpt is rewritten and the results must be recomputed (rf_analyze).
//   rf_identity_segments  IdentityResolver.segmentRanges, for showing what a range swap will cover.

import Foundation

enum ReviewABI {
    /// The Mac frame review's default confidence threshold for "Low confidence" (ReviewExportView.threshold).
    static let lowConfidence: Float = 0.35

    /// Moments to check, merged into runs of consecutive frames of the same kind (at most `limit` runs).
    static func qcEvents(track: PoseTrack, report: AnalysisReport, limit: Int = 20_000) -> [[String: Any]] {
        let n = track.count, animals = track.animalCount
        var out: [[String: Any]] = []
        var kind: String?
        var first = 0
        let tolerance = report.outsideArenaTolerance ?? 0

        func title(_ k: String) -> String {
            switch k {
            case "noDetection": return L("No detection", "未检出")
            case "animalMissing": return animals > 2 ? L("Animal missing", "有小鼠未检出") : L("One animal missing", "一只小鼠未检出")
            case "lowConfidence": return L("Low confidence", "置信度低")
            case "outsideArena": return L("Outside calibrated arena", "超出标定范围")
            case "identitySuspect": return L("Identity: check A / B", "身份：请核对 A / B")
            case "identityUncertain": return L("Identity uncertain", "身份不确定")
            case "overlapping": return L("Animals overlapping", "小鼠重叠")
            default: return k
            }
        }

        func push(_ last: Int) {
            guard let k = kind, last >= first, out.count < limit else { return }
            var e: [String: Any] = [:]
            e["kind"] = k
            e["title"] = title(k)
            e["firstIndex"] = first
            e["lastIndex"] = last
            e["frames"] = last - first + 1
            e["start"] = RFJSON.number(track.time[first])
            e["end"] = RFJSON.number(track.time[last])
            if k == "outsideArena" { e["toleranceCM"] = RFJSON.number(tolerance) }
            out.append(e)
        }

        for i in 0..<n {
            var best: Float = 0, worst: Float = .infinity
            var detected = 0
            for a in 0..<animals {
                let c = track.pose(i, a).conf
                best = max(best, c)
                worst = min(worst, c)
                if c > 0 { detected += 1 }
            }
            let outside = report.outsideArena.contains { i < $0.flags.count && $0.flags[i] }
            let flags: UInt8 = i < track.flags.count ? track.flags[i] : 0
            let now: String?
            if best <= 0 { now = "noDetection" }
            else if outside { now = "outsideArena" }
            else if animals > 1 && detected < animals { now = "animalMissing" }
            else if worst < lowConfidence { now = "lowConfidence" }
            else if animals > 1 && flags & IdentityFlag.suspect != 0 { now = "identitySuspect" }
            else if animals > 1 && flags & IdentityFlag.uncertain != 0 { now = "identityUncertain" }
            else if animals > 1 && flags & IdentityFlag.merged != 0 { now = "overlapping" }
            else { now = nil }
            if now != kind {
                push(i - 1)
                kind = now
                first = i
            }
        }
        if n > 0 { push(n - 1) }
        return out
    }

    struct SwapRequest: Decodable {
        var poseFile: String
        /// "Swap A / B from here": the frame (track index).
        var at: Int?
        /// "Swap A / B in a range": first and last track index.
        var from: Int?
        var to: Int?
    }

    static func swap(_ r: SwapRequest) throws -> [String: Any] {
        let url = URL(fileURLWithPath: r.poseFile)
        let track = try PoseTrack.decode(try Data(contentsOf: url))
        guard track.animalCount == 2 else { throw RFError.failed("A / B can be swapped only in a two-animal run.") }
        let fixed: PoseTrack?
        if let from = r.from, let to = r.to {
            fixed = IdentityResolver.correct(track, from: min(from, to), to: max(from, to))
        } else if let at = r.at {
            fixed = IdentityResolver.correct(track, at: at)
        } else {
            throw RFError.badArgument("Give either at, or from and to")
        }
        guard let fixed, let changed = IdentityResolver.changedOrder(track, fixed) else {
            return ["swapped": false, "changed": NSNull()]
        }
        try fixed.encoded().write(to: url, options: .atomic)
        TrackCache.shared.invalidate(r.poseFile)
        return ["swapped": true, "changed": [changed.lowerBound, changed.upperBound]]
    }

    static func segments(_ poseFile: String) throws -> [String: Any] {
        let track = try TrackCache.shared.track(poseFile)
        guard track.animalCount == 2 else { return ["segments": [Any]()] }
        let ranges: [[Int]] = IdentityResolver.segmentRanges(track).map { [$0.lowerBound, $0.upperBound] }
        return ["segments": ranges]
    }
}

/// `{poseFile, at}` or `{poseFile, from, to}` → `{ok, swapped, changed: [first, last] | null}`. Rewrites pose.mpt.
@_cdecl("rf_swap_identity")
public func rf_swap_identity(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_swap_identity: no request"))
    }
    do {
        let request = try RFCoding.decode(ReviewABI.SwapRequest.self, from: text)
        return rfMakeCString(RFJSON.ok(try ReviewABI.swap(request)))
    } catch {
        return rfMakeCString(RFJSON.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
    }
}

/// Identity segments of a two-animal pose.mpt: `{ok, segments: [[first, last], …]}` (track indices).
@_cdecl("rf_identity_segments")
public func rf_identity_segments(_ poseFile: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let path = rfReadCString(poseFile) else {
        return rfMakeCString(RFJSON.failure("rf_identity_segments: no path"))
    }
    do {
        return rfMakeCString(RFJSON.ok(try ReviewABI.segments(path)))
    } catch {
        return rfMakeCString(RFJSON.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
    }
}
