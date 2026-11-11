// Survival.swift — Kaplan–Meier curves and the log-rank test for latencies with a cut-off (RodentFlow 2.0:
// iOS build 14, Mac build 13). A latency that ends at the cut-off without the event (no escape, no entry, no
// attack) is right-censored; a t-test on such values is biased, the log-rank test is not.

import Foundation

struct SurvivalPoint: Codable, Hashable {
    var group: String
    var time: Double
    var survival: Double
}

struct SurvivalGroupSummary: Codable, Hashable {
    var group: String
    var n: Int
    var events: Int
    /// Time at which half of the animals had the event (nil when fewer than half had it).
    var median: Double?
}

struct SurvivalResult: Codable, Hashable {
    var eventName = ""
    var steps: [SurvivalPoint] = []
    var censored: [SurvivalPoint] = []
    var groups: [SurvivalGroupSummary] = []
    var chiSquare: Double?
    var df = 0
    var p: Double?
    var reportLine = ""
    /// Sessions left out because they have the latency but no event flag (computed by an older version).
    var withoutFlag = 0
}

/// Latency measures with a cut-off: the measure and the 0/1 (or 0/100) event that ends it.
enum SurvivalSpecs {
    struct Spec {
        var eventKey: String
        var eventEN: String
        var eventZH: String
    }

    static func spec(_ assay: StudyAssay, metric: String) -> Spec? {
        switch (assay, metric) {
        case (.poseMorrisWaterMaze, "escape_latency"): return Spec(eventKey: "found_platform_pct", eventEN: "platform found", eventZH: "找到平台")
        case (.posePassiveAvoidance, "entry_latency"): return Spec(eventKey: "entered_pct", eventEN: "entered the dark side", eventZH: "进入暗室")
        case (.poseResidentIntruder, "attack_latency"): return Spec(eventKey: "attack_occurred", eventEN: "attack", eventZH: "发生攻击")
        case (.poseNoveltySuppressedFeeding, "feeding_latency"): return Spec(eventKey: "ate_pct", eventEN: "first bite", eventZH: "开始进食")
        case (.poseStepDown, "step_down_latency"): return Spec(eventKey: "stepped_down", eventEN: "stepped down", eventZH: "下台")
        case (.poseVisualCliff, "deep_latency"): return Spec(eventKey: "entered_deep", eventEN: "entered the deep side", eventZH: "进入深侧")
        case (.poseBarnesMaze, "primary_latency"): return Spec(eventKey: "found_target", eventEN: "found the target hole", eventZH: "找到目标洞")
        case (.tstMultiChamber, "tst_latency_s"): return Spec(eventKey: "tst_became_immobile", eventEN: "became immobile", eventZH: "出现不动")
        default: return nil
        }
    }
}

enum Survival {
    /// Kaplan–Meier step points (starting at 1 at t = 0) and censoring marks of one group.
    static func kaplanMeier(_ obs: [(time: Double, event: Bool)]) -> (steps: [(Double, Double)], censored: [(Double, Double)]) {
        let sorted = obs.filter { $0.time.isFinite }.sorted { ($0.time, $0.event ? 0 : 1) < ($1.time, $1.event ? 0 : 1) }
        var s = 1.0
        var atRisk = sorted.count
        var steps: [(Double, Double)] = [(0, 1)]
        var censored: [(Double, Double)] = []
        var i = 0
        while i < sorted.count {
            let t = sorted[i].time
            var d = 0, c = 0
            while i < sorted.count && sorted[i].time == t {
                if sorted[i].event { d += 1 } else { c += 1 }
                i += 1
            }
            if d > 0 && atRisk > 0 {
                steps.append((t, s))
                s *= 1 - Double(d) / Double(atRisk)
                steps.append((t, s))
            }
            if c > 0 { censored.append((t, s)) }
            atRisk -= d + c
        }
        if let last = sorted.last?.time, (steps.last?.0 ?? 0) < last { steps.append((last, s)) }
        return (steps, censored)
    }

    static func median(_ steps: [(Double, Double)]) -> Double? {
        steps.first { $0.1 <= 0.5 }?.0
    }

    /// Log-rank test for k groups: chi-square with k − 1 degrees of freedom.
    static func logRank(_ groups: [[(time: Double, event: Bool)]]) -> (chi2: Double, df: Int, p: Double)? {
        let k = groups.count
        guard k >= 2 else { return nil }
        let times = Set(groups.flatMap { g in g.filter { $0.event }.map { $0.time } }).sorted()
        guard !times.isEmpty else { return nil }
        let m = k - 1
        var oe = [Double](repeating: 0, count: m)
        var v = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for t in times {
            let n = groups.map { g in Double(g.filter { $0.time >= t }.count) }
            let d = groups.map { g in Double(g.filter { $0.time == t && $0.event }.count) }
            let nt = n.reduce(0, +), dt = d.reduce(0, +)
            guard nt > 0 else { continue }
            for g in 0..<m {
                oe[g] += d[g] - dt * n[g] / nt
                guard nt > 1 else { continue }
                let f = dt * (nt - dt) / (nt - 1)
                for h in 0..<m {
                    v[g][h] += f * n[g] / nt * ((g == h ? 1 : 0) - n[h] / nt)
                }
            }
        }
        // chi2 = oeᵀ V⁻¹ oe (Gaussian elimination on [V | oe]).
        var a = v
        var b = oe
        for col in 0..<m {
            var pivot = col
            for r in col..<m where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(pivot, col)
            b.swapAt(pivot, col)
            for r in 0..<m where r != col {
                let f = a[r][col] / a[col][col]
                guard f != 0 else { continue }
                for c2 in col..<m { a[r][c2] -= f * a[col][c2] }
                b[r] -= f * b[col]
            }
        }
        var chi2 = 0.0
        for g in 0..<m { chi2 += oe[g] * b[g] / a[g][g] }
        guard chi2.isFinite, chi2 >= 0 else { return nil }
        return (chi2, m, Distributions.chiSquareSF(chi2, df: Double(m)))
    }

    /// Survival analysis of a between-groups comparison (one record per animal).
    static func analyse(records: [GroupRecord], groups: [String], metric: String, spec: SurvivalSpecs.Spec,
                        english: Bool) -> (result: SurvivalResult?, note: String?) {
        func tx(_ en: String, _ zh: String) -> String { english || !Lang.isChinese ? en : zh }
        var perSubject: [String: Int] = [:]
        for r in records { perSubject[r.displayGroup + "|" + r.subjectKey, default: 0] += 1 }
        if perSubject.values.contains(where: { $0 > 1 }) {
            return (nil, tx("Survival analysis needs one session per animal: filter to one phase / day / session to see Kaplan–Meier curves.",
                            "生存分析需要每只动物一条记录：请筛选到一个阶段 / 一天 / 一次实验，即可看到 Kaplan–Meier 曲线。"))
        }
        var result = SurvivalResult()
        result.eventName = english || !Lang.isChinese ? spec.eventEN : spec.eventZH
        var data: [[(time: Double, event: Bool)]] = []
        var used: [String] = []
        // Sessions computed before the event flag existed cannot say whether the latency is censored.
        var withoutFlag = 0
        for g in groups {
            let obs = records.filter { $0.displayGroup == g }.compactMap { r -> (time: Double, event: Bool)? in
                guard let t = r.metrics[metric], t.isFinite else { return nil }
                guard let e = r.metrics[spec.eventKey] else { withoutFlag += 1; return nil }
                return (t, e > 0)
            }
            guard !obs.isEmpty else { continue }
            used.append(g)
            data.append(obs)
            let km = kaplanMeier(obs)
            result.steps += km.steps.map { SurvivalPoint(group: g, time: $0.0, survival: $0.1) }
            result.censored += km.censored.map { SurvivalPoint(group: g, time: $0.0, survival: $0.1) }
            result.groups.append(SurvivalGroupSummary(group: g, n: obs.count, events: obs.filter { $0.event }.count, median: median(km.steps)))
        }
        let flagNote = withoutFlag == 0 ? nil : String(format: tx("%d session(s) without the event flag (computed by an older version; open them to recompute) were left out of the Kaplan–Meier analysis.",
                                                                  "%d 次实验没有“是否发生事件”的记录（由旧版本计算；打开即可重新计算），未纳入 Kaplan–Meier 分析。"), withoutFlag)
        result.withoutFlag = withoutFlag
        guard !used.isEmpty else { return (nil, flagNote) }
        var line = tx("Kaplan–Meier", "Kaplan–Meier") + " · " + result.groups.map { s in
            let med = s.median.map { String(format: "%.1f s", $0) } ?? tx("not reached", "未达到")
            return String(format: tx("%@: %d/%d with event, median %@", "%@：%d/%d 发生，中位 %@"), (s.group.isEmpty ? tx("Ungrouped", "未分组") : s.group), s.events, s.n, med)
        }.joined(separator: "; ")
        if let lr = logRank(data) {
            result.chiSquare = lr.chi2
            result.df = lr.df
            result.p = lr.p
            line += String(format: " · log-rank χ²(%d) = %@, %@", lr.df, StatsFormat.number(lr.chi2), StatsFormat.p(lr.p))
        }
        result.reportLine = line
        return (result, flagNote)
    }
}
