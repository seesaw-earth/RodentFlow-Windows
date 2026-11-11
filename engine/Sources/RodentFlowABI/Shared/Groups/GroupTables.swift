// GroupTables.swift — what a group comparison exports besides its figure (RodentFlow 2.0: iOS build 15,
// Mac build 14), identical on both platforms:
//   • a statistics report: every test with statistic, df, p (raw and adjusted), effect size and 95% CI (CSV),
//     plus a Methods paragraph and a figure-legend draft (n per group, test, p) in English;
//   • a Prism table to paste into GraphPad Prism (tab separated: Column table for one factor, Grouped table for
//     two factors and for days / sessions / bins with one sub-column per animal);
//   • a long-format table (one row per animal and value) for R (tidyverse, lme4) or Python (pandas, statsmodels).
// Exports always pass a result computed with `english: true`.

import Foundation

enum GroupReportText {
    private static func tx(_ english: Bool, _ en: String, _ zh: String) -> String { english || !Lang.isChinese ? en : zh }

    // MARK: Lines for the summary text

    /// Effect sizes, two-way ANOVA, ANCOVA and assumption checks, one line each.
    static func detailLines(_ r: GroupAnalysisResult) -> [String] {
        let english = r.english
        var lines: [String] = []
        if !r.report.effects.isEmpty {
            lines.append(tx(english, "Effect sizes:", "效应量："))
            for e in r.report.effects {
                lines.append("  " + e.label + ": " + e.line + (e.note.map { " (\($0))" } ?? ""))
            }
        }
        if let tw = r.twoWay {
            lines.append(tw.methodSummary)
            for t in tw.terms { lines.append("  " + t.name + ": " + t.test(dfError: tw.dfError).reportLine) }
            for s in tw.simpleA + tw.simpleB { lines.append("  " + s.test.name + ": " + s.test.reportLine) }
            for c in tw.pairwiseA + tw.pairwiseB { lines.append("  " + pairLine(c, english: english)) }
        }
        if let a = r.ancova {
            lines.append(a.methodSummary)
            lines.append("  " + a.group.name + ": " + a.group.test(dfError: a.dfError).reportLine)
            lines.append("  " + a.covariate.name + ": " + a.covariate.test(dfError: a.dfError).reportLine
                         + String(format: tx(english, ", slope = %@ ± %@ (SE)", "，斜率 = %@ ± %@（SE）"), StatsFormat.number(a.slope), StatsFormat.number(a.slopeSE)))
            if let s = a.slopes { lines.append("  " + s.name + ": " + s.reportLine) }
            for m in a.adjusted {
                lines.append(String(format: tx(english, "  Adjusted mean %@: %@ ± %@ (SE), 95%% CI [%@, %@], n = %d", "  校正均值 %@：%@ ± %@（SE），95%% CI [%@, %@]，n = %d"),
                                    english ? m.group : groupDisplayName(m.group), StatsFormat.number(m.mean), StatsFormat.number(m.se),
                                    StatsFormat.number(m.low), StatsFormat.number(m.high), m.n))
            }
            for c in a.pairwise { lines.append("  " + pairLine(c, english: english)) }
            lines += a.notes.map { "  " + $0 }
        }
        if let a = r.assumptions {
            lines.append(tx(english, "Assumption checks:", "前提检查："))
            for n in a.normality + (a.residuals.map { [$0] } ?? []) {
                if let w = n.w, let p = n.p {
                    lines.append(String(format: tx(english, "  Shapiro–Wilk %@ (n = %d): W = %@, %@", "  Shapiro–Wilk %@（n = %d）：W = %@，%@"),
                                        n.label, n.n, StatsFormat.number(w), StatsFormat.p(p)))
                } else {
                    lines.append(String(format: tx(english, "  Shapiro–Wilk %@ (n = %d): not computable", "  Shapiro–Wilk %@（n = %d）：无法计算"), n.label, n.n))
                }
            }
            if let bf = a.spread { lines.append("  " + bf.name + ": " + bf.reportLine) }
            lines.append("  " + a.suggestion)
        }
        return lines
    }

    static func pairLine(_ c: PairwiseComparison, english: Bool) -> String {
        let level = c.level.map { " [\($0)]" } ?? ""
        // Fisher's exact tests have no test statistic (statisticName "").
        let statistic = c.statisticName.isEmpty ? "" : "\(c.statisticName) = \(StatsFormat.number(c.statistic)), "
        var line = (english ? c.groupA : groupDisplayName(c.groupA)) + " vs " + (english ? c.groupB : groupDisplayName(c.groupB)) + level
            + ": " + statistic + tx(english, "adjusted ", "校正后 ") + StatsFormat.p(c.pAdjusted)
        line += " " + StatsFormat.stars(c.pAdjusted)
        if let lo = c.ciLow, let hi = c.ciHigh {
            line += String(format: tx(english, "; difference %@ [95%% CI %@, %@]", "；差值 %@ [95%% CI %@, %@]"),
                           StatsFormat.number(c.difference), StatsFormat.number(lo), StatsFormat.number(hi))
        }
        return line
    }

    /// Each group's proportion with its Wilson 95% CI, one indented line per group.
    static func proportionLines(_ pr: ProportionTest, english: Bool) -> [String] {
        pr.rows.map { row in
            let w = row.wilson
            return String(format: tx(english, "  %@: %d/%d = %.0f%% (Wilson 95%% CI %.0f–%.0f%%)", "  %@：%d/%d = %.0f%%（Wilson 95%% CI %.0f–%.0f%%）"),
                          row.group, row.events, row.animals, row.proportion * 100, w.low * 100, w.high * 100)
        }
    }

    // MARK: Statistics report (CSV)

    private static func csv(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    private static func num(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.6g", v)
    }

    /// One row per test, term, comparison, effect size and check; task, measure and unit are repeated in the first
    /// columns so the file has a single header row (pandas.read_csv / readr::read_csv defaults). The last column
    /// (`role`, build 23) says which rows are the main analysis (listed first), which are secondary (not the result
    /// reported in the legend, e.g. a t-test of 0/1 values) and which are supporting (effect sizes, checks).
    static func statsReportCSV(_ r: GroupAnalysisResult, taskName: String) -> String {
        let header = ["section", "comparison", "test", "statistic", "value", "df1", "df2", "p", "p_adjusted",
                      "effect_size", "effect_value", "ci_low", "ci_high", "method", "role"]
        var mainRows: [[String]] = []
        var otherRows: [[String]] = []
        func add(_ row: [String], _ role: String) {
            if role == "main" { mainRows.append(row + [role]) } else { otherRows.append(row + [role]) }
        }
        func test(_ section: String, _ comparison: String, _ t: TestResult, method: String = "", role: String) {
            add([section, comparison, t.name, t.statisticName, num(t.statistic), num(t.df1), num(t.df2), num(t.p), "",
                 t.effectName ?? "", num(t.effect), "", "", method.isEmpty ? (t.note ?? "") : method], role)
        }
        func pair(_ section: String, _ c: PairwiseComparison, role: String) {
            let label = c.groupA + " vs " + c.groupB + (c.level.map { " [\($0)]" } ?? "")
            add([section, label, c.method, c.statisticName, c.statisticName.isEmpty ? "" : num(c.statistic), "", "", num(c.p), num(c.pAdjusted),
                 "difference", num(c.difference), num(c.ciLow), num(c.ciHigh), c.method], role)
        }
        let rep = r.report
        let standardRole = r.main == .standard ? "main" : "secondary"
        if r.main == .descriptive || r.main == .survivalUnavailable {
            add(["no test", "all groups", "", "", "", "", "", "", "", "", "", "", "", r.mainNote], "main")
        }
        if let o = rep.omnibus { test("omnibus", "all groups", o, method: rep.methodSummary, role: standardRole) }
        if let m = rep.mixed {
            if let g = m.group { test("mixed ANOVA", "group", g, role: standardRole) }
            test("mixed ANOVA", r.levelLabel.isEmpty ? "within" : r.levelLabel, m.level, role: standardRole)
            if let i = m.interaction { test("mixed ANOVA", "interaction", i, role: standardRole) }
        }
        for c in rep.pairwise { pair("pairwise", c, role: standardRole) }
        let perGroupRole = r.main == .standard || r.main == .descriptive ? "main" : "secondary"
        for g in rep.perGroup.keys.sorted() {
            if let t = rep.perGroup[g] { test("within group", g + " (" + rep.perGroupLabel + ")", t, role: perGroupRole) }
        }
        for e in rep.effects {
            add(["effect size", e.label, "", "", "", "", "", "", "", e.name, num(e.value), num(e.low), num(e.high), e.note ?? ""], "supporting")
        }
        if let s = r.survival {
            add(["survival", "all groups", "Log-rank test", "chi-square", num(s.chiSquare), String(s.df), "", num(s.p), "", "", "", "", "", s.reportLine],
                r.main == .survival ? "main" : "secondary")
        }
        if let pr = r.proportion {
            let role = r.main == .proportion ? "main" : "secondary"
            add(["proportion", "all groups", pr.name, pr.statistic == nil ? "" : "chi-square", num(pr.statistic), pr.df.map(String.init) ?? "", "", num(pr.p), "", "", "", "", "", pr.reportLine], role)
            for row in pr.rows {
                let w = row.wilson
                add(["proportion per group", row.group, "Wilson score interval", "percent", num(row.proportion * 100), "", "", "", "",
                     "", "", num(w.low * 100), num(w.high * 100), "\(row.events)/\(row.animals) animals"], role)
            }
            if pr.rows.count > 2 { for c in pr.pairwise { pair("proportion pairwise", c, role: role) } }
        }
        let modelRole = r.main == .twoWay || r.main == .ancova ? "main" : "secondary"
        if let tw = r.twoWay {
            for t in tw.terms { test("two-way ANOVA", t.name, t.test(dfError: tw.dfError), method: "Type III", role: modelRole) }
            for s in tw.simpleA + tw.simpleB { test("simple effect", s.factor + " at " + s.at, s.test, role: modelRole) }
            for c in tw.pairwiseA + tw.pairwiseB { pair("two-way pairwise", c, role: modelRole) }
        }
        if let a = r.ancova {
            test("ANCOVA", "group (adjusted)", a.group.test(dfError: a.dfError), method: "Type III", role: modelRole)
            test("ANCOVA", "covariate: " + a.covariateName, a.covariate.test(dfError: a.dfError), method: "slope \(num(a.slope)) ± \(num(a.slopeSE)) SE", role: modelRole)
            if let s = a.slopes { test("ANCOVA", "homogeneity of slopes", s, role: modelRole) }
            for m in a.adjusted {
                add(["ANCOVA adjusted mean", m.group, "", "mean", num(m.mean), "", "", "", "", "SE", num(m.se), num(m.low), num(m.high), "n = \(m.n)"], modelRole)
            }
            for c in a.pairwise { pair("ANCOVA pairwise", c, role: modelRole) }
        }
        if let a = r.assumptions {
            for n in a.normality + (a.residuals.map { [$0] } ?? []) {
                add(["assumption", n.label + " (n = \(n.n))", "Shapiro–Wilk test", "W", num(n.w), "", "", num(n.p), "", "", "", "", "", ""], "supporting")
            }
            if let bf = a.spread { test("assumption", "equal spread", bf, role: "supporting") }
            add(["assumption", "hint", "", "", "", "", "", "", "", "", "", "", "", a.suggestion], "supporting")
        }
        let rows = [header] + mainRows + otherRows
        let lines = rows.enumerated().map { (i, row) -> [String] in
            (i == 0 ? ["task", "measure", "unit"] : [taskName, r.metricName, r.unit]) + row
        }
        return lines.map { $0.map(csv).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    // MARK: Methods paragraph and figure legend (English)

    static func groupCounts(_ r: GroupAnalysisResult) -> String {
        r.groups.compactMap { g -> String? in
            guard let d = r.descriptives[g], d.n > 0 else { return nil }
            return "\(d.n) (\(g))"
        }.joined(separator: ", ")
    }

    private static func isRepeated(_ r: GroupAnalysisResult) -> Bool {
        [.byDay, .bySession, .withinSession].contains(r.request.design)
    }

    /// Animals behind each point of a curve, per group ("WT 4–6, KO 6").
    static func perLevelCounts(_ r: GroupAnalysisResult) -> String? {
        let parts = r.groups.compactMap { g -> String? in
            let ns = r.curves.filter { $0.group == g }.map(\.n)
            guard let lo = ns.min(), let hi = ns.max() else { return nil }
            let name = r.english ? g : groupDisplayName(g)
            return lo == hi ? "\(name) \(lo)" : "\(name) \(lo)–\(hi)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "The repeated-measures test used the n animals with a value at every bin; m … were left out."
    static func repeatedCountSentence(_ r: GroupAnalysisResult) -> String? {
        guard isRepeated(r), let used = r.report.animalsInTest else { return nil }
        let word = r.request.design == .withinSession && isBinned(r) ? tx(r.english, "bin", "时间段") : GroupAnalysisEngine.levelWord(r.levelLabel)
        var line = String(format: tx(r.english, "The repeated-measures test used the %d animals with a value at every %@", "重复测量检验纳入每个%2$@都有数值的 %1$d 只动物"), used, word)
        if r.report.animalsLeftOut > 0 {
            line += String(format: tx(r.english, "; %d animal(s) with a missing %@ were left out (they are still plotted).", "；%d 只缺少某个%@的动物未纳入（图中仍画出）。"),
                           r.report.animalsLeftOut, word)
        } else {
            line += tx(r.english, ".", "。")
        }
        return line
    }

    /// Series in time bins (the x label names the bin width, e.g. "Time (min), 1-min bins").
    static func isBinned(_ r: GroupAnalysisResult) -> Bool {
        r.levelLabel.lowercased().contains("bin") || r.levelLabel.contains("每段")
    }

    static func methodsParagraph(_ r: GroupAnalysisResult, taskName: String) -> String {
        var s: [String] = []
        s.append("Statistics (\(taskName), \(r.metricName)\(r.unit.isEmpty ? "" : ", \(r.unit)")). The animal was the experimental unit: sessions of the same animal were averaged first, so n is the number of animals (n = \(groupCounts(r))).")
        if r.censoredValuesAsObserved {
            s.append("This latency is right-censored at the cut-off for animals without the event; in this design the cut-off values were analysed as if observed, which tends to understate differences between groups.")
        }
        let perGroup = r.report.perGroupMethod
        switch r.main {
        case .standard:
            if !r.report.methodSummary.isEmpty { s.append(r.report.methodSummary) }
        case .proportion:
            if let pr = r.proportion {
                s.append(pr.df == nil ? "Because each animal scored 0 or 1, the proportions of the two groups were compared with Fisher's exact test (two-sided)."
                         : "Because each animal scored 0 or 1, the proportions were compared with a chi-square test of independence, followed by "
                           + (r.request.comparison == .versusControl ? "two-sided Fisher's exact tests of each group vs \(r.groups.first ?? "the first group") with Holm correction."
                              : "pairwise two-sided Fisher's exact tests with Holm correction."))
                s.append("Proportions are shown with Wilson score 95% confidence intervals."
                         + (r.report.omnibus != nil ? " A t / Mann–Whitney test of the 0/1 values is listed in stats_report.csv as a secondary analysis only." : ""))
            }
            if !perGroup.isEmpty { s.append(perGroup) }
        case .survival:
            s.append("Latencies without the event before the cut-off were treated as right-censored at the cut-off; groups were compared with Kaplan–Meier curves and the log-rank test."
                     + (r.report.omnibus != nil ? " A test of the latencies with the cut-off values entered as observed is listed in stats_report.csv as a secondary analysis only." : ""))
            if let w = r.survival?.withoutFlag, w > 0 {
                s.append("\(w) session(s) computed by an earlier version without the event indicator were left out of the Kaplan–Meier analysis.")
            }
        case .survivalUnavailable:
            s.append("Latencies without the event before the cut-off are right-censored at the cut-off. " + r.mainNote)
        case .twoWay:
            if let tw = r.twoWay { s.append(tw.methodSummary) }
            if let a = r.ancova { s.append(a.methodSummary) }
        case .ancova:
            if let a = r.ancova { s.append(a.methodSummary) }
        case .descriptive:
            s.append(r.mainNote)
            if !perGroup.isEmpty { s.append(perGroup) }
        }
        if let line = repeatedCountSentence(r) { s.append(line) }
        if r.assumptions != nil {
            s.append("Normality was examined with Shapiro–Wilk tests (per group and on the residuals) and equality of spread with the Brown–Forsythe test; these checks were descriptive and did not determine the test.")
        }
        var names: [String] = []
        if r.main == .standard {
            for e in r.report.effects where !names.contains(e.name) { names.append(e.name) }
        } else if r.main == .twoWay || r.main == .ancova {
            names.append("partial η²")
        }
        if !names.isEmpty {
            s.append("Effect sizes are reported as " + names.joined(separator: ", ") + ", with 95% confidence intervals where defined.")
        }
        if !r.models.isEmpty {
            s.append(r.models.count == 1 ? "Poses were estimated with the \(r.models[0]) model."
                     : "Poses were estimated with the \(r.models.joined(separator: ", ")) models (model of each animal in long_format.csv).")
        }
        let hasTest = !(r.main == .descriptive || r.main == .survivalUnavailable) || !r.report.perGroup.isEmpty
        if hasTest {
            s.append("Tests were two-tailed with α = 0.05; p values of multiple comparisons are adjusted as stated.")
            s.append("No correction was applied across the measures of the task or across repeated looks at the data; these are exploratory statistics to be confirmed with a pre-specified analysis.")
        }
        s.append("Analyses were performed with \(AppInfo.name) \(AppInfo.version).")
        return s.joined(separator: " ")
    }

    /// Per-group tests in one clause ("Within groups (change vs 0): WT: Paired t-test, t(5) = …").
    static func perGroupLine(_ r: GroupAnalysisResult) -> String? {
        let parts = r.report.perGroup.keys.sorted().compactMap { g in
            r.report.perGroup[g].map { "\(r.english ? g : groupDisplayName(g)): \($0.name), \($0.reportLine)" }
        }
        guard !parts.isEmpty else { return nil }
        return String(format: tx(r.english, "Within groups (%@): ", "组内（%@）："), r.report.perGroupLabel) + parts.joined(separator: "; ")
    }

    /// The main result in one line, in the result's language: the legend, the line under the figure on both
    /// platforms and summary.txt all use it.
    static func mainTestLine(_ r: GroupAnalysisResult) -> String? {
        let english = r.english
        switch r.main {
        case .descriptive, .survivalUnavailable:
            var line = r.mainNote
            if let pg = perGroupLine(r) { line += (line.isEmpty ? "" : " ") + pg }
            return line.isEmpty ? nil : line
        case .survival:
            guard let sv = r.survival, let p = sv.p, let chi = sv.chiSquare else { return nil }
            // The n of the Kaplan–Meier analysis itself (sessions without the event flag are left out of it).
            let counts = sv.groups.map { g in
                (g.group.isEmpty ? tx(english, "Ungrouped", "未分组") : g.group) + " \(g.n)"
            }.joined(separator: ", ")
            var line = tx(english, "Log-rank test (Kaplan–Meier, n = ", "Log-rank 检验（Kaplan–Meier，n = ") + counts + tx(english, ")", "）")
                + ", χ²(\(sv.df)) = \(StatsFormat.number(chi)), \(StatsFormat.p(p))"
            if sv.withoutFlag > 0 {
                line += String(format: tx(english, "; %d session(s) without the event flag (computed by an older version) left out",
                                          "；%d 次实验缺少事件记录（旧版本计算），未纳入"), sv.withoutFlag)
            }
            return line
        case .proportion:
            guard let pr = r.proportion else { return nil }
            let counts = pr.rows.map { "\($0.group) \($0.events)/\($0.animals)" }.joined(separator: ", ")
            var line = (pr.df == nil ? tx(english, "Fisher's exact test, two-sided", "Fisher 精确检验（双侧）") : pr.name) + " (" + counts + ")"
            if let st = pr.statistic, let df = pr.df { line += ", χ²(\(df)) = \(StatsFormat.number(st))" }
            return line + ", " + StatsFormat.p(pr.p)
        case .twoWay:
            guard let tw = r.twoWay else { return nil }
            var line = tw.terms.map { "\($0.name): \($0.test(dfError: tw.dfError).reportLine)" }.joined(separator: "; ")
            if let a = r.ancova { line += "; ANCOVA, \(a.group.name): \(a.group.test(dfError: a.dfError).reportLine)" }
            return line
        case .ancova:
            guard let a = r.ancova else { return nil }
            return "ANCOVA, \(a.group.name): \(a.group.test(dfError: a.dfError).reportLine)"
        case .standard:
            if let o = r.report.omnibus {
                var line = "\(o.name), \(o.reportLine)"
                if let e = r.report.effects.first(where: { $0.low != nil && $0.name != "Mean difference" && $0.name != "均值差" }) ?? r.report.effects.first {
                    line += "; \(e.line)"
                }
                if r.request.design == .phaseChange, let pg = perGroupLine(r) { line += "; " + pg }
                return line
            }
            if let m = r.report.mixed {
                var parts: [String] = []
                if let g = m.group { parts.append(tx(english, "group ", "组 ") + g.reportLine) }
                parts.append("\(r.levelLabel.isEmpty ? tx(english, "within", "组内") : GroupAnalysisEngine.levelWord(r.levelLabel)) \(m.level.reportLine)")
                if let i = m.interaction { parts.append(tx(english, "interaction ", "交互作用 ") + i.reportLine) }
                return tx(english, "Mixed ANOVA: ", "混合方差分析：") + parts.joined(separator: "; ")
            }
            return perGroupLine(r)
        }
    }

    /// Main test line of a result for a legend (kept for callers of RodentFlow 2.0).
    static func legendTestLine(_ r: GroupAnalysisResult) -> String? { mainTestLine(r) }

    /// Comparisons that may get brackets over the groups: those of the main analysis only (none for models,
    /// Kaplan–Meier, and when no between-groups test was run).
    static func bracketComparisons(_ r: GroupAnalysisResult) -> [PairwiseComparison] {
        guard r.request.design == .betweenGroups || r.request.design == .phaseChange else { return [] }
        switch r.main {
        case .standard: return r.report.pairwise.filter { $0.level == nil }
        case .proportion: return r.proportion?.pairwise ?? []
        default: return []
        }
    }

    /// What the marks of the figure show, in the result's language (legend draft and the caption under the figure).
    static func marksDescription(_ r: GroupAnalysisResult, style: GroupPlotStyle, showAnimals: Bool = false) -> String {
        let english = r.english
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            if r.main == .proportion, r.proportion != nil {
                var t = (style.kind == .barDots ? tx(english, "Bars show", "柱高为") : tx(english, "Points show", "点为"))
                    + tx(english, " the percentage of animals with the outcome in each group, with Wilson 95% confidence intervals; numbers under the groups are animals with the outcome / animals.",
                         "各组出现该结果的动物百分比，误差线为 Wilson 95% 置信区间；组名下方为出现该结果的动物数 / 动物数。")
                if style.showPoints { t += tx(english, " Each dot is one animal (0 or 100%).", "每个点为一只动物（0 或 100%）。") }
                return t
            }
            var t = style.legendDescription(english: english)
            if r.main == .survival || r.main == .survivalUnavailable {
                t += tx(english, " Latencies without the event are drawn at the cut-off (censored values).", "未发生事件的潜伏期画在截止时间（截尾值）。")
            }
            if r.request.design == .phaseChange {
                t += tx(english, " The dashed line marks no change (0).", "虚线表示无变化（0）。")
            } else if r.request.testAgainstChance, let c = r.chance {
                t += String(format: tx(english, " The dashed line marks the reference value (%@).", "虚线为参考值（%@）。"), StatsFormat.number(c))
            }
            return t
        case .byDay, .bySession, .withinSession:
            let err = style.error.legendText(english: english)
            var t: String
            if r.request.design == .withinSession && isBinned(r) {
                t = String(format: tx(english, "Points show the %@ of each group in each bin, plotted at the bin centre.", "点和误差线为各组每段的%@，画在每段的中点。"), err)
            } else {
                let word = GroupAnalysisEngine.levelWord(r.levelLabel)
                t = english || !Lang.isChinese ? "Points show the \(err) of each group at each \(word)." : "点和误差线为各组在每个\(word)的\(err)。"
            }
            if showAnimals { t += tx(english, " Thin lines are individual animals.", "细线为每只动物。") }
            return t
        case .pairedMeasures:
            return tx(english, "Lines join the two values of each animal; short bars mark the group means.", "连线连接每只动物的两个值；短横线为组均值。")
        }
    }

    static func figureLegend(_ r: GroupAnalysisResult, taskName: String, style: GroupPlotStyle, phase: String? = nil,
                             showAnimals: Bool = false) -> String {
        var s: [String] = []
        let what = r.unit.isEmpty ? r.metricName : "\(r.metricName) (\(r.unit))"
        s.append("\(what) in the \(taskName)" + (phase.map { $0.isEmpty ? "" : ", \($0)" } ?? "") + ".")
        s.append(marksDescription(r, style: style, showAnimals: showAnimals))
        s.append("n = \(groupCounts(r)) animals.")
        if isRepeated(r), let counts = perLevelCounts(r) { s.append("Animals per point: \(counts).") }
        if let line = mainTestLine(r) { s.append(line.hasSuffix(".") ? line : line + ".") }
        if r.censoredValuesAsObserved {
            s.append("Censored latency: animals without the event are plotted and tested at the cut-off.")
        }
        if let line = repeatedCountSentence(r) { s.append(line) }
        let comps = bracketComparisons(r)
        if style.showSignificance && !comps.isEmpty {
            let method = comps.first?.method ?? ""
            if !comps.contains(where: { style.bracketed($0.pAdjusted) }) {
                s.append("No pairwise comparison (\(method)) reached p < 0.05, so no brackets are drawn.")
            } else {
                s.append(style.significance == .stars
                         ? "Brackets: pairwise comparisons (\(method)); *p < 0.05, **p < 0.01, ***p < 0.001, ****p < 0.0001\(style.showNonsignificant ? ", ns = not significant" : "")."
                         : "Brackets: adjusted p values of pairwise comparisons (\(method)).")
            }
        }
        if r.survival != nil && (r.main == .survival || r.main == .survivalUnavailable) {
            s.append("Kaplan–Meier curves (kaplan_meier.*): proportion of animals without the event over time; "
                     + (style.grayscale ? "open symbols" : "+") + " = censored at the cut-off.")
        }
        return s.joined(separator: " ")
    }

    // MARK: Prism (tab separated)

    /// GraphPad Prism table. Column table (one column per group) for one factor and paired measures;
    /// Grouped table for two factors (rows = factor B, columns = factor A with one sub-column per animal) and
    /// for days / sessions / bins (rows = levels, one sub-column per animal, matched across rows).
    static func prismTable(_ r: GroupAnalysisResult) -> String {
        func cell(_ v: Double?) -> String { v.map { String(format: "%.6g", $0) } ?? "" }
        var lines: [String] = []
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            if let tw = r.twoWay {
                // Grouped: rows = levels of B; one data set per level of A with replicate sub-columns.
                var reps: [String: Int] = [:]
                for c in tw.cells { reps[c.a] = max(reps[c.a] ?? 0, c.n) }
                var header = [tw.factorB]
                for a in tw.levelsA { header += [String](repeating: a, count: reps[a] ?? 1) }
                lines.append(header.joined(separator: "\t"))
                let values = cellValues(r, tw)
                for b in tw.levelsB {
                    var row = [b]
                    for a in tw.levelsA {
                        let v = values[a + "|" + b] ?? []
                        for k in 0..<(reps[a] ?? 1) { row.append(k < v.count ? cell(v[k]) : "") }
                    }
                    lines.append(row.joined(separator: "\t"))
                }
            } else {
                let cols = r.groups.map { g in r.points.filter { $0.group == g }.map(\.value) }
                lines.append(r.groups.joined(separator: "\t"))
                let n = cols.map(\.count).max() ?? 0
                for i in 0..<n { lines.append(cols.map { i < $0.count ? cell($0[i]) : "" }.joined(separator: "\t")) }
            }
        case .pairedMeasures:
            var header: [String] = []
            var cols: [[Double]] = []
            for g in r.groups {
                let pts = r.paired.filter { $0.group == g }
                guard !pts.isEmpty else { continue }
                header += [g + " · " + r.pairLabelA, g + " · " + r.pairLabelB]
                cols += [pts.map(\.a), pts.map(\.b)]
            }
            lines.append(header.joined(separator: "\t"))
            let n = cols.map(\.count).max() ?? 0
            for i in 0..<n { lines.append(cols.map { i < $0.count ? cell($0[i]) : "" }.joined(separator: "\t")) }
        case .byDay, .bySession, .withinSession:
            var header = [r.levelLabel.isEmpty ? "Level" : r.levelLabel]
            var series: [SubjectSeries] = []
            for g in r.groups {
                let s = r.subjectSeries.filter { $0.group == g }
                header += s.map { _ in g }
                series += s
            }
            lines.append(header.joined(separator: "\t"))
            for (j, level) in r.levels.enumerated() {
                var row = [String(format: "%.6g", level)]
                for s in series { row.append(j < s.values.count ? cell(s.values[j]) : "") }
                lines.append(row.joined(separator: "\t"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Values of each two-way cell ("a|b"), from the animal values of the result.
    private static func cellValues(_ r: GroupAnalysisResult, _ tw: TwoWayReport) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        let split = r.request.factorB == .groupSplit ? GroupAnalysisEngine.groupSplit(r.groups) : nil
        for p in r.points {
            let a: String, b: String
            if let split, let parts = split.parts[p.group] {
                a = parts[0]
                b = parts[1]
            } else if r.request.factorB == .sex, let sx = r.animalSex[p.group + "|" + p.subject] {
                a = r.english ? p.group : groupDisplayName(p.group)
                b = GroupAnalysisEngine.sexLabel(sx, english: r.english)
            } else {
                continue
            }
            out[a + "|" + b, default: []].append(p.value)
        }
        return out
    }

    // MARK: Long format (R / Python)

    static func longFormatCSV(_ r: GroupAnalysisResult, taskName: String) -> String {
        func q(_ s: String) -> String { csv(s) }
        func v(_ x: Double?) -> String { num(x) }
        var lines: [String] = []
        let phase = r.request.phaseFilter ?? ""
        let measureKey = r.request.design == .withinSession ? r.request.seriesKey : r.request.metricKey
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            let split = r.request.factorB == .groupSplit ? GroupAnalysisEngine.groupSplit(r.groups) : nil
            let covKey = r.ancova?.covariateKey ?? r.request.covariateKey
            lines.append("task,design,measure_key,measure,unit,phase,group,factor_a,factor_b,sex,animal_id,value,sessions_averaged,covariate_key,covariate,model")
            for p in r.points {
                let key = p.group + "|" + p.subject
                let parts = split?.parts[p.group]
                let row: [String] = [q(taskName), r.request.design.rawValue, q(measureKey), q(r.metricName), q(r.unit), q(phase), q(p.group),
                                     q(parts?[0] ?? ""), q(parts?[1] ?? ""), q(r.animalSex[key] ?? ""), q(p.subject), v(p.value), String(p.records),
                                     q(r.covariateValues.isEmpty ? "" : covKey), v(r.covariateValues[key]), q(r.animalModel[key] ?? "")]
                lines.append(row.joined(separator: ","))
            }
        case .byDay, .bySession, .withinSession:
            lines.append("task,design,measure_key,measure,unit,phase,group,sex,animal_id,level_name,level,value,model")
            for s in r.subjectSeries {
                for (j, value) in s.values.enumerated() {
                    guard let value, j < r.levels.count else { continue }
                    let row: [String] = [q(taskName), r.request.design.rawValue, q(measureKey), q(r.metricName), q(r.unit), q(phase), q(s.group),
                                         q(r.animalSex[s.group + "|" + s.subject] ?? ""), q(s.subject), q(r.levelLabel), v(r.levels[j]), v(value),
                                         q(r.animalModel[s.group + "|" + s.subject] ?? "")]
                    lines.append(row.joined(separator: ","))
                }
            }
        case .pairedMeasures:
            lines.append("task,design,pair,phase,group,sex,animal_id,condition,value,model")
            for p in r.paired {
                let sex = r.animalSex[p.group + "|" + p.subject] ?? ""
                for (label, value) in [(r.pairLabelA, p.a), (r.pairLabelB, p.b)] {
                    let row: [String] = [q(taskName), r.request.design.rawValue, q(r.metricName), q(phase), q(p.group), q(sex), q(p.subject), q(label), v(value),
                                         q(r.animalModel[p.group + "|" + p.subject] ?? "")]
                    lines.append(row.joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// How to use the exported tables (README next to them).
    static func readme(taskName: String) -> String {
        """
        \(taskName) — group comparison export (\(AppInfo.name) \(AppInfo.version))

        figure.pdf / figure.svg / figure_*dpi.png   The figure at the chosen journal width (vector PDF / SVG; PNG at 300 or 600 dpi).
        figure_source_data.csv                      The values drawn in the figure (one row per animal).
        figure_legend.txt                           Draft legend: what the marks show, n per group, test and p.
        stats_report.csv                            Every test: statistic, df, p (raw and adjusted), effect size, 95% CI, method
                                                    (task, measure and unit in the first columns). Column "role": main =
                                                    the analysis reported in the legend (rows first), secondary = other
                                                    tests (not the result), supporting = effect sizes and checks.
        methods.txt                                 Methods paragraph for the statistics.
        prism_table.txt                             Tab-separated table for GraphPad Prism: copy everything and paste into a new
                                                    Column table (one factor, paired measures) or Grouped table (two factors;
                                                    days / sessions / bins with one sub-column per animal).
        long_format.csv                             One row per animal (and level): read with R (readr::read_csv) or Python
                                                    (pandas.read_csv) for your own models. The last column
                                                    is the pose model that tracked the animal (empty for
                                                    the classic centroid tracker and multi-chamber TST).
        summary.txt                                 Everything above as plain text.

        n = animals: sessions of the same animal were averaged before the statistics.
        """
    }
}
