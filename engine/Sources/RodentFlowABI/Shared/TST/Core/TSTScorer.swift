import Foundation

public struct ChamberSummary: Codable, Identifiable, Sendable {
    public var id: Int { chamber }
    public var chamber: Int                 // 1-based, left → right
    public var analysed: Bool
    public var immobileTotalSec: Double
    public var immobilePercent: Double
    public var immobileLastWindowSec: Double
    /// First immobility bout that starts within the standard test; without one, the end of the observed
    /// test (censored: see `becameImmobile`). Archives before definition version 2: whole recording, nil = none.
    public var latencySec: Double?
    public var bouts: Int
    public var meanBoutSec: Double
    public var longestBoutSec: Double
    public var noMousePercent: Double       // QC: segmentation failure / climbing / out of view
    public var perMinuteImmobileSec: [Double]
    // Standard windows, measured from this mouse's own suspension (optional: archives written earlier
    // lack them). `immobileLastWindowSec` = the primary window; `latencySec`, the bouts and
    // `perMinuteImmobileSec` are also counted from the suspension.
    public var onsetSec: Double? = nil              // suspension, s after the analysis start
    public var testLengthSec: Double? = nil         // standard test length (360 s)
    public var primaryStartSec: Double? = nil       // primary window = [primaryStartSec, testLengthSec)
    public var earlyImmobileSec: Double? = nil      // minutes 0–2
    public var primaryImmobileSec: Double? = nil    // minutes 2–6
    /// % of every recorded frame of the window (the frames of the seconds); a frame without the mouse
    /// counts in the denominator, not as immobility. Before definition version 2: % of the frames with the mouse.
    public var primaryImmobilePercent: Double? = nil
    public var testImmobileSec: Double? = nil       // minutes 0–6
    public var testImmobilePercent: Double? = nil   // as primaryImmobilePercent
    public var testCoverage: Double? = nil          // recorded share of the 0–6 min test (0–1)
    public var mobilityIntensity: Double? = nil     // mean motion (% body) while mobile, minutes 0–6
    // Definition version 2 (nil in older archives until they are recomputed, see TSTStoredRecording.upgradingSummaries).
    public var primaryNoMousePercent: Double? = nil // frames without the mouse, % of the recorded primary window
    public var testNoMousePercent: Double? = nil    // the same over the whole standard test
    public var becameImmobile: Bool? = nil          // an immobility bout started within the test
    /// No-mouse % of the primary window or of the test above AnalysisSettings.exclusionNoMousePct: review the
    /// animal. A suggestion only; nothing is excluded automatically.
    public var exclusionSuggested: Bool? = nil
    public var definitionVersion: Int? = nil
}

public struct ChamberTrace: Sendable {
    public var time: [Double]
    public var motion: [Double]        // chosen metric, % of mouse area (smoothed)
    public var pixelPercent: [Double]  // raw pixel change, % of mouse area
    public var shapePercent: [Double]  // raw shape change, % of mouse area
    public var immobile: [Bool]
    public var noMouse: [Bool]
    public var area: [Double]
    public var cx: [Double]
    public var cy: [Double]
    public var boxPercent: [Double] = []   // box metric, % of the reference body size
    public var boxPresent: [Bool] = []     // box metric presence check
    public var onsetSec: Double = 0        // this mouse's suspension, s after the analysis start
}

public struct TSTMultiAnalysisResult: Sendable {
    public var settings: AnalysisSettings
    public var layout: ChamberLayout
    public var fps: Double
    public var summaries: [ChamberSummary]
    public var traces: [ChamberTrace]
}

public enum Scorer {
    /// Version of the summary definitions. 2: ★ % and test % over every recorded frame of the window, no-mouse %
    /// per window with the exclusion suggestion, latency within the test (censored at its end). Archived
    /// summaries of an older version are recomputed when read (TSTStoredRecording.upgradingSummaries).
    public static let definitionVersion = 2

    public static func score(measures: [[FrameMeasure]], layout: ChamberLayout,
                             settings: AnalysisSettings, fps: Double) -> TSTMultiAnalysisResult {
        var summaries: [ChamberSummary] = []
        var traces: [ChamberTrace] = []
        let testLength = settings.standardTestSec
        for (ci, ms) in measures.enumerated() {
            let t = ms.map { $0.time }
            let areas = ms.map { $0.area }
            let ref = median(areas.filter { $0 > 0 })
            let pixPct = ms.map { ref > 0 ? 100 * $0.pixelChange / ref : .nan }
            let shpPct = ms.map { ref > 0 ? 100 * $0.shapeChange / ref : .nan }
            let boxPct = ms.map { $0.boxBody > 0 ? 100 * $0.boxChange / $0.boxBody : .nan }
            let boxBody = ms.first?.boxBody ?? 0
            let raw: [Double]
            switch settings.metric {
            case .shape: raw = shpPct
            case .pixel: raw = pixPct
            case .box: raw = boxPct
            }
            // Box metric: presence comes from the mouse pixels in the box, not from the segmentation.
            let noMouse = settings.metric == .box ? ms.map { !$0.boxPresent } : areas.map { $0 == 0 }
            let analysed = layout.enabled[ci] && (settings.metric == .box ? boxBody > 0 : ref > 0)

            // Time since THIS mouse was suspended. Frames before it are not part of its test.
            let onset: Double = {
                guard let all = settings.chamberOnsetSec, ci < all.count, all[ci].isFinite else { return 0 }
                return max(0, all[ci])
            }()
            let rel = t.map { $0 - onset }
            let started = rel.map { $0 >= 0 }
            let present = started.indices.map { started[$0] && !noMouse[$0] }

            let smooth = rollingMedian(interpolate(raw), window: max(1, Int((settings.smoothSec * fps).rounded())))
            var imm = smooth.indices.map { k in analysed && present[k] && smooth[k] < settings.immobilityThreshold }
            imm = removeShortRuns(imm, minLength: Int((settings.minBoutSec * fps).rounded()))

            // Mobility intensity: mean motion while the mouse is mobile (and present) during the test.
            var mobileSum = 0.0, mobileN = 0
            for k in smooth.indices where present[k] && !imm[k] && rel[k] < testLength && smooth[k].isFinite {
                mobileSum += smooth[k]
                mobileN += 1
            }

            var summary = ChamberSummary(chamber: ci + 1, analysed: analysed, immobileTotalSec: 0, immobilePercent: 0,
                                         immobileLastWindowSec: 0, latencySec: nil, bouts: 0, meanBoutSec: 0,
                                         longestBoutSec: 0, noMousePercent: 0, perMinuteImmobileSec: [])
            applyWindows(&summary, time: t, immobile: imm, noMouse: noMouse, onset: onset, settings: settings, fps: fps)
            summary.onsetSec = onset
            summary.mobilityIntensity = mobileN == 0 ? nil : mobileSum / Double(mobileN)
            summaries.append(summary)
            traces.append(ChamberTrace(time: t, motion: smooth, pixelPercent: pixPct, shapePercent: shpPct,
                                       immobile: imm, noMouse: noMouse, area: areas,
                                       cx: ms.map { $0.cx }, cy: ms.map { $0.cy },
                                       boxPercent: boxPct, boxPresent: ms.map { $0.boxPresent },
                                       onsetSec: onset))
        }
        return TSTMultiAnalysisResult(settings: settings, layout: layout, fps: fps, summaries: summaries, traces: traces)
    }

    /// Re-classify existing traces with new threshold / bout settings (no re-processing of video).
    public static func rescore(_ r: TSTMultiAnalysisResult, settings: AnalysisSettings, measures: [[FrameMeasure]]) -> TSTMultiAnalysisResult {
        score(measures: measures, layout: r.layout, settings: settings, fps: r.fps)
    }

    /// Every window measure of one chamber from its scored frames (immobile / no-mouse flag per frame) and the
    /// mouse's suspension (`onset`, s after the analysis start). `s.analysed` must be set; the onset, mobility
    /// intensity and the analysed flag are left as they are. Used by `score` and to bring archived summaries
    /// to the current definitions (the archived traces hold the same flags).
    static func applyWindows(_ s: inout ChamberSummary, time t: [Double], immobile: [Bool], noMouse: [Bool],
                             onset: Double, settings: AnalysisSettings, fps: Double) {
        let n = min(t.count, immobile.count, noMouse.count)
        let dt = 1 / fps
        let nMin = max(1, Int((settings.durationSec / 60).rounded(.up)))
        let testLength = settings.standardTestSec
        let primaryLength = min(max(0, settings.lastWindowSec), testLength)
        let primaryStart = testLength - primaryLength
        let rel = (0..<n).map { t[$0] - onset }
        let imm = Array(immobile.prefix(n))
        let started = rel.map { $0 >= 0 }
        let present = (0..<n).map { started[$0] && !noMouse[$0] }

        func frames(_ flags: [Bool], from lo: Double, to hi: Double) -> Int {
            var count = 0
            for k in flags.indices where flags[k] && rel[k] >= lo && rel[k] < hi { count += 1 }
            return count
        }
        func percent(_ part: Int, of whole: Int) -> Double? { whole == 0 ? nil : 100 * Double(part) / Double(whole) }
        let immAll = frames(imm, from: 0, to: .infinity)
        let presentAll = frames(present, from: 0, to: .infinity)
        let startedAll = frames(started, from: 0, to: .infinity)
        let immTest = frames(imm, from: 0, to: testLength)
        let presentTest = frames(present, from: 0, to: testLength)
        let recordedTest = frames(started, from: 0, to: testLength)
        let immEarly = frames(imm, from: 0, to: primaryStart)
        let immPrimary = frames(imm, from: primaryStart, to: testLength)
        let presentPrimary = frames(present, from: primaryStart, to: testLength)
        let recordedPrimary = frames(started, from: primaryStart, to: testLength)

        // Bouts and latency inside the standard test only. Without a bout the latency is censored at the end of
        // the observed test: the test length, or the end of the video when it stops earlier.
        let testImm = (0..<n).map { imm[$0] && rel[$0] < testLength }
        let runs = trueRuns(testImm)
        let durs = runs.map { Double($0.1 - $0.0) * dt }
        let observedEnd = min(testLength, max(0, settings.durationSec - onset))

        var perMin = [Double](repeating: 0, count: nMin)
        for k in 0..<n where imm[k] {
            let m = min(nMin - 1, max(0, Int(rel[k] / 60)))
            perMin[m] += dt
        }

        s.immobileTotalSec = Double(immAll) * dt
        // Whole recording: share of the frames in which the mouse was present (frames after a mouse was taken
        // down must not dilute it). The standard windows below use every recorded frame instead.
        s.immobilePercent = percent(immAll, of: presentAll) ?? 0
        s.immobileLastWindowSec = Double(immPrimary) * dt
        s.latencySec = s.analysed ? (runs.first.map { rel[$0.0] } ?? observedEnd) : nil
        s.becameImmobile = s.analysed ? !runs.isEmpty : nil
        s.bouts = runs.count
        s.meanBoutSec = durs.isEmpty ? 0 : durs.reduce(0, +) / Double(durs.count)
        s.longestBoutSec = durs.max() ?? 0
        s.noMousePercent = percent(startedAll - presentAll, of: startedAll) ?? 0
        s.perMinuteImmobileSec = perMin
        s.testLengthSec = testLength
        s.primaryStartSec = primaryStart
        s.earlyImmobileSec = Double(immEarly) * dt
        s.primaryImmobileSec = Double(immPrimary) * dt
        s.primaryImmobilePercent = percent(immPrimary, of: recordedPrimary)
        s.testImmobileSec = Double(immTest) * dt
        s.testImmobilePercent = percent(immTest, of: recordedTest)
        s.testCoverage = min(1, Double(recordedTest) * dt / testLength)
        s.primaryNoMousePercent = percent(recordedPrimary - presentPrimary, of: recordedPrimary)
        s.testNoMousePercent = percent(recordedTest - presentTest, of: recordedTest)
        let worst = max(s.primaryNoMousePercent ?? 0, s.testNoMousePercent ?? 0)
        s.exclusionSuggested = s.analysed ? worst > settings.exclusionNoMousePct : nil
        s.definitionVersion = definitionVersion
    }

    // MARK: helpers

    static func interpolate(_ v: [Double]) -> [Double] {
        var out = v
        let valid = v.indices.filter { !v[$0].isNaN }
        guard let first = valid.first, let lastIdx = valid.last else { return v.map { _ in 0 } }
        for i in 0..<first { out[i] = v[first] }
        for i in (lastIdx + 1)..<v.count { out[i] = v[lastIdx] }
        var prev = first
        for i in valid.dropFirst() {
            if i - prev > 1 {
                for k in (prev + 1)..<i {
                    let f = Double(k - prev) / Double(i - prev)
                    out[k] = v[prev] + f * (v[i] - v[prev])
                }
            }
            prev = i
        }
        return out
    }

    static func rollingMedian(_ v: [Double], window w: Int) -> [Double] {
        if w <= 1 { return v }
        let half = w / 2
        return v.indices.map { i in
            let a = max(0, i - half), b = min(v.count, i - half + w)
            return median(Array(v[a..<b]))
        }
    }

    static func removeShortRuns(_ b: [Bool], minLength: Int) -> [Bool] {
        var out = b
        for (s, e) in trueRuns(b) where e - s < minLength {
            for k in s..<e { out[k] = false }
        }
        return out
    }

    /// Half-open [start, end) index ranges of consecutive `true`s.
    static func trueRuns(_ b: [Bool]) -> [(Int, Int)] {
        var runs: [(Int, Int)] = []
        var i = 0
        while i < b.count {
            if b[i] {
                var j = i
                while j < b.count && b[j] { j += 1 }
                runs.append((i, j)); i = j
            } else { i += 1 }
        }
        return runs
    }
}
