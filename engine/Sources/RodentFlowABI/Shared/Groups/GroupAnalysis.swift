// GroupAnalysis.swift — group comparison of a task's animals, identical on iPhone / iPad and Mac.
//
// Port of RodentFlow iOS 1.3 GroupAnalysis.swift, generalized from RodentFlow records to the sessions of
// any task (pose, two-animal pose, classic centroid, multi-chamber TST). The rules are RodentFlow's:
//   • the animal is the experimental unit (n = animals); several sessions of one animal are averaged
//     within the animal first;
//   • phases are never pooled by default; excluded sessions are left out unless asked;
//   • the first included group is the control for "vs. first group" comparisons;
//   • tests: Welch t / Mann–Whitney (2 groups), one-way ANOVA + Tukey–Kramer or Welch + Holm vs control /
//     Kruskal–Wallis + Dunn–Holm (≥ 3 groups), mixed ANOVA with Greenhouse–Geisser for repeated levels,
//     paired t / Wilcoxon for within-animal pairs.
// Added in the desktop app: a session-number filter and an "across sessions" design (level = 实验次数).
// Text is produced in English when `english` is true (exports) and in the interface language otherwise.
// The phone and the Mac compile this same file, so the same records give the same statistics.

import Foundation

// MARK: - Request / result types

enum GroupDesign: String, CaseIterable, Codable, Identifiable {
    case betweenGroups = "between_groups"
    case bySession = "by_session"
    case byDay = "by_day"
    case withinSession = "within_session"
    case pairedMeasures = "paired_measures"
    case phaseChange = "phase_change"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .betweenGroups: return L("Compare groups", "组间比较")
        case .bySession: return L("Across sessions", "按实验次数")
        case .byDay: return L("Across days", "按天")
        case .withinSession: return L("Time course", "时间进程")
        case .pairedMeasures: return L("Paired measures", "配对指标")
        case .phaseChange: return L("Change between phases", "阶段间变化")
        }
    }

    var explanation: String {
        switch self {
        case .betweenGroups: return L("One value per animal (sessions averaged within animal).", "每只小鼠一个值（同一小鼠的多次实验先取平均）。")
        case .bySession: return L("One value per animal per session number (实验次数): learning across sessions.", "每只小鼠每个实验次数一个值：跨实验次数的变化。")
        case .byDay: return L("Learning curve: one value per animal per day (trials averaged within day).", "学习曲线：每只小鼠每天一个值（同一天的试次先取平均）。")
        case .withinSession: return L("Series stored in each session: time bins, CS presentations.", "每次实验内的序列：时间段、CS 呈现。")
        case .pairedMeasures: return L("Two measures from the same animal, e.g. novel vs familiar.", "同一小鼠的两个指标，如新物体 vs 熟悉物体。")
        case .phaseChange: return L("Per-animal difference between two phases, e.g. test − pre-test.", "每只小鼠两个阶段之差，如 测试 − 预测试。")
        }
    }
}

enum StatMode: String, CaseIterable, Codable, Identifiable {
    case parametric
    case nonparametric
    var id: String { rawValue }
    var displayName: String { self == .parametric ? L("Parametric", "参数检验") : L("Non-parametric", "非参数检验") }
}

enum ComparisonMode: String, CaseIterable, Codable, Identifiable {
    case allPairs = "all_pairs"
    case versusControl = "versus_control"
    var id: String { rawValue }
    var displayName: String { self == .allPairs ? L("All pairs", "两两比较") : L("Vs. first group", "与第一组比较") }
}

/// A measure of a task, with names in both languages (English goes into exports).
struct TaskMetricDef: Codable, Hashable, Identifiable {
    var key: String
    var nameEN: String
    var nameZH: String
    var unit: String
    var unitZH: String
    var decimals: Int
    /// Reference value for an optional one-sample test (e.g. DI vs 0, quadrant vs 25%).
    var chance: Double?

    var id: String { key }
    var name: String { Lang.isChinese && !nameZH.isEmpty ? nameZH : nameEN }
    var displayUnit: String { Lang.isChinese && !unitZH.isEmpty ? unitZH : unit }
    var axisTitle: String { displayUnit.isEmpty ? name : "\(name) (\(displayUnit))" }
    var exportHeader: String { unit.isEmpty ? nameEN : "\(nameEN) (\(unit))" }

    func title(english: Bool) -> String { english ? nameEN : name }
    func unitText(english: Bool) -> String { english ? unit : displayUnit }

    func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let number = String(format: "%.\(decimals)f", value)
        let u = displayUnit
        if u.isEmpty { return number }
        return u == "%" ? number + "%" : number + " " + u
    }
}

/// Two measures of the same animal compared within animal (RodentFlow AssayKind.withinPairs).
struct MetricPair: Codable, Hashable, Identifiable {
    var key: String
    var nameEN: String
    var nameZH: String
    var metricA: String
    var metricB: String
    var labelAEN: String
    var labelAZH: String
    var labelBEN: String
    var labelBZH: String
    var id: String { key }

    func title(english: Bool) -> String { english || !Lang.isChinese ? nameEN : nameZH }
    func labelA(english: Bool) -> String { english || !Lang.isChinese ? labelAEN : labelAZH }
    func labelB(english: Bool) -> String { english || !Lang.isChinese ? labelBEN : labelBZH }
}

enum TaskPairs {
    /// RodentFlow 1.3 within-animal pairs of the video assays.
    static func pairs(_ assay: StudyAssay) -> [MetricPair] {
        guard let flow = assay.flowAssay else { return [] }
        switch flow {
        case .novelObject:
            return [MetricPair(key: "novel_vs_familiar", nameEN: "Novel vs familiar exploration", nameZH: "新物体 vs 熟悉物体探索",
                               metricA: "novel_time_s", metricB: "familiar_time_s",
                               labelAEN: "Novel", labelAZH: "新物体", labelBEN: "Familiar", labelBZH: "熟悉物体")]
        case .placePreference:
            return [MetricPair(key: "paired_vs_unpaired", nameEN: "Paired vs unpaired side", nameZH: "配对侧 vs 非配对侧",
                               metricA: "paired_time_s", metricB: "unpaired_time_s",
                               labelAEN: "Paired", labelAZH: "配对侧", labelBEN: "Unpaired", labelBZH: "非配对侧")]
        case .morrisWaterMaze, .barnesMaze:
            return [MetricPair(key: "target_vs_opposite", nameEN: "Target vs opposite quadrant", nameZH: "目标象限 vs 对侧象限",
                               metricA: "target_quadrant_pct", metricB: "opposite_quadrant_pct",
                               labelAEN: "Target", labelAZH: "目标", labelBEN: "Opposite", labelBZH: "对侧")]
        case .fearConditioning:
            return [MetricPair(key: "baseline_vs_cs", nameEN: "Baseline vs CS freezing", nameZH: "基线 vs CS 僵直",
                               metricA: "baseline_freezing_pct", metricB: "cs_freezing_pct",
                               labelAEN: "Baseline", labelAZH: "基线", labelBEN: "CS", labelBZH: "CS")]
        case .elevatedPlusMaze:
            return [MetricPair(key: "open_vs_closed", nameEN: "Open vs closed arm time", nameZH: "开放臂 vs 闭合臂时间",
                               metricA: "open_time_s", metricB: "closed_time_s",
                               labelAEN: "Open", labelAZH: "开放臂", labelBEN: "Closed", labelBZH: "闭合臂")]
        default:
            return []
        }
    }

    /// RodentFlow AssayKind.analysisDefaultPhase.
    static func analysisDefaultPhase(_ assay: StudyAssay) -> String? {
        switch assay.flowAssay {
        case .novelObject?, .placePreference?: return "Test"
        case .morrisWaterMaze?, .barnesMaze?: return "Acquisition"
        case .fearConditioning?: return "Cue test"
        default: return nil
        }
    }
}

/// One session (video) as the group comparison sees it.
struct GroupRecord: Identifiable {
    var id: UUID
    /// Animal ID as entered ("" if missing).
    var subjectID: String
    /// Animal identity within the task (videos without an ID are separate animals).
    var subjectKey: String
    /// Group label ("" = no group).
    var group: String
    var phase: String
    var day: Int?
    var trial: Int?
    var session: Int?
    var date: String?
    var metrics: [String: Double]
    var series: [FlowResultSeries]
    var excluded: Bool
    var exclusionReason: String
    /// QC warnings of the analysis (English).
    var qcFlags: [String]
    /// The reviewer marked the tracking of this session as having problems.
    var trackingProblem: Bool
    /// "M", "F" or "" (two-way ANOVA with sex as the second factor).
    var sex: String = ""
    /// Pose model of the session's data ("" = no pose model: classic centroid, multi-chamber TST).
    var model: String = ""

    static let ungroupedLabel = "Ungrouped"
    var displayGroup: String { group.isEmpty ? Self.ungroupedLabel : group }
    var displaySubject: String { subjectID.isEmpty ? subjectKey : subjectID }
}

/// Group label for the interface ("Ungrouped" is shown in the interface language).
func groupDisplayName(_ g: String) -> String {
    g == GroupRecord.ungroupedLabel ? L("Ungrouped", "未分组") : g
}

/// What the engine needs to know about the task.
struct GroupAnalysisContext {
    var assay: StudyAssay
    var defs: [TaskMetricDef]
    var pairs: [MetricPair]
    /// Phase keys in the task's own order.
    var assayPhases: [String]
    /// Primary measure for a phase ("" = all phases).
    var primaryKey: (String) -> String
    var usesDays: Bool

    func phaseTitle(_ key: String, english: Bool) -> String {
        if key.isEmpty { return english ? "no phase" : L("No phase", "无阶段") }
        return english ? key : assay.phaseTitle(key)
    }
}

/// Second between-animal factor of a two-way ANOVA (the first factor is the group).
enum FactorSource: String, CaseIterable, Codable, Identifiable {
    /// One factor (the groups).
    case none
    /// Group × sex (from the animal's sex).
    case sex
    /// Group labels split into two factors, e.g. "WT-Veh" → genotype "WT" × treatment "Veh".
    case groupSplit = "group_split"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return L("None (one factor)", "无（单因素）")
        case .sex: return L("Group × sex", "组 × 性别")
        case .groupSplit: return L("Split group names (e.g. WT-Veh)", "拆分组名（如 WT-Veh）")
        }
    }
}

struct GroupAnalysisRequest: Codable, Hashable {
    var design: GroupDesign = .betweenGroups
    var metricKey: String = ""
    var seriesKey: String = ""
    var pairKey: String = ""
    /// nil = all phases.
    var phaseFilter: String?
    /// nil = all sessions (averaged within animal); a number = only that session number (实验次数).
    var sessionFilter: Int?
    var phaseA: String = ""
    var phaseB: String = ""
    /// Included groups in display order; the first one is treated as the control.
    var groups: [String] = []
    var includeExcluded = false
    var mode: StatMode = .parametric
    var comparison: ComparisonMode = .allPairs
    var testAgainstChance = false
    /// Two-way ANOVA: the second factor (compare groups only).
    var factorB: FactorSource = .none
    /// Names of the two factors for a split group label ("" = Factor A / Factor B).
    var factorNameA = ""
    var factorNameB = ""
    /// ANCOVA: another measure of the same animal as the covariate ("" = none; compare groups only).
    var covariateKey = ""
}

struct SubjectPoint: Codable, Hashable, Identifiable {
    var subject: String
    var group: String
    var value: Double
    var records: Int
    var id: String { group + "|" + subject }
}

struct CurvePoint: Codable, Hashable, Identifiable {
    var group: String
    var level: Double
    var mean: Double
    var sem: Double
    var n: Int
    var id: String { "\(group)|\(level)" }
}

struct SubjectSeries: Codable, Hashable, Identifiable {
    var subject: String
    var group: String
    var values: [Double?]
    var id: String { group + "|" + subject }
}

struct PairedPoint: Codable, Hashable, Identifiable {
    var subject: String
    var group: String
    var a: Double
    var b: Double
    var id: String { group + "|" + subject }
}

struct GroupTestReport: Codable, Hashable {
    var omnibus: TestResult?
    var mixed: StatTests.MixedANOVAOutput?
    var pairwise: [PairwiseComparison] = []
    var perGroup: [String: TestResult] = [:]
    var perGroupLabel = ""
    var methodSummary = ""
    /// Effect sizes with 95% CIs (one row per comparison or test).
    var effects: [EffectSizeRow] = []
    /// The sentence of `methodSummary` that describes the per-group tests (also part of `methodSummary`).
    var perGroupMethod = ""
    /// Repeated designs: animals in the repeated-measures test (those with a value at every level) and left out.
    var animalsInTest: Int? = nil
    var animalsLeftOut = 0
}

/// What the figure brackets, the legend, the Methods and the line under the figure lead with (RodentFlow 2.1 build 23).
enum MainAnalysis: String, Codable {
    /// The design's own test (`report`).
    case standard
    /// A 0/1 measure: Fisher's exact / chi-square test of the proportions (`proportion`).
    case proportion
    /// A latency with a cut-off: Kaplan–Meier curves and the log-rank test (`survival`).
    case survival
    /// A latency with a cut-off whose Kaplan–Meier analysis could not be computed: no test (`mainNote` says why).
    case survivalUnavailable = "survival_unavailable"
    /// Two-way ANOVA (and an ANCOVA, if one was also asked for).
    case twoWay = "two_way"
    case ancova
    /// No between-groups test: an animal appears in more than one group (`mainNote`).
    case descriptive
}

struct GroupAnalysisResult: Codable {
    var request: GroupAnalysisRequest
    var english = false
    var metricName = ""
    var unit = ""
    var levelLabel = ""
    var groups: [String] = []
    var points: [SubjectPoint] = []
    var descriptives: [String: Descriptives] = [:]
    var levels: [Double] = []
    var curves: [CurvePoint] = []
    var subjectSeries: [SubjectSeries] = []
    var paired: [PairedPoint] = []
    var pairLabelA = ""
    var pairLabelB = ""
    var chance: Double?
    var report = GroupTestReport()
    var notes: [String] = []
    var generatedAt = Date()
    /// Kaplan–Meier / log-rank for latencies with a cut-off (one record per animal).
    var survival: SurvivalResult? = nil
    /// Normality / equal-spread checks (a hint; the test is not changed).
    var assumptions: AssumptionReport? = nil
    /// Two-way ANOVA (group × sex, or the two parts of split group labels).
    var twoWay: TwoWayReport? = nil
    /// ANCOVA with another measure as the covariate.
    var ancova: ANCOVAReport? = nil
    /// Sex of each animal ("group|animal" → "M" / "F"), for the long-format export.
    var animalSex: [String: String] = [:]
    /// 0/1 measures (one value per animal): Fisher's exact / chi-square test of the proportions (RodentFlow 2.1).
    var proportion: ProportionTest? = nil
    /// Pose model(s) of each animal's sessions ("group|animal" → model names joined by "; "), for the long-format export.
    var animalModel: [String: String] = [:]
    /// Pose models of the included sessions, in order of first appearance.
    var models: [String] = []
    /// Covariate value of each animal ("group|animal"), when an ANCOVA was asked for.
    var covariateValues: [String: Double] = [:]
    /// The analysis the figure, legend and Methods report as the result.
    var main: MainAnalysis = .standard
    /// Why there is no test (crossover groups, Kaplan–Meier not computable), in the result's language.
    var mainNote = ""
    /// A censored latency (SurvivalSpecs) analysed outside the between-groups design: its cut-off values enter the
    /// test as if observed (no Kaplan–Meier here). Stated in the notes, the legend and Methods.
    var censoredValuesAsObserved = false
    /// Animal IDs found in more than one included group.
    var crossoverSubjects: [String] = []

    var animalCount: Int {
        switch request.design {
        case .betweenGroups, .phaseChange: return points.count
        case .byDay, .bySession, .withinSession: return subjectSeries.count
        case .pairedMeasures: return paired.count
        }
    }

    var isEmpty: Bool { animalCount == 0 }

    var axisTitle: String { unit.isEmpty ? metricName : "\(metricName) (\(unit))" }
}

struct SeriesOption: Hashable, Identifiable {
    var key: String
    var name: String
    var unit: String
    var xLabel: String
    var id: String { key }
}

// MARK: - Engine

enum GroupAnalysisEngine {
    static let controlHints = ["control", "ctrl", "wt", "wild", "vehicle", "veh", "saline", "sham", "naive", "con"]

    private static func tx(_ english: Bool, _ en: String, _ zh: String) -> String {
        english || !Lang.isChinese ? en : zh
    }

    /// "A − B" with group names in the output language.
    static func displayPair(_ a: String, _ b: String, english: Bool) -> String {
        (english ? a : groupDisplayName(a)) + " − " + (english ? b : groupDisplayName(b))
    }

    /// Groups ordered with a likely control first, then alphabetically.
    static func orderedGroups(_ records: [GroupRecord]) -> [String] {
        let names = Set(records.map(\.displayGroup))
        return names.sorted { a, b in
            let ca = isLikelyControl(a), cb = isLikelyControl(b)
            if ca != cb { return ca }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static func isLikelyControl(_ name: String) -> Bool {
        let lower = name.lowercased()
        return controlHints.contains { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + "-") || lower.hasPrefix($0 + "_") || lower.hasPrefix($0 + "/") }
    }

    /// Phases present, in the task's order. "" (no phase) is listed only when other phases exist too, so it
    /// can be analysed separately instead of being pooled with them.
    static func phases(_ records: [GroupRecord], assayPhases: [String]) -> [String] {
        var seen: [String] = []
        for p in assayPhases where records.contains(where: { $0.phase == p }) { seen.append(p) }
        for r in records where !r.phase.isEmpty && !seen.contains(r.phase) { seen.append(r.phase) }
        if !seen.isEmpty && records.contains(where: { $0.phase.isEmpty }) { seen.append("") }
        return seen
    }

    static func days(_ records: [GroupRecord]) -> [Int] {
        Array(Set(records.compactMap(\.day))).sorted()
    }

    static func sessions(_ records: [GroupRecord]) -> [Int] {
        Array(Set(records.compactMap(\.session))).sorted()
    }

    static func metricOptions(_ context: GroupAnalysisContext, records: [GroupRecord]) -> [TaskMetricDef] {
        let present = Set(records.flatMap { $0.metrics.keys })
        return context.defs.filter { present.contains($0.key) }
    }

    /// A censored latency analysed in a design without Kaplan–Meier (by day, by session, change between phases): the
    /// cut-off values of animals without the event are tested as if observed, which understates group differences.
    static func noteCensoredOutsideKM(_ result: inout GroupAnalysisResult, assay: StudyAssay, records: [GroupRecord]) {
        guard let spec = SurvivalSpecs.spec(assay, metric: result.request.metricKey) else { return }
        // Only when a value is (or may be) censored: a session with the latency and no event, or without the event flag.
        let key = result.request.metricKey
        guard records.contains(where: { r in
            guard let t = r.metrics[key], t.isFinite else { return false }
            return (r.metrics[spec.eventKey] ?? 0) <= 0
        }) else { return }
        let english = result.english
        result.censoredValuesAsObserved = true
        result.notes.append(String(format: tx(english,
            "This latency is censored: animals without the event (%@) have the cut-off as their value, and this design tests those values as if observed. For a censored comparison, choose “Between groups” for one day / session / phase (Kaplan–Meier and log-rank).",
            "该潜伏期为截尾数据：未发生事件（%@）的动物取截止时间作为数值，本设计把这些值当作实测值检验。如需按截尾数据比较，请选择“组间比较”并限定到某一天 / 某次实验 / 某个阶段（Kaplan–Meier 与 log-rank）。"),
            english || !Lang.isChinese ? spec.eventEN : spec.eventZH))
    }

    /// Note when the standard (t / U / ANOVA) test has no result.
    static func noTestNote(_ english: Bool) -> String {
        tx(english, "No test result: each group needs at least 2 animals with values that differ (identical values give no variability to test).",
           "没有检验结果：每组至少需要 2 只数值不完全相同的小鼠。")
    }

    /// Interface text of a stored series axis label: time-course labels ("Time (min), 1-min bins", any bin width)
    /// are rebuilt in the interface language; other stored labels (classic "Minute", …) go through RFText.
    static func displayXLabel(_ stored: String) -> String {
        let shown = TimeCourseLabel.display(stored)
        return shown == stored ? RFText.tr(stored) : shown
    }

    static func seriesOptions(_ records: [GroupRecord], english: Bool = false) -> [SeriesOption] {
        var out: [SeriesOption] = []
        for r in records {
            for s in r.series where !out.contains(where: { $0.key == s.key }) {
                out.append(SeriesOption(key: s.key, name: english ? s.name : RFText.tr(s.name), unit: s.unit,
                                        xLabel: english ? s.xLabel : displayXLabel(s.xLabel)))
            }
        }
        return out
    }

    static func availableDesigns(_ context: GroupAnalysisContext, records: [GroupRecord]) -> [GroupDesign] {
        var designs: [GroupDesign] = [.betweenGroups]
        if sessions(records).count >= 2 { designs.append(.bySession) }
        if days(records).count >= 2 { designs.append(.byDay) }
        if !seriesOptions(records).isEmpty { designs.append(.withinSession) }
        let pairs = context.pairs.filter { pair in records.contains { $0.metrics[pair.metricA] != nil && $0.metrics[pair.metricB] != nil } }
        if !pairs.isEmpty { designs.append(.pairedMeasures) }
        if phases(records, assayPhases: context.assayPhases).count >= 2 { designs.append(.phaseChange) }
        return designs
    }

    /// A reasonable starting request for a task and its sessions.
    static func defaultRequest(_ context: GroupAnalysisContext, records: [GroupRecord]) -> GroupAnalysisRequest {
        var req = GroupAnalysisRequest()
        let ph = phases(records, assayPhases: context.assayPhases)
        if !ph.isEmpty && (!context.assayPhases.isEmpty || ph.count >= 2) {
            // Never pool different phases by default (e.g. acquisition and probe trials).
            let preferred = TaskPairs.analysisDefaultPhase(context.assay) ?? context.assay.defaultPhase
            req.phaseFilter = ph.contains(preferred) ? preferred : ph[0]
        }
        let primaryPhase = req.phaseFilter ?? (ph.count == 1 ? ph[0] : "")
        // (An empty primary phase means: the measure highlighted most often in all sessions.)
        let metrics = metricOptions(context, records: records)
        let primary = context.primaryKey(primaryPhase)
        req.metricKey = metrics.contains(where: { $0.key == primary }) ? primary : (metrics.first?.key ?? "")
        req.groups = orderedGroups(records)
        if context.usesDays && days(records).count >= 2 { req.design = .byDay }
        if ph.count >= 2 {
            req.phaseA = ph.first(where: { $0.lowercased().contains("pre") }) ?? ph[0]
            req.phaseB = ph.first(where: { $0 == "Test" }) ?? ph[ph.count - 1]
        }
        req.seriesKey = seriesOptions(records).first?.key ?? ""
        req.pairKey = context.pairs.first?.key ?? ""
        return req
    }

    // MARK: Pose models

    /// Records which pose model made each animal's data, and warns when the groups were not all tracked with
    /// the same model (e.g. a strain comparison of dark and white mice: differences between the models then add
    /// to the differences between the strains).
    static func noteModels(_ records: [GroupRecord], into result: inout GroupAnalysisResult) {
        var perAnimal: [String: [String]] = [:]
        var perGroup: [String: Set<String>] = [:]
        for r in records where !r.model.isEmpty {
            let key = r.displayGroup + "|" + r.subjectKey
            if !(perAnimal[key] ?? []).contains(r.model) { perAnimal[key, default: []].append(r.model) }
            perGroup[r.displayGroup, default: []].insert(r.model)
            if !result.models.contains(r.model) { result.models.append(r.model) }
        }
        result.animalModel = perAnimal.mapValues { $0.joined(separator: "; ") }
        guard result.models.count > 1 else { return }
        let english = result.english
        let sets = result.groups.compactMap { perGroup[$0] }
        if Set(sets).count > 1 {
            let detail = result.groups.compactMap { g in perGroup[g].map { "\(english ? g : groupDisplayName(g)): \($0.sorted().joined(separator: " + "))" } }
                .joined(separator: "; ")
            result.notes.append(String(format: tx(english,
                "The groups were tracked with different pose models (%@). Differences between the models (e.g. how often an animal is missed) add to the differences between the groups; compare the detection rates of the groups before interpreting the result.",
                "各组用的姿态模型不同（%@）。模型之间的差别（例如漏检多少）会和组间差别混在一起；解读结果前请先比较各组的检出率。"), detail))
        } else {
            result.notes.append(String(format: tx(english, "The sessions were tracked with more than one pose model (%@), and every group includes the same models.",
                                                  "这些实验用了不止一个姿态模型（%@），每组都包含这些模型。"), result.models.joined(separator: ", ")))
        }
    }

    // MARK: Run

    static func run(_ req: GroupAnalysisRequest, records allRecords: [GroupRecord], context: GroupAnalysisContext,
                    english: Bool = false) -> GroupAnalysisResult {
        var result = GroupAnalysisResult(request: req)
        result.english = english
        var records = allRecords
        let excludedCount = records.filter(\.excluded).count
        if !req.includeExcluded {
            records.removeAll(where: \.excluded)
            if excludedCount > 0 {
                result.notes.append(String(format: tx(english, "%d excluded session(s) left out.", "已排除 %d 次实验（未纳入）。"), excludedCount))
            }
        }
        if req.design != .phaseChange, let phase = req.phaseFilter {
            records = records.filter { $0.phase == phase }
        }
        if req.design != .bySession, let session = req.sessionFilter {
            records = records.filter { $0.session == session }
        }
        let groupSet = Set(req.groups)
        records = records.filter { groupSet.contains($0.displayGroup) }
        result.groups = req.groups.filter { g in records.contains { $0.displayGroup == g } }
        for r in records where !r.sex.isEmpty && result.animalSex[r.displayGroup + "|" + r.subjectKey] == nil {
            result.animalSex[r.displayGroup + "|" + r.subjectKey] = r.sex
        }
        noteModels(records, into: &result)

        let def = context.defs.first { $0.key == req.metricKey }
        result.metricName = def?.title(english: english) ?? req.metricKey
        result.unit = def?.unitText(english: english) ?? ""
        result.chance = def?.chance

        let flagged = records.filter { !$0.qcFlags.isEmpty || $0.trackingProblem }
        if !flagged.isEmpty {
            let names = flagged.prefix(4).map(\.displaySubject).joined(separator: ", ") + (flagged.count > 4 ? "…" : "")
            result.notes.append(String(format: tx(english,
                "%d included session(s) have QC warnings or tracking problems (%@). Open them and exclude them if your criteria require it.",
                "%d 次纳入的实验有质控警告或追踪问题（%@）。如按你的标准应排除，请打开并标记排除。"), flagged.count, names))
        }
        let unnamed = records.filter { $0.subjectID.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if unnamed > 0 {
            result.notes.append(String(format: tx(english, "%d session(s) without an animal ID were treated as separate animals.",
                                                  "%d 次实验没有小鼠编号，按不同小鼠处理。"), unnamed))
        }
        // The same animal in two groups (crossover): the groups are not independent samples (pseudoreplication,
        // Lazic 2010), so no between-groups test is run.
        result.crossoverSubjects = crossoverSubjects(records)
        if !result.crossoverSubjects.isEmpty {
            result.main = .descriptive
            result.mainNote = req.design == .phaseChange
                ? String(format: tx(english,
                    "No between-groups test: animal ID(s) %@ have a different group in different phases, so the groups are not independent (descriptive statistics only). Give each animal the same group label in every phase (the phases already hold the conditions); if these are different animals that share an ID, give them unique IDs.",
                    "未做组间检验：小鼠编号 %@ 在不同阶段属于不同分组，各组不是独立样本（仅描述统计）。请让每只动物在所有阶段使用同一个分组（处理条件已由阶段表示）；若只是不同动物用了相同编号，请改成唯一编号。"),
                    result.crossoverSubjects.joined(separator: ", "))
                : String(format: tx(english,
                    "No between-groups test: animal ID(s) %@ appear in more than one group, so the groups are not independent (descriptive statistics only). For a within-animal design, record the conditions as phases and use “Change between phases” (paired test); if these are different animals that share an ID, give them unique IDs.",
                    "未做组间检验：小鼠编号 %@ 出现在多个分组中，各组不是独立样本（仅描述统计）。若为同一动物先后接受不同处理，请把处理记为阶段，并用“阶段间变化”（配对检验）；若只是不同动物用了相同编号，请改成唯一编号。"),
                    result.crossoverSubjects.joined(separator: ", "))
            result.notes.append(result.mainNote)
        }

        switch req.design {
        case .betweenGroups:
            result.points = subjectMeans(records, metric: req.metricKey)
            noteAveraging(&result)
            analyzeIndependent(&result)
            noteUnconfirmed(&result, records: records)
            guard result.crossoverSubjects.isEmpty else { break }
            if req.factorB != .none {
                analyzeTwoWay(&result, records: records)
            }
            if !req.covariateKey.isEmpty && req.covariateKey != req.metricKey {
                analyzeCovariate(&result, records: records, context: context)
            }
            if result.twoWay == nil {
                result.assumptions = independentAssumptions(result)
            }
            let model = result.twoWay != nil || result.ancova != nil
            if model { result.main = result.twoWay != nil ? .twoWay : .ancova }
            if ProportionTests.applies(metricKey: req.metricKey),
               let prop = ProportionTests.test(points: result.points, groups: result.groups, english: english,
                                               controlOnly: req.comparison == .versusControl) {
                result.proportion = prop
                if !model {
                    result.main = .proportion
                    let secondary = result.report.omnibus != nil
                    let control = result.groups.first.map { english ? $0 : groupDisplayName($0) } ?? ""
                    let many = req.comparison == .versusControl
                        ? String(format: tx(english, "a chi-square test, then Fisher's exact tests of each group vs %@ with Holm correction",
                                            "卡方检验，再将各组与 %@ 做 Fisher 精确检验（Holm 校正）"), control)
                        : tx(english, "a chi-square test and pairwise Fisher's exact tests with Holm correction",
                             "卡方检验，并做 Holm 校正的两两 Fisher 精确检验")
                    result.notes.append(tx(english, "Each animal is 0 or 1 on this measure: the groups are compared as proportions (Fisher's exact test; with more than two groups ",
                                           "这个指标每只动物只有 0 或 1：组间按比例比较（Fisher 精确检验；多于两组时用") + many + tx(english, ").", "）。")
                                        + (secondary ? tx(english, " The t / U test of the 0/1 values is listed only as a secondary analysis.",
                                                          "对 0/1 数值的 t / U 检验只作为次要分析列出。") : ""))
                }
                if prop.smallExpected {
                    result.notes.append(tx(english, "Some expected counts are below 5: the chi-square p value is approximate.", "部分期望频数 < 5：卡方检验的 p 值只是近似。"))
                }
            }
            if let spec = SurvivalSpecs.spec(context.assay, metric: req.metricKey) {
                let s = Survival.analyse(records: records, groups: result.groups, metric: req.metricKey, spec: spec, english: english)
                result.survival = s.result
                if let note = s.note { result.notes.append(note) }
                let groupsWithData = Set(result.points.map(\.group)).count
                if !model && groupsWithData >= 2 {
                    if s.result?.p != nil {
                        result.main = .survival
                        result.notes.append(result.report.omnibus != nil
                            ? tx(english, "Latencies without the event are drawn at the cut-off in the plot; the result is the log-rank test of the Kaplan–Meier curves (a t / U test of the cut-off values is listed only as a secondary analysis).",
                                 "未发生事件的潜伏期在图中按截止时间画出；结果以 Kaplan–Meier 曲线的 log-rank 检验为准（对截止值的 t / U 检验只作为次要分析列出）。")
                            : tx(english, "Latencies without the event are drawn at the cut-off in the plot; the result is the log-rank test of the Kaplan–Meier curves.",
                                 "未发生事件的潜伏期在图中按截止时间画出；结果以 Kaplan–Meier 曲线的 log-rank 检验为准。"))
                    } else {
                        result.main = .survivalUnavailable
                        let events = s.result?.groups.reduce(0) { $0 + $1.events } ?? 0
                        let fallback = s.result != nil && events == 0
                            ? tx(english, "no animal had the event, so there is nothing to compare", "没有动物发生该事件，无可比较")
                            : tx(english, "the log-rank test is not defined for these data", "这些数据无法计算 log-rank 检验")
                        let reason = (s.note ?? fallback).trimmingCharacters(in: CharacterSet(charactersIn: ".。 "))
                        result.mainNote = tx(english, "No test: these latencies are censored at the cut-off, and the Kaplan–Meier / log-rank analysis could not be computed (",
                                             "未做检验：这些潜伏期在截止时间截尾，而 Kaplan–Meier / log-rank 分析无法计算（") + reason + tx(english, ").", "）。")
                    }
                }
            }
            // Two-way ANOVA / ANCOVA of a censored latency: tested on the cut-off values, without Kaplan–Meier.
            if model { noteCensoredOutsideKM(&result, assay: context.assay, records: records) }
            if result.main == .proportion || result.main == .survival || result.main == .survivalUnavailable {
                // Normality checks describe the t / U test, which is not the result here.
                result.assumptions = nil
                // Nor is the t / U test's "no test result" (e.g. 0/6 vs 6/6: no variability, but a Fisher p value).
                let noTest = noTestNote(english)
                result.notes.removeAll { $0 == noTest }
            }
        case .phaseChange:
            result.metricName = "Δ " + result.metricName + " (\(context.phaseTitle(req.phaseB, english: english)) − \(context.phaseTitle(req.phaseA, english: english)))"
            result.points = phaseDifferences(records, metric: req.metricKey, phaseA: req.phaseA, phaseB: req.phaseB, english: english, notes: &result.notes)
            result.chance = 0
            analyzeIndependent(&result)
            if result.crossoverSubjects.isEmpty { result.assumptions = independentAssumptions(result) }
            noteCensoredOutsideKM(&result, assay: context.assay, records: records)
        case .byDay, .bySession:
            let byDay = req.design == .byDay
            result.levelLabel = byDay ? tx(english, "Day", "天") : tx(english, "Session", "实验次数")
            let rows = records.compactMap { r -> (String, String, Double, Double)? in
                guard let level = byDay ? r.day : r.session, let v = r.metrics[req.metricKey], v.isFinite else { return nil }
                return (r.displayGroup, r.subjectKey, Double(level), v)
            }
            if rows.count < records.count {
                result.notes.append(String(format: tx(english, "%d session(s) without a %@ or value were skipped.", "%d 次实验缺少%@或数值，已跳过。"),
                                           records.count - rows.count, result.levelLabel.lowercased()))
            }
            buildRepeated(&result, rows: rows)
            noteCensoredOutsideKM(&result, assay: context.assay, records: records)
        case .withinSession:
            let option = seriesOptions(records, english: english).first { $0.key == req.seriesKey }
            result.metricName = option?.name ?? req.seriesKey
            result.unit = option?.unit ?? ""
            result.levelLabel = option?.xLabel ?? tx(english, "Level", "水平")
            result.chance = nil
            var rows: [(String, String, Double, Double)] = []
            for r in records {
                guard let s = r.series.first(where: { $0.key == req.seriesKey }) else { continue }
                for (x, y) in zip(s.x, s.y) where x.isFinite && y.isFinite { rows.append((r.displayGroup, r.subjectKey, x, y)) }
            }
            buildRepeated(&result, rows: rows)
        case .pairedMeasures:
            analyzePaired(&result, records: records, context: context)
            let diffs = result.groups.compactMap { g -> (label: String, values: [Double])? in
                let d = result.paired.filter { $0.group == g }.map { $0.a - $0.b }
                return d.isEmpty ? nil : (label: english ? g : groupDisplayName(g), values: d)
            }
            if !diffs.isEmpty {
                result.assumptions = StatTests.assumptions(diffs, english: english, twoGroups: true)
            }
        }
        return result
    }

    // MARK: Assumptions, two-way ANOVA, ANCOVA (iOS build 15, Mac build 14)

    static func independentAssumptions(_ result: GroupAnalysisResult) -> AssumptionReport? {
        let rows = result.groups.compactMap { g -> (label: String, values: [Double])? in
            let v = result.points.filter { $0.group == g }.map(\.value)
            return v.isEmpty ? nil : (label: result.english ? g : groupDisplayName(g), values: v)
        }
        guard !rows.isEmpty else { return nil }
        return StatTests.assumptions(rows, english: result.english, twoGroups: rows.count == 2)
    }

    /// NSF latencies count only after the first bite was confirmed in the review.
    static func noteUnconfirmed(_ result: inout GroupAnalysisResult, records: [GroupRecord]) {
        guard result.request.metricKey == "feeding_latency" else { return }
        let open = records.filter { $0.metrics["feeding_latency"] == nil && $0.metrics["feeding_confirmed"] != nil }.count
        guard open > 0 else { return }
        result.notes.append(String(format: tx(result.english,
            "%d session(s) were left out because the first bite has not been confirmed in the review yet (“Set as first bite” or “No feeding before the cut-off”).",
            "%d 次实验的首次进食还没有在回看中确认（“设为首次进食”或“确认截止前未进食”），未纳入。"), open))
    }

    /// Splits every group label into two parts with one separator (e.g. "WT-Veh" → "WT", "Veh"); nil unless
    /// all labels split into two non-empty parts and each factor has at least two levels.
    static func groupSplit(_ groups: [String]) -> (separator: String, parts: [String: [String]])? {
        let candidates = [" × ", "×", " x ", " / ", "/", " - ", "-", "_", "+", "|", ":", " "]
        guard groups.count >= 2 else { return nil }
        for sep in candidates {
            var parts: [String: [String]] = [:]
            var ok = true
            for g in groups {
                let p = g.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2 && !p[0].isEmpty && !p[1].isEmpty {
                    parts[g] = p
                } else {
                    ok = false
                    break
                }
            }
            if ok && Set(parts.values.map { $0[0] }).count >= 2 && Set(parts.values.map { $0[1] }).count >= 2 {
                return (sep, parts)
            }
        }
        return nil
    }

    /// Second factors that the records support (sex needs two sexes; split labels need a common separator).
    static func factorSources(_ records: [GroupRecord], groups: [String]) -> [FactorSource] {
        var out: [FactorSource] = [.none]
        let wanted = Set(groups)
        let sexes = Set(records.filter { wanted.contains($0.displayGroup) }.map { $0.sex.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if sexes.count >= 2 && groups.count >= 2 { out.append(.sex) }
        if groupSplit(groups) != nil { out.append(.groupSplit) }
        return out
    }

    static func sexLabel(_ raw: String, english: Bool) -> String {
        switch raw.uppercased() {
        case "M": return tx(english, "Male", "雄")
        case "F": return tx(english, "Female", "雌")
        default: return raw
        }
    }

    static func analyzeTwoWay(_ result: inout GroupAnalysisResult, records: [GroupRecord]) {
        let req = result.request
        let english = result.english
        var obs: [StatTests.FactorialObservation] = []
        var levelsA: [String] = []
        var levelsB: [String] = []
        var nameA = tx(english, "Group", "组")
        var nameB = tx(english, "Sex", "性别")
        var left = 0
        switch req.factorB {
        case .none:
            return
        case .sex:
            var sexOf: [String: String] = [:]
            for r in records {
                let sx = r.sex.trimmingCharacters(in: .whitespaces)
                let key = r.displayGroup + "|" + r.subjectKey
                if !sx.isEmpty && sexOf[key] == nil { sexOf[key] = sx }
            }
            levelsA = result.groups.map { english ? $0 : groupDisplayName($0) }
            for p in result.points {
                guard let sx = sexOf[p.group + "|" + p.subject] else { left += 1; continue }
                let b = sexLabel(sx, english: english)
                if !levelsB.contains(b) { levelsB.append(b) }
                obs.append(StatTests.FactorialObservation(a: english ? p.group : groupDisplayName(p.group), b: b, value: p.value))
            }
            levelsB.sort()
            if left > 0 {
                result.notes.append(String(format: tx(english, "%d animal(s) without a recorded sex were left out of the two-way ANOVA.",
                                                      "%d 只动物没有记录性别，未纳入双因素方差分析。"), left))
            }
        case .groupSplit:
            guard let split = groupSplit(result.groups) else {
                result.notes.append(tx(english, "The group labels cannot be split into two factors: every label needs exactly one common separator, e.g. “WT-Veh”, “WT-Drug”, “KO-Veh”, “KO-Drug”.",
                                       "组名无法拆成两个因素：每个组名都需要恰好一个相同的分隔符，例如 “WT-Veh”“WT-Drug”“KO-Veh”“KO-Drug”。"))
                return
            }
            let a0 = req.factorNameA.trimmingCharacters(in: .whitespaces)
            let b0 = req.factorNameB.trimmingCharacters(in: .whitespaces)
            nameA = a0.isEmpty ? tx(english, "Factor A", "因素 A") : a0
            nameB = b0.isEmpty ? tx(english, "Factor B", "因素 B") : b0
            for g in result.groups {
                guard let p = split.parts[g] else { continue }
                if !levelsA.contains(p[0]) { levelsA.append(p[0]) }
                if !levelsB.contains(p[1]) { levelsB.append(p[1]) }
            }
            for p in result.points {
                guard let parts = split.parts[p.group] else { continue }
                obs.append(StatTests.FactorialObservation(a: parts[0], b: parts[1], value: p.value))
            }
        }
        guard let report = StatTests.twoWayANOVA(obs, levelsA: levelsA, levelsB: levelsB, nameA: nameA, nameB: nameB, english: english) else {
            result.notes.append(tx(english, "No two-way ANOVA: every combination of the two factors needs at least one animal, the factors need two levels each, and there must be more animals than combinations.",
                                   "无法做双因素方差分析：两个因素的每个组合都至少需要 1 只动物，每个因素至少 2 个水平，且动物数要多于组合数。"))
            return
        }
        result.twoWay = report
        if req.mode == .nonparametric {
            result.notes.append(tx(english, "The two-way analysis is parametric (ANOVA); a non-parametric version is not available yet.",
                                   "双因素分析为参数方法（方差分析），非参数版本暂未提供。"))
        }
        let groups = report.levelsA.flatMap { a in report.levelsB.map { b in (a, b) } }
        let rows = groups.map { ab -> (label: String, values: [Double]) in
            (label: ab.0 + " · " + ab.1, values: obs.filter { $0.a == ab.0 && $0.b == ab.1 }.map(\.value))
        }
        result.assumptions = StatTests.assumptions(rows, english: english, twoGroups: false, residualsOverride: report.residuals)
    }

    static func analyzeCovariate(_ result: inout GroupAnalysisResult, records: [GroupRecord], context: GroupAnalysisContext) {
        let req = result.request
        let english = result.english
        let def = context.defs.first { $0.key == req.covariateKey }
        let name = def.map { d -> String in
            let u = d.unitText(english: english)
            return u.isEmpty ? d.title(english: english) : d.title(english: english) + " (" + u + ")"
        } ?? req.covariateKey
        let cov = subjectMeans(records, metric: req.covariateKey)
        var byKey: [String: Double] = [:]
        for c in cov { byKey[c.group + "|" + c.subject] = c.value }
        result.covariateValues = byKey
        var obs: [StatTests.CovariateObservation] = []
        var missing = 0
        for p in result.points {
            if let c = byKey[p.group + "|" + p.subject] {
                obs.append(StatTests.CovariateObservation(group: p.group, covariate: c, value: p.value))
            } else {
                missing += 1
            }
        }
        guard var report = StatTests.ancova(obs, groups: result.groups, covariateKey: req.covariateKey, covariateName: name, english: english) else {
            result.notes.append(tx(english, "No ANCOVA: it needs at least two groups with two animals each that have both measures, and a covariate that varies.",
                                   "无法做 ANCOVA：至少需要两组、每组 2 只同时有两个指标的动物，且协变量有变化。"))
            return
        }
        if missing > 0 {
            report.notes.append(String(format: tx(english, "%d animal(s) without a covariate value were left out of the ANCOVA.", "%d 只动物没有协变量值，未纳入 ANCOVA。"), missing))
        }
        if req.mode == .nonparametric {
            report.notes.append(tx(english, "ANCOVA is a parametric method.", "ANCOVA 为参数方法。"))
        }
        result.ancova = report
    }

    static func subjectMeans(_ records: [GroupRecord], metric: String) -> [SubjectPoint] {
        var sums: [String: (group: String, subject: String, sum: Double, n: Int)] = [:]
        var order: [String] = []
        for r in records {
            guard let v = r.metrics[metric], v.isFinite else { continue }
            let key = r.displayGroup + "|" + r.subjectKey
            if sums[key] == nil {
                sums[key] = (r.displayGroup, r.subjectKey, 0, 0)
                order.append(key)
            }
            sums[key]!.sum += v
            sums[key]!.n += 1
        }
        return order.compactMap { key in
            guard let e = sums[key] else { return nil }
            return SubjectPoint(subject: e.subject, group: e.group, value: e.sum / Double(e.n), records: e.n)
        }
    }

    static func noteAveraging(_ result: inout GroupAnalysisResult) {
        let english = result.english
        let multi = result.points.filter { $0.records > 1 }
        if !multi.isEmpty {
            result.notes.append(String(format: tx(english,
                "%d animal(s) had several sessions; their values were averaged so n = animals. Filter by phase or session number to analyze one session.",
                "%d 只小鼠有多次实验，已在小鼠内取平均，n = 小鼠数。可按阶段或实验次数筛选，只分析某一次实验。"), multi.count))
        }
    }

    /// Animal IDs with sessions in more than one of the included groups (sorted). Videos without an ID are
    /// separate animals and never match.
    static func crossoverSubjects(_ records: [GroupRecord]) -> [String] {
        var groupsOf: [String: Set<String>] = [:]
        var name: [String: String] = [:]
        for r in records {
            groupsOf[r.subjectKey, default: []].insert(r.displayGroup)
            name[r.subjectKey] = r.displaySubject
        }
        return groupsOf.filter { $0.value.count > 1 }.keys.map { name[$0] ?? $0 }.sorted()
    }

    static func phaseDifferences(_ records: [GroupRecord], metric: String, phaseA: String, phaseB: String, english: Bool, notes: inout [String]) -> [SubjectPoint] {
        let a = subjectMeans(records.filter { $0.phase == phaseA }, metric: metric)
        let b = subjectMeans(records.filter { $0.phase == phaseB }, metric: metric)
        var out: [SubjectPoint] = []
        var unmatched = 0
        for pb in b {
            if let pa = a.first(where: { $0.subject == pb.subject && $0.group == pb.group }) {
                out.append(SubjectPoint(subject: pb.subject, group: pb.group, value: pb.value - pa.value, records: pa.records + pb.records))
            } else {
                unmatched += 1
            }
        }
        unmatched += a.filter { pa in !b.contains { $0.subject == pa.subject && $0.group == pa.group } }.count
        if unmatched > 0 {
            notes.append(String(format: tx(english, "%d animal(s) had only one of the two phases and were left out.", "%d 只小鼠只有其中一个阶段，未纳入。"), unmatched))
        }
        return out
    }

    // MARK: Independent groups (one value per animal)

    static func analyzeIndependent(_ result: inout GroupAnalysisResult) {
        let req = result.request
        let english = result.english
        let groups = result.groups
        var values: [[Double]] = []
        for g in groups {
            let v = result.points.filter { $0.group == g }.map(\.value)
            values.append(v)
            result.descriptives[g] = Stats.describe(v)
        }
        let present = zip(groups, values).filter { !$0.1.isEmpty }
        let names = present.map { $0.0 }
        let data = present.map { $0.1 }
        var report = GroupTestReport()
        let k = data.count
        // Groups that share animals are not compared (see run); within-animal tests per group still are.
        let between = result.crossoverSubjects.isEmpty
        let phaseChange = req.design == .phaseChange
        let perGroupTests = phaseChange || req.testAgainstChance

        if !between {
            report.methodSummary = tx(english, "No between-groups test (an animal appears in more than one group).",
                                      "未做组间检验（有动物出现在多个分组中）。")
        } else if k == 2 {
            if req.mode == .parametric {
                if let t = StatTests.welchT(data[0], data[1]) {
                    report.omnibus = t
                    let diff = Stats.mean(data[0]) - Stats.mean(data[1])
                    let ci = StatTests.welchDifferenceCI(data[0], data[1])
                    report.pairwise = [PairwiseComparison(groupA: names[0], groupB: names[1], level: nil,
                                                          difference: diff,
                                                          statisticName: "t", statistic: t.statistic, p: t.p, pAdjusted: t.p, method: t.name,
                                                          ciLow: ci?.low, ciHigh: ci?.high)]
                    report.methodSummary = tx(english, "Two-tailed Welch's t-test (unequal variances).", "双侧 Welch t 检验（方差不等）。")
                    let label = displayPair(names[0], names[1], english: english)
                    report.effects.append(EffectSizeRow(label: label, name: tx(english, "Mean difference", "均值差"), value: diff,
                                                        low: ci?.low, high: ci?.high, note: "Welch"))
                    if let g = t.effect {
                        let gci = StatTests.hedgesGCI(g, n1: data[0].count, n2: data[1].count)
                        report.effects.append(EffectSizeRow(label: label, name: "Hedges' g", value: g, low: gci.low, high: gci.high))
                    }
                }
            } else if let u = StatTests.mannWhitney(data[0], data[1]) {
                report.omnibus = u
                report.pairwise = [PairwiseComparison(groupA: names[0], groupB: names[1], level: nil,
                                                      difference: Stats.quantile(data[0], 0.5) - Stats.quantile(data[1], 0.5),
                                                      statisticName: "U", statistic: u.statistic, p: u.p, pAdjusted: u.p, method: u.name)]
                report.methodSummary = String(format: tx(english, "Two-tailed Mann–Whitney U test (%@).", "双侧 Mann–Whitney U 检验（%@）。"), u.note ?? "exact")
                let label = displayPair(names[0], names[1], english: english)
                if let z = StatTests.mannWhitneyZ(data[0], data[1]) {
                    let n = Double(data[0].count + data[1].count)
                    report.effects.append(EffectSizeRow(label: label, name: "r = Z/√N", value: z / n.squareRoot()))
                }
                if let rb = u.effect {
                    report.effects.append(EffectSizeRow(label: label, name: "rank-biserial r", value: rb))
                }
                if let hl = StatTests.hodgesLehmann(data[0], data[1]) {
                    report.effects.append(EffectSizeRow(label: label, name: tx(english, "Hodges–Lehmann shift", "Hodges–Lehmann 位移"), value: hl))
                }
            }
        } else if k >= 3 {
            let control = req.comparison == .versusControl ? 0 : nil
            if req.mode == .parametric {
                let anova = StatTests.oneWayANOVA(data)
                report.omnibus = anova?.test
                if let eta = anova?.test.effect {
                    report.effects.append(EffectSizeRow(label: tx(english, "Overall", "总体"), name: "η²", value: eta))
                }
                if let omega = StatTests.omegaSquared(data) {
                    report.effects.append(EffectSizeRow(label: tx(english, "Overall", "总体"), name: "ω²", value: omega))
                }
                if control == nil {
                    report.pairwise = StatTests.tukeyHSD(data, names: names)
                    report.methodSummary = tx(english, "One-way ANOVA followed by Tukey–Kramer HSD for all pairwise comparisons.",
                                              "单因素方差分析，事后用 Tukey–Kramer HSD 做两两比较。")
                } else {
                    var comps: [PairwiseComparison] = []
                    for j in 1..<k {
                        if let t = StatTests.welchT(data[0], data[j]) {
                            let ci = StatTests.welchDifferenceCI(data[0], data[j])
                            comps.append(PairwiseComparison(groupA: names[0], groupB: names[j], level: nil,
                                                            difference: Stats.mean(data[0]) - Stats.mean(data[j]),
                                                            statisticName: "t", statistic: t.statistic, p: t.p, pAdjusted: t.p, method: "Welch's t (Holm)",
                                                            ciLow: ci?.low, ciHigh: ci?.high))
                        }
                    }
                    let adj = Stats.holm(comps.map(\.p))
                    for i in comps.indices { comps[i].pAdjusted = adj[i] }
                    report.pairwise = comps
                    report.methodSummary = String(format: tx(english, "One-way ANOVA followed by Welch's t-tests of each group against %@ with Holm correction.",
                                                             "单因素方差分析，事后各组分别与 %@ 做 Welch t 检验（Holm 校正）。"), names[0])
                }
            } else {
                report.omnibus = StatTests.kruskalWallis(data)
                if let eta = report.omnibus?.effect {
                    report.effects.append(EffectSizeRow(label: tx(english, "Overall", "总体"), name: "η²(H)", value: eta))
                }
                report.pairwise = StatTests.dunn(data, names: names, controlIndex: control)
                report.methodSummary = control == nil
                    ? tx(english, "Kruskal–Wallis test followed by Dunn's test with Holm correction.", "Kruskal–Wallis 检验，事后 Dunn 检验（Holm 校正）。")
                    : String(format: tx(english, "Kruskal–Wallis test followed by Dunn's test with Holm correction (each group vs %@).",
                                        "Kruskal–Wallis 检验，事后 Dunn 检验（Holm 校正，各组与 %@ 比较）。"), names[0])
            }
        } else if k == 1 && !(perGroupTests && result.chance != nil) {
            report.methodSummary = tx(english, "Single group: descriptive statistics only.", "只有一组：仅描述统计。")
        }
        if between && k >= 3 && req.mode == .parametric {
            for c in report.pairwise {
                report.effects.append(EffectSizeRow(label: displayPair(c.groupA, c.groupB, english: english), name: tx(english, "Mean difference", "均值差"),
                                                    value: c.difference, low: c.ciLow, high: c.ciHigh,
                                                    note: c.method.hasPrefix("Tukey") ? tx(english, "Tukey simultaneous 95% CI", "Tukey 同时 95% CI") : tx(english, "unadjusted 95% CI", "未校正的 95% CI")))
            }
        }
        if between && k >= 2 && report.omnibus == nil {
            result.notes.append(noTestNote(english))
        }

        // Per group: the change between phases against 0 (a paired test of the two phases), or the values against
        // the measure's reference value when asked for.
        if perGroupTests, let chance = result.chance {
            for (name, v) in zip(names, data) {
                var test: TestResult?
                if req.mode == .parametric {
                    test = StatTests.oneSampleT(v, mu: chance)
                    if phaseChange {
                        test?.name = "Paired t-test"
                        test?.effectName = "Cohen's dz"
                    }
                } else {
                    test = StatTests.wilcoxonSignedRank(v.map { $0 - chance })
                }
                if let test { report.perGroup[name] = test }
            }
            if phaseChange {
                report.perGroupLabel = tx(english, "change vs 0", "变化与 0 比较")
                report.perGroupMethod = req.mode == .parametric
                    ? tx(english, "Within each group, the change of each animal between the two phases was tested against 0 with a paired t-test.",
                         "各组内，每只动物两阶段间的变化用配对 t 检验与 0 比较。")
                    : tx(english, "Within each group, the change of each animal between the two phases was tested against 0 with a Wilcoxon signed-rank test.",
                         "各组内，每只动物两阶段间的变化用 Wilcoxon 符号秩检验与 0 比较。")
            } else {
                report.perGroupLabel = String(format: tx(english, "vs %@", "与 %@ 比较"), StatsFormat.number(chance))
                report.perGroupMethod = req.mode == .parametric
                    ? String(format: tx(english, "One-sample t-tests against %@.", "单样本 t 检验（与 %@ 比较）。"), StatsFormat.number(chance))
                    : String(format: tx(english, "Wilcoxon signed-rank tests against %@.", "Wilcoxon 符号秩检验（与 %@ 比较）。"), StatsFormat.number(chance))
            }
            report.methodSummary += (report.methodSummary.isEmpty ? "" : " ") + report.perGroupMethod
        }
        result.report = report
    }

    // MARK: Repeated (sessions, days, bins, CS)

    static func buildRepeated(_ result: inout GroupAnalysisResult, rows: [(String, String, Double, Double)]) {
        let req = result.request
        let english = result.english
        let levels = Array(Set(rows.map { $0.2 })).sorted()
        result.levels = levels
        guard !levels.isEmpty else { return }
        var levelIndex: [Double: Int] = [:]
        for (i, level) in levels.enumerated() { levelIndex[level] = i }

        // Average within animal × level (e.g. trials within a day).
        var cell: [String: [Double]] = [:]
        var subjectsByGroup: [String: [String]] = [:]
        for (g, s, x, y) in rows {
            let key = g + "|" + s + "|" + String(levelIndex[x] ?? 0)
            cell[key, default: []].append(y)
            if !(subjectsByGroup[g]?.contains(s) ?? false) { subjectsByGroup[g, default: []].append(s) }
        }
        var series: [SubjectSeries] = []
        for g in result.groups {
            for s in subjectsByGroup[g] ?? [] {
                let values: [Double?] = levels.indices.map { j in
                    cell[g + "|" + s + "|" + String(j)].map { Stats.mean($0) }
                }
                series.append(SubjectSeries(subject: s, group: g, values: values))
            }
        }
        result.subjectSeries = series

        var curves: [CurvePoint] = []
        for g in result.groups {
            let gs = series.filter { $0.group == g }
            for (j, level) in levels.enumerated() {
                let v = gs.compactMap { $0.values[j] }
                guard !v.isEmpty else { continue }
                let d = Stats.describe(v)
                curves.append(CurvePoint(group: g, level: level, mean: d.mean, sem: d.sem, n: d.n))
            }
            result.descriptives[g] = Stats.describe(gs.compactMap { s -> Double? in
                let v = s.values.compactMap { $0 }
                return v.isEmpty ? nil : Stats.mean(v)
            })
        }
        result.curves = curves

        var report = GroupTestReport()
        let groupsWithData = result.groups.filter { g in series.contains { $0.group == g } }
        let complete = series.filter { $0.values.allSatisfy { $0 != nil } }
        let dropped = series.count - complete.count
        let levelWord = GroupAnalysisEngine.levelWord(result.levelLabel)

        guard result.crossoverSubjects.isEmpty else {
            report.methodSummary = tx(english, "No test (an animal appears in more than one group).", "未做检验（有动物出现在多个分组中）。")
            result.report = report
            return
        }

        if levels.count >= 2 {
            if req.mode == .parametric {
                let data = groupsWithData.map { g in complete.filter { $0.group == g }.map { $0.values.map { $0 ?? 0 } } }
                if let mixed = StatTests.mixedANOVA(data, levelCount: levels.count, dropped: dropped) {
                    report.mixed = mixed
                    report.animalsInTest = mixed.subjectsUsed
                    report.animalsLeftOut = dropped
                    report.methodSummary = groupsWithData.count >= 2
                        ? String(format: tx(english, "Two-way mixed ANOVA (group × %@, animal as the repeated unit) with Greenhouse–Geisser correction for the within-animal factor.",
                                            "两因素混合方差分析（组 × %@，小鼠为重复测量单位），组内因素用 Greenhouse–Geisser 校正。"), levelWord)
                        : tx(english, "One-way repeated-measures ANOVA with Greenhouse–Geisser correction.", "单因素重复测量方差分析（Greenhouse–Geisser 校正）。")
                }
                if dropped > 0 {
                    result.notes.append(String(format: tx(english, "%d animal(s) missing at least one %@ were left out of the ANOVA (still shown in the plot).",
                                                          "%d 只小鼠缺少至少一个%@，未纳入方差分析（图中仍显示）。"), dropped, levelWord))
                }
            } else if groupsWithData.count == 1 {
                let rowsComplete = complete.map { $0.values.map { $0 ?? 0 } }
                report.omnibus = StatTests.friedman(rowsComplete)
                if report.omnibus != nil {
                    report.animalsInTest = rowsComplete.count
                    report.animalsLeftOut = dropped
                }
                report.methodSummary = String(format: tx(english, "Friedman test across %@s.", "跨%@的 Friedman 检验。"), levelWord)
                if dropped > 0 {
                    result.notes.append(String(format: tx(english, "%d animal(s) missing at least one %@ were left out of the Friedman test (still shown in the plot).",
                                                          "%d 只小鼠缺少至少一个%@，未纳入 Friedman 检验（图中仍显示）。"), dropped, levelWord))
                }
            } else {
                report.methodSummary = String(format: tx(english, "Non-parametric: per-%@ Mann–Whitney tests with Holm correction (no omnibus test).",
                                                         "非参数：每个%@分别做 Mann–Whitney 检验（Holm 校正，无总体检验）。"), levelWord)
            }
        }

        // Post-hoc: groups compared at each level.
        if groupsWithData.count >= 2 {
            var comps: [PairwiseComparison] = []
            for (j, level) in levels.enumerated() {
                let byGroup = groupsWithData.map { g in series.filter { $0.group == g }.compactMap { $0.values[j] } }
                for a in 0..<groupsWithData.count {
                    for b in (a + 1)..<groupsWithData.count {
                        if req.comparison == .versusControl && a != 0 { continue }
                        let x = byGroup[a], y = byGroup[b]
                        let label = levelName(level, label: result.levelLabel, english: english)
                        if req.mode == .parametric, let t = StatTests.welchT(x, y) {
                            comps.append(PairwiseComparison(groupA: groupsWithData[a], groupB: groupsWithData[b], level: label,
                                                            difference: Stats.mean(x) - Stats.mean(y), statisticName: "t",
                                                            statistic: t.statistic, p: t.p, pAdjusted: t.p, method: "Welch's t (Holm)"))
                        } else if req.mode == .nonparametric, let u = StatTests.mannWhitney(x, y) {
                            comps.append(PairwiseComparison(groupA: groupsWithData[a], groupB: groupsWithData[b], level: label,
                                                            difference: Stats.quantile(x, 0.5) - Stats.quantile(y, 0.5), statisticName: "U",
                                                            statistic: u.statistic, p: u.p, pAdjusted: u.p, method: "Mann–Whitney (Holm)"))
                        }
                    }
                }
            }
            let adj = Stats.holm(comps.map(\.p))
            for i in comps.indices { comps[i].pAdjusted = adj[i] }
            report.pairwise = comps
            if !comps.isEmpty {
                report.methodSummary += " " + (req.mode == .parametric
                    ? String(format: tx(english, "Group differences at each %@: Welch's t-tests, Holm-corrected across all comparisons.",
                                        "每个%@的组间差异：Welch t 检验，所有比较一起做 Holm 校正。"), levelWord)
                    : String(format: tx(english, "Group differences at each %@: Mann–Whitney tests, Holm-corrected across all comparisons.",
                                        "每个%@的组间差异：Mann–Whitney 检验，所有比较一起做 Holm 校正。"), levelWord))
            }
        }
        result.report = report
    }

    static func levelName(_ level: Double, label: String, english: Bool) -> String {
        // Bin centres (0.125, 0.375 … min with 15-s bins) keep their digits, so neighbouring bins never share a label.
        var number = abs(level - level.rounded()) < 1e-9 ? String(format: "%.0f", level) : String(format: "%.4f", level)
        if number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        if label == tx(english, "Day", "天") { return String(format: tx(english, "Day %@", "第 %@ 天"), number) }
        if label == tx(english, "Session", "实验次数") { return String(format: tx(english, "Session %@", "第 %@ 次"), number) }
        // Series x labels state the bin width after a comma ("Time (min), 1-min bins"): keep the name and unit only.
        let head = label.components(separatedBy: CharacterSet(charactersIn: ",，")).first?.trimmingCharacters(in: .whitespaces) ?? label
        return head.isEmpty ? number : "\(head) \(number)"
    }

    /// The level of a repeated design as a word inside a sentence: "day", "session", or the series x label
    /// without its unit and bin width ("Time (min), 1-min bins" → "time").
    static func levelWord(_ label: String) -> String {
        var head = label.components(separatedBy: CharacterSet(charactersIn: ",，(（")).first?.trimmingCharacters(in: .whitespaces) ?? label
        if head.isEmpty { head = "level" }
        let chars = Array(head)
        // "Time" → "time", but "CS" stays "CS".
        if chars.count >= 2, chars[0].isUppercase, chars[1].isLowercase { return head.prefix(1).lowercased() + String(head.dropFirst()) }
        return head
    }

    // MARK: Paired measures

    static func analyzePaired(_ result: inout GroupAnalysisResult, records: [GroupRecord], context: GroupAnalysisContext) {
        let req = result.request
        let english = result.english
        guard let pair = context.pairs.first(where: { $0.key == req.pairKey }) ?? context.pairs.first else { return }
        let defA = context.defs.first { $0.key == pair.metricA }
        let labelA = pair.labelA(english: english), labelB = pair.labelB(english: english)
        result.metricName = pair.title(english: english)
        result.unit = defA?.unitText(english: english) ?? ""
        result.pairLabelA = labelA
        result.pairLabelB = labelB
        result.chance = nil

        let a = subjectMeans(records, metric: pair.metricA)
        let b = subjectMeans(records, metric: pair.metricB)
        var paired: [PairedPoint] = []
        for pa in a {
            if let pb = b.first(where: { $0.subject == pa.subject && $0.group == pa.group }) {
                paired.append(PairedPoint(subject: pa.subject, group: pa.group, a: pa.value, b: pb.value))
            }
        }
        result.paired = paired

        var report = GroupTestReport()
        report.perGroupLabel = String(format: tx(english, "%@ vs %@", "%@ vs %@"), labelA, labelB)
        var differencesByGroup: [[Double]] = []
        var groupsWithData: [String] = []
        for g in result.groups {
            let pts = paired.filter { $0.group == g }
            guard !pts.isEmpty else { continue }
            groupsWithData.append(g)
            differencesByGroup.append(pts.map { $0.a - $0.b })
            result.descriptives[g] = Stats.describe(pts.map { $0.a - $0.b })
            let test = req.mode == .parametric
                ? StatTests.pairedT(pts.map(\.a), pts.map(\.b))
                : StatTests.wilcoxonSignedRank(pts.map { $0.a - $0.b })
            if let test { report.perGroup[g] = test }
            let d = pts.map { $0.a - $0.b }
            let gname = english ? g : groupDisplayName(g)
            if d.count >= 2 {
                let m = Stats.mean(d)
                let se = Stats.sd(d) / Double(d.count).squareRoot()
                let tq = Distributions.tQuantile(0.975, df: Double(d.count - 1))
                if se.isFinite && se > 0 {
                    report.effects.append(EffectSizeRow(label: gname, name: String(format: tx(english, "Mean difference (%@ − %@)", "均值差（%@ − %@）"), labelA, labelB),
                                                        value: m, low: m - tq * se, high: m + tq * se))
                }
            }
            if let test, let e = test.effect, let en = test.effectName {
                report.effects.append(EffectSizeRow(label: gname, name: en, value: e))
            }
        }
        report.methodSummary = req.mode == .parametric
            ? String(format: tx(english, "Within each group: paired t-test (%@ vs %@).", "各组内：配对 t 检验（%@ vs %@）。"), labelA, labelB)
            : String(format: tx(english, "Within each group: Wilcoxon signed-rank test (%@ vs %@).", "各组内：Wilcoxon 符号秩检验（%@ vs %@）。"), labelA, labelB)

        if groupsWithData.count >= 2 && result.crossoverSubjects.isEmpty {
            if req.mode == .parametric {
                let data = groupsWithData.map { g in paired.filter { $0.group == g }.map { [$0.a, $0.b] } }
                report.mixed = StatTests.mixedANOVA(data, levelCount: 2)
                report.methodSummary += " " + String(format: tx(english, "Between groups: two-way mixed ANOVA (group × measure); the interaction tests whether the %@–%@ difference differs between groups.",
                                                                "组间：两因素混合方差分析（组 × 指标）；交互作用检验 %@–%@ 之差在各组间是否不同。"), labelA, labelB)
            } else {
                report.omnibus = groupsWithData.count == 2
                    ? StatTests.mannWhitney(differencesByGroup[0], differencesByGroup[1])
                    : StatTests.kruskalWallis(differencesByGroup)
                report.methodSummary += " " + (groupsWithData.count == 2
                    ? String(format: tx(english, "Between groups: the %@ − %@ differences were compared with a Mann–Whitney test.",
                                        "组间：%@ − %@ 之差用 Mann–Whitney 检验比较。"), labelA, labelB)
                    : String(format: tx(english, "Between groups: the %@ − %@ differences were compared with a Kruskal–Wallis test.",
                                        "组间：%@ − %@ 之差用 Kruskal–Wallis 检验比较。"), labelA, labelB))
            }
        }
        result.report = report
    }

    // MARK: Text summary (RodentFlow GroupAnalysisViewModel.summaryText)

    static func summaryText(_ r: GroupAnalysisResult, taskName: String, context: GroupAnalysisContext) -> String {
        let english = r.english
        var lines: [String] = []
        lines.append("\(taskName) — \(r.metricName)\(r.unit.isEmpty ? "" : " (\(r.unit))")")
        if let phase = r.request.phaseFilter, r.request.design != .phaseChange {
            lines.append(String(format: tx(english, "Phase: %@", "阶段：%@"), context.phaseTitle(phase, english: english)))
        }
        if let session = r.request.sessionFilter, r.request.design != .bySession {
            lines.append(String(format: tx(english, "Session number: %d", "实验次数：%d"), session))
        }
        for g in r.groups {
            if let d = r.descriptives[g], d.n > 0 {
                let name = english ? g : groupDisplayName(g)
                lines.append(String(format: tx(english, "%@: n = %d, mean ± SEM = %@ ± %@, median = %@", "%@：n = %d，均值 ± SEM = %@ ± %@，中位数 = %@"),
                                    name, d.n, StatsFormat.number(d.mean), StatsFormat.number(d.sem), StatsFormat.number(d.median)))
            }
        }
        if r.main != .standard {
            if let main = GroupReportText.mainTestLine(r) { lines.append(tx(english, "Main analysis: ", "主要分析：") + main) }
            if r.main == .proportion, let pr = r.proportion {
                lines.append(contentsOf: GroupReportText.proportionLines(pr, english: english))
                for c in pr.pairwise where pr.rows.count > 2 { lines.append("  " + GroupReportText.pairLine(c, english: english)) }
            }
            if r.main == .survival, let sv = r.survival { lines.append("  " + sv.reportLine) }
            if r.report.omnibus != nil || r.report.mixed != nil || !r.report.pairwise.isEmpty {
                lines.append(tx(english, "Secondary analysis (not the main result):", "次要分析（不是主要结果）："))
            }
        }
        lines.append(r.report.methodSummary)
        if let omnibus = r.report.omnibus { lines.append("\(omnibus.name): \(omnibus.reportLine)") }
        if let m = r.report.mixed {
            if let g = m.group { lines.append(String(format: tx(english, "Group: %@", "组：%@"), g.reportLine)) }
            lines.append("\(r.levelLabel.isEmpty ? tx(english, "Within", "组内") : r.levelLabel): \(m.level.reportLine)")
            if let i = m.interaction { lines.append(String(format: tx(english, "Interaction: %@", "交互作用：%@"), i.reportLine)) }
        }
        if let used = r.report.animalsInTest {
            lines.append(String(format: tx(english, "Animals in the repeated-measures test: %d (left out for a missing %@: %d)", "重复测量检验纳入 %d 只动物（缺少某个%@而未纳入：%d 只）"),
                                used, levelWord(r.levelLabel), r.report.animalsLeftOut))
        }
        for c in r.report.pairwise {
            lines.append(GroupReportText.pairLine(c, english: english))
        }
        for g in r.report.perGroup.keys.sorted() {
            if let t = r.report.perGroup[g] { lines.append("\(g) (\(r.report.perGroupLabel)): \(t.reportLine)") }
        }
        lines.append(contentsOf: GroupReportText.detailLines(r))
        lines.append(contentsOf: r.notes)
        lines.append(tx(english, "n = animals. Generated with \(AppInfo.name) (RodentFlow 1.3 group-analysis methods).",
                        "n = 小鼠数。由 \(AppInfo.name) 生成（RodentFlow 1.3 组间分析方法）。"))
        return lines.joined(separator: "\n")
    }
}
