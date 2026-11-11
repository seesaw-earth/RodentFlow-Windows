// TSTSessionMetrics.swift — one chamber of a multi-chamber TST recording as an ordinary session summary
// (SessionMetricSummary), so group statistics, exports and the phone → Mac sync treat it like any task.
//
// Measures follow the usual TST reporting (Steru 1985; Can et al. 2012, JoVE): every mouse is timed from
// its OWN suspension; the primary measure is immobility in the last 4 min of a 6-min test (minutes 2–6),
// with minutes 0–2, the whole 0–6 min test, latency and bout structure as secondary measures. The
// per-minute immobility is also supplied as a series, so the group page can show the time course
// (mean ± SEM per group, n = animals) and test group × minute with the mixed ANOVA.
import Foundation

enum TSTSessionMetrics {
    static let seriesKey = "tst_immobility_per_minute"
    static let seriesName = "Immobility per minute"
    /// Series contract: x = bin centre in minutes after this mouse's suspension (0.5, 1.5, …).
    static let seriesXLabel = "Time (min), 1-min bins"

    /// "2–6 min" style label of a window given in seconds.
    static func minutes(_ a: Double, _ b: Double, dash: String = "–") -> String {
        minuteText(a) + dash + minuteText(b)
    }

    /// "6" or "5.5": a time in seconds as minutes.
    static func minuteText(_ s: Double) -> String {
        let v = s / 60
        return abs(v - v.rounded()) < 0.01 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }

    /// The standard windows of a recording's settings, for captions (minutes after each mouse's suspension).
    struct Windows {
        let test: Double
        let primaryStart: Double

        init(_ settings: AnalysisSettings) {
            test = settings.standardTestSec
            primaryStart = test - min(max(0, settings.lastWindowSec), test)
        }

        /// "2–6", "0–2", "0–6"; `testMinutes` "6", `primaryMinutes` "4".
        var primary: String { TSTSessionMetrics.minutes(primaryStart, test) }
        var early: String { TSTSessionMetrics.minutes(0, primaryStart) }
        var whole: String { TSTSessionMetrics.minutes(0, test) }
        var testMinutes: String { TSTSessionMetrics.minuteText(test) }
        var primaryMinutes: String { TSTSessionMetrics.minuteText(test - primaryStart) }
    }

    /// One minute after a mouse's suspension, with the share of it that was recorded.
    struct MinuteBin {
        let index: Int
        let seconds: Double
        let coverage: Double
        var centre: Double { Double(index) + 0.5 }
        var label: String { "\(index)–\(index + 1)" }
        var complete: Bool { coverage >= 59.5 / 60 }
    }

    /// Immobility per minute after the suspension (series contract): a minute with less than 90 % of it inside the
    /// recorded part of the video (and, with `testOnly`, inside the standard test) is left out.
    static func minuteBins(_ c: ChamberSummary, settings: AnalysisSettings, testOnly: Bool) -> [MinuteBin] {
        let onset = c.onsetSec ?? 0
        let test = c.testLengthSec ?? settings.standardTestSec
        let recorded = max(0, settings.durationSec - onset)
        let end = testOnly ? min(test, recorded) : recorded
        var out: [MinuteBin] = []
        for (m, seconds) in c.perMinuteImmobileSec.enumerated() {
            let a = Double(m) * 60
            if testOnly && a >= test { break }
            let covered = max(0, min(a + 60, end) - a) / 60
            if covered >= 0.9 - 1e-9 { out.append(MinuteBin(index: m, seconds: seconds, coverage: min(1, covered))) }
        }
        return out
    }

    /// The measures of one chamber (one animal) of a saved recording, as the group comparison, the task
    /// exports and the phone → Mac sync see them. Same numbers on the phone and on the Mac.
    static func summary(record: TSTStoredRecording, chamber: ChamberSummary, key: String, videoID: UUID,
                        runFolder: String, phase: String) -> SessionMetricSummary {
        func metric(_ key: String, _ en: String, _ zh: String, _ unitEN: String, _ unitZH: String,
                    _ value: Double?, _ decimals: Int = 2) -> SessionMetricEntry {
            SessionMetricEntry(key: key, nameEN: en, nameZH: zh, unitEN: unitEN, unitZH: unitZH,
                               decimals: decimals, value: value?.isFinite == true ? value : nil,
                               chance: nil, section: nil)
        }
        // Archives written before the standard windows existed: their "last window" is the primary value.
        let testLength = chamber.testLengthSec ?? record.settings.standardTestSec
        let primaryStart = chamber.primaryStartSec ?? max(0, testLength - record.settings.lastWindowSec)
        let primaryLabel = minutes(primaryStart, testLength)
        let earlyLabel = minutes(0, primaryStart)
        let testLabel = minutes(0, testLength)
        // English names go into the exports: plain ASCII hyphen.
        let primaryEN = minutes(primaryStart, testLength, dash: "-")
        let earlyEN = minutes(0, primaryStart, dash: "-")
        let testEN = minutes(0, testLength, dash: "-")

        var metrics: [SessionMetricEntry] = [
            metric("tst_imm_primary_s", "Immobility, min " + primaryEN, "不动时间（第 " + primaryLabel + " 分钟）", "s", "秒",
                   chamber.primaryImmobileSec ?? chamber.immobileLastWindowSec),
            metric("tst_imm_primary_pct", "Immobility %, min " + primaryEN, "不动百分比（第 " + primaryLabel + " 分钟）", "%", "%",
                   chamber.primaryImmobilePercent),
            metric("tst_no_mouse_primary_pct", "No mouse, min " + primaryEN, "无小鼠（第 " + primaryLabel + " 分钟）", "%", "%",
                   chamber.primaryNoMousePercent),
            metric("tst_imm_early_s", "Immobility, min " + earlyEN, "不动时间（第 " + earlyLabel + " 分钟）", "s", "秒",
                   chamber.earlyImmobileSec),
            metric("tst_imm_test_s", "Immobility, min " + testEN, "不动时间（第 " + testLabel + " 分钟）", "s", "秒",
                   chamber.testImmobileSec),
            metric("tst_imm_test_pct", "Immobility %, min " + testEN, "不动百分比（第 " + testLabel + " 分钟）", "%", "%",
                   chamber.testImmobilePercent),
            // Censored: without a bout in the test it is the end of the observed test (tst_became_immobile = 0).
            metric("tst_latency_s", "Latency to first immobility", "首次不动潜伏期", "s", "秒", chamber.latencySec),
            metric("tst_became_immobile", "Became immobile, min " + testEN, "出现不动（第 " + testLabel + " 分钟）", "%", "%",
                   chamber.becameImmobile.map { $0 ? 100 : 0 }, 0),
            metric("tst_bouts", "Immobility bouts, min " + testEN, "不动次数（第 " + testLabel + " 分钟）", "count", "次",
                   Double(chamber.bouts), 0),
            metric("tst_mean_bout_s", "Mean immobility bout", "平均不动持续时间", "s", "秒", chamber.meanBoutSec),
            metric("tst_longest_bout_s", "Longest immobility bout", "最长不动持续时间", "s", "秒", chamber.longestBoutSec),
            metric("tst_intensity", "Mobility intensity (motion while mobile)", "运动强度（活动时的运动量）", "% body", "% 鼠体",
                   chamber.mobilityIntensity),
            metric("tst_immobile_s", "Immobility, whole recording", "不动时间（全程）", "s", "秒", chamber.immobileTotalSec),
            metric("tst_immobile_pct", "Immobility %, whole recording", "不动百分比（全程）", "%", "%", chamber.immobilePercent),
            metric("tst_no_mouse_pct", "No-mouse / segmentation failure", "漏检／分割失败", "%", "%", chamber.noMousePercent),
            metric("tst_test_coverage_pct", "Recorded share of the min " + testEN + " test", "第 " + testLabel + " 分钟测试的录制比例",
                   "%", "%", chamber.testCoverage.map { 100 * $0 }, 0),
        ]
        // Minutes of the whole analysed window after the suspension; a minute with less than 90 % recorded is missing
        // (empty), never 0 s (same rule as the time course).
        let recordedMinutes = Dictionary(uniqueKeysWithValues: minuteBins(chamber, settings: record.settings, testOnly: false)
            .map { ($0.index, $0.seconds) })
        for i in chamber.perMinuteImmobileSec.indices {
            metrics.append(metric("tst_minute_\(i + 1)_s", "Minute \(i + 1) immobility", "第 \(i + 1) 分钟不动", "s", "秒",
                                  recordedMinutes[i]))
        }

        let onset = chamber.onsetSec ?? 0
        // Time course for the group page: the minutes of the standard test (bin centres; < 90 % recorded = left out).
        let bins = minuteBins(chamber, settings: record.settings, testOnly: true)
        // Stored in English like every other series (exports are English); the interface translates the labels.
        let series = bins.isEmpty ? [] : [FlowResultSeries(key: seriesKey, name: seriesName, unit: "s", xLabel: seriesXLabel,
                                                            x: bins.map(\.centre), y: bins.map(\.seconds))]

        var out = SessionMetricSummary(cacheKey: key,
                                       analyzer: "TSTScorer6 / multi-chamber · summary definitions v\(chamber.definitionVersion ?? 1)"
                                           + " · measure: " + record.settings.metric.rawValue
                                           + String(format: " · threshold %.2f%% per analysed frame at %.2f fps",
                                                    record.settings.immobilityThreshold, record.fps)
                                           + (record.settings.useRefinedOutline ? " · refined outline" : " · original outline")
                                           + (chamber.onsetSec != nil ? " · timed from each mouse's suspension" : ""),
                                       computedAt: record.savedAt, videoID: videoID,
                                       runFolder: runFolder, phase: phase,
                                       primaryKey: "tst_imm_primary_s", metrics: metrics)
        out.series = series
        if (chamber.definitionVersion ?? 1) >= Scorer.definitionVersion { out.definitions = SessionMetricSummary.currentDefinitions }
        out.windowStart = record.settings.startSec + onset
        out.windowLength = testLength
        out.trackedFraction = max(0, min(1, 1 - chamber.noMousePercent / 100))
        if let coverage = chamber.testCoverage, coverage < 0.98 {
            out.qcFlags.append(String(format: "Only %.0f%% of the ", 100 * coverage) + testEN
                               + " min test was recorded after this mouse's suspension")
        }
        let threshold = record.settings.exclusionNoMousePct
        if chamber.exclusionSuggested == true {
            // A suggestion only: the session stays included until the user excludes it.
            out.qcFlags.append(String(format: "Exclusion suggested: no mouse in %.1f%% of min ", chamber.primaryNoMousePercent ?? 0)
                               + primaryEN + String(format: " and %.1f%% of min ", chamber.testNoMousePercent ?? 0) + testEN
                               + String(format: " (threshold %g%%); review the video", threshold))
        } else if chamber.exclusionSuggested == nil, chamber.noMousePercent > threshold {
            out.qcFlags.append(String(format: "No-mouse / segmentation-failure frames exceed %g%%; manually review", threshold))
        }
        if (chamber.definitionVersion ?? 1) < Scorer.definitionVersion {
            // Archives without frame traces (TSTScorer 0.7.0) cannot be recomputed when read.
            out.qcFlags.append("Earlier TST definitions (this archive holds no frame traces to recompute them): immobility % is of the frames with the mouse visible and the latency is not censored; analyse the video again before pooling with current results")
        }
        out.qcFlags.append("TST multi-chamber scoring has not been validated against blinded manual scoring")
        return out
    }
}
