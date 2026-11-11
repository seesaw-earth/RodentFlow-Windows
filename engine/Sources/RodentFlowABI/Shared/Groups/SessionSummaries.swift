// SessionSummaries.swift — the summary numbers of one session, as the task / group summaries use them,
// on both platforms. The phone stores one per finished analysis and sends it with the session to the
// Mac, so the Mac can show the phone's own numbers next to its recomputation (consistency check).

import Foundation

struct SessionMetricEntry: Codable, Hashable {
    var key: String
    var nameEN: String
    var nameZH: String
    var unitEN: String
    var unitZH: String
    var decimals: Int
    var value: Double?
    /// Reference value for an optional one-sample test (only where the method defines one).
    var chance: Double?
    /// Section of the original result screen, English (optional).
    var section: String?
}

struct SessionMetricSummary: Codable {
    static let currentFormat = 1
    var format = SessionMetricSummary.currentFormat
    var cacheKey: String
    var analyzer: String
    var computedAt: Date
    var videoID: UUID
    var runFolder: String
    var phase: String
    var primaryKey: String
    var metrics: [SessionMetricEntry]
    var series: [FlowResultSeries] = []
    /// Quality warnings of the analysis (English).
    var qcFlags: [String] = []
    var windowStart: Double = 0
    var windowLength: Double = 0
    /// Detection rate (pose), tracked samples (classic centroid) or chamber coverage (TST), 0–1.
    var trackedFraction: Double?
    /// Pose model of the session's data (nil: classic centroid / multi-chamber, or a cache from before
    /// iOS build 19 / Mac build 15).
    var model: String?
    /// Version of the measure definitions the phone computed these numbers with (`currentDefinitions`); nil: RodentFlow
    /// 2.1 build 22 or earlier, or a summary made on the Mac. Packages are not re-sent when the phone refreshes stored
    /// numbers with newer definitions, so the Mac's consistency check uses this to explain the expected differences.
    var definitions: Int?
    /// 2 = RodentFlow 2.1 build 23 (censored Barnes / TST latencies, Y-maze returns, T-maze VTE from 10 choices, TST %
    /// of every recorded frame, classic tracked samples over the analysis window, series at bin centres).
    static let currentDefinitions = 2

    var values: [String: Double] {
        var out: [String: Double] = [:]
        for m in metrics {
            if let v = m.value, v.isFinite, out[m.key] == nil { out[m.key] = v }
        }
        return out
    }

    func value(_ key: String) -> Double? { values[key] }
    func entry(_ key: String) -> SessionMetricEntry? { metrics.first { $0.key == key } }
}

extension TaskMetricDef {
    init(_ e: SessionMetricEntry) {
        self.init(key: e.key, nameEN: e.nameEN, nameZH: e.nameZH, unit: e.unitEN, unitZH: e.unitZH,
                  decimals: e.decimals, chance: e.chance)
    }
}

// MARK: - Pose sessions

enum PoseMetricEntries {
    /// Version of the pose analysis that produced a summary (part of every cache key).
    static let analyzerVersion = "RodentFlow 2.1 pose analysis (shared engine)"

    /// Entries of a pose report: names in both languages, English units, chance levels.
    static func entries(_ report: AnalysisReport) -> [SessionMetricEntry] {
        var out: [SessionMetricEntry] = []
        var seen = Set<String>()
        for m in report.metrics where !seen.contains(m.key) {
            seen.insert(m.key)
            let value: Double? = (m.value?.isFinite ?? false) ? m.value : nil
            out.append(SessionMetricEntry(key: m.key,
                                          nameEN: L10n.metricLabel(m.title, key: m.key),
                                          nameZH: L10n.chinese(m.title),
                                          unitEN: L10n.english(m.unit),
                                          unitZH: L10n.chinese(m.unit),
                                          decimals: m.decimals,
                                          value: value,
                                          // The analysis defines the reference value (chance / no preference); the
                                          // fixed list only covers measures it does not mark.
                                          chance: m.reference ?? TaskMetricDefinitions.poseChance(m.key),
                                          section: nil))
        }
        return out
    }
}

// MARK: - Task-level definitions

enum TaskMetricDefinitions {
    /// Measures of a task, in the order of the result screens. Names are taken from the sessions of
    /// `preferredPhase` first (some pose measure names depend on the phase, e.g. NOR training vs test).
    static func defs(_ summaries: [SessionMetricSummary], preferredPhase: String?) -> [TaskMetricDef] {
        var order: [String] = []
        var byKey: [String: TaskMetricDef] = [:]
        let preferred = summaries.filter { preferredPhase == nil || $0.phase == preferredPhase }
        let rest = summaries.filter { !(preferredPhase == nil || $0.phase == preferredPhase) }
        for s in preferred + rest {
            for e in s.metrics where byKey[e.key] == nil {
                byKey[e.key] = TaskMetricDef(e)
                order.append(e.key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Primary measure for a phase: the one highlighted in most sessions of that phase.
    static func primaryKey(_ summaries: [SessionMetricSummary], phase: String) -> String {
        let pool = phase.isEmpty ? summaries : summaries.filter { $0.phase == phase }
        var counts: [String: Int] = [:]
        for s in pool where !s.primaryKey.isEmpty { counts[s.primaryKey, default: 0] += 1 }
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? ""
    }

    /// Reference values where the pose definition has a natural "no preference" value:
    /// preference / discrimination indices (a − b) / (a + b) → 0, RI (%) → 50, target quadrant (%) → 25.
    /// Used only when the user asks for a one-sample test, and only for measures whose MetricValue.reference
    /// (set by the analysis, build 23) is nil.
    static func poseChance(_ key: String) -> Double? {
        switch key {
        case "di", "di_20s", "sniff_index", "chamber_index", "turn_bias": return 0
        case "ri": return 50
        case "target_quadrant_pct": return 25
        default: return nil
        }
    }

    /// Within-animal pairs: RodentFlow's own pairs, and the same comparisons on the pose measures.
    static func pairs(_ assay: StudyAssay) -> [MetricPair] {
        if assay.flowAssay != nil { return TaskPairs.pairs(assay) }
        switch assay.paradigm {
        case .novelObject?:
            return [MetricPair(key: "novel_vs_familiar", nameEN: "Novel vs familiar exploration", nameZH: "新物体 vs 熟悉物体探索",
                               metricA: "exp_novel", metricB: "exp_familiar",
                               labelAEN: "Novel", labelAZH: "新物体", labelBEN: "Familiar", labelBZH: "熟悉物体")]
        case .threeChamber?:
            return [MetricPair(key: "stimulus_vs_other", nameEN: "Sniffing: stimulus vs other side", nameZH: "嗅探：刺激侧 vs 另一侧",
                               metricA: "sniff_stim", metricB: "sniff_other",
                               labelAEN: "Stimulus", labelAZH: "刺激侧", labelBEN: "Other", labelBZH: "另一侧")]
        case .elevatedPlusMaze?:
            return [MetricPair(key: "open_vs_closed", nameEN: "Open vs closed arm time", nameZH: "开放臂 vs 闭合臂时间",
                               metricA: "open_time", metricB: "closed_time",
                               labelAEN: "Open", labelAZH: "开放臂", labelBEN: "Closed", labelBZH: "闭合臂")]
        case .elevatedZeroMaze?:
            return [MetricPair(key: "open_vs_closed", nameEN: "Open vs closed segment time", nameZH: "开放段 vs 闭合段时间",
                               metricA: "open_time", metricB: "closed_time",
                               labelAEN: "Open", labelAZH: "开放段", labelBEN: "Closed", labelBZH: "闭合段")]
        case .waterMaze?:
            return [MetricPair(key: "target_vs_opposite", nameEN: "Target vs opposite quadrant", nameZH: "目标象限 vs 对侧象限",
                               metricA: "target_quadrant_pct", metricB: "opposite_quadrant_pct",
                               labelAEN: "Target", labelAZH: "目标", labelBEN: "Opposite", labelBZH: "对侧")]
        case .fearConditioning?:
            return [MetricPair(key: "baseline_vs_cs", nameEN: "Baseline vs CS freezing", nameZH: "基线 vs CS 僵直",
                               metricA: "freeze_baseline_pct", metricB: "freeze_cs_mean",
                               labelAEN: "Baseline", labelAZH: "基线", labelBEN: "CS", labelBZH: "CS")]
        default:
            return []
        }
    }

    /// What the group comparison needs to know about a task (measure names from `phase` first).
    static func context(assay: StudyAssay, summaries all: [SessionMetricSummary], phase: String?) -> GroupAnalysisContext {
        let defs = defs(all, preferredPhase: phase)
        let phases = assay.phaseOptions.map(\.key)
        return GroupAnalysisContext(assay: assay, defs: defs, pairs: pairs(assay), assayPhases: phases,
                                    primaryKey: { p in primaryKey(all, phase: p) },
                                    usesDays: assay.flowAssay?.usesDays ?? false)
    }
}
