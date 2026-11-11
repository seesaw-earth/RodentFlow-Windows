// GroupABI.swift — the group comparison of a task (rf_group_analysis), as the Mac's task page shows it.
//
//   in    the task (paradigm), its sessions — each with the summary rf_analyze returned for it (SessionMetricSummary,
//         the Mac's saved summary) and the session's animal, group, phase, day, trial, session number, sex,
//         exclusion and tracking verdict — the request (GroupAnalysisRequest; omitted = the task's default) and the
//         plot style (GroupPlotStyle).
//   out   what the controls offer (designs, measures, series, pairs, phases, sessions, groups, second factors), the
//         request and style actually used, the result's texts (GroupAnalysisEngine.summaryText,
//         GroupReportText.detailLines), the descriptives per group, the statistics and long-format tables
//         (GroupReportText.statsReportCSV / longFormatCSV), and the figure (PubGroupFigure.build) both as drawing
//         items and as SVG (PubSVG.render).
//
// The Mac shows the same publication figure on screen (PubFigureView of PubGroupFigure.build, GroupCharts.swift),
// so the Windows page draws these items and both apps show and export one and the same figure.

import Foundation

enum GroupABI {
    struct SessionInput: Decodable {
        var id: UUID
        var subjectID: String
        var subjectKey: String
        var group: String
        var phase: String
        var day: Int?
        var trial: Int?
        var session: Int?
        var date: String?
        var excluded: Bool
        var exclusionReason: String?
        var sex: String?
        var trackingProblem: Bool?
        var summary: SessionMetricSummary
    }

    struct Request: Decodable {
        var paradigm: String
        var taskName: String?
        var sessions: [SessionInput]
        var request: GroupAnalysisRequest?
        var style: GroupPlotStyle?
        var settings: FigureExportSettings?
        /// Texts and figure in English (files), else the interface language.
        var english: Bool?
        /// Curves: every animal's own line under the group means.
        var showAnimals: Bool?
    }

    static func run(_ r: Request) throws -> [String: Any] {
        guard let paradigm = Paradigm(rawValue: r.paradigm), let assay = StudyAssay(paradigm: paradigm) else {
            throw RFError.badArgument("Unknown task " + r.paradigm)
        }
        let english = r.english ?? false
        let summaries = r.sessions.map { $0.summary }
        var records: [GroupRecord] = []
        for s in r.sessions {
            records.append(GroupRecord(id: s.id, subjectID: s.subjectID, subjectKey: s.subjectKey, group: s.group,
                                       phase: s.phase, day: s.day, trial: s.trial, session: s.session, date: s.date,
                                       metrics: s.summary.values, series: s.summary.series, excluded: s.excluded,
                                       exclusionReason: s.exclusionReason ?? "", qcFlags: s.summary.qcFlags,
                                       trackingProblem: s.trackingProblem ?? false, sex: s.sex ?? "",
                                       model: s.summary.model ?? ""))
        }
        let firstContext = TaskMetricDefinitions.context(assay: assay, summaries: summaries, phase: r.request?.phaseFilter)
        let designs = GroupAnalysisEngine.availableDesigns(firstContext, records: records)
        var req = r.request ?? GroupAnalysisEngine.defaultRequest(firstContext, records: records)
        // A design no longer possible (sessions were removed) falls back to the task's default.
        if !designs.contains(req.design) { req = GroupAnalysisEngine.defaultRequest(firstContext, records: records) }
        let context = TaskMetricDefinitions.context(assay: assay, summaries: summaries, phase: req.phaseFilter)
        let result = GroupAnalysisEngine.run(req, records: records, context: context, english: english)

        var colorIndex: [String: Int] = [:]
        let allGroups = GroupAnalysisEngine.orderedGroups(records)
        for (i, g) in allGroups.enumerated() { colorIndex[g] = i }
        let style = r.style ?? GroupPlotStyle()
        let settings = r.settings ?? FigureExportSettings()
        let figure = PubGroupFigure.build(result, colorIndex: colorIndex, style: style, settings: settings,
                                          showAnimals: r.showAnimals ?? false)
        let taskName = r.taskName ?? assay.rawValue

        var out: [String: Any] = [:]
        out["request"] = try RFCoding.tree(req)
        out["style"] = try RFCoding.tree(style)
        out["options"] = GroupABI.options(context, records: records, groups: allGroups, english: english)
        out["result"] = GroupABI.result(result, taskName: taskName, context: context)
        out["figure"] = GroupABI.figure(figure)
        out["svg"] = PubSVG.render(figure, title: result.metricName)
        return out
    }

    // MARK: What the controls offer

    static func options(_ context: GroupAnalysisContext, records: [GroupRecord], groups: [String], english: Bool) -> [String: Any] {
        func item(_ key: String, _ title: String) -> [String: Any] { ["key": key, "title": title] }
        var d: [String: Any] = [:]
        d["designs"] = GroupAnalysisEngine.availableDesigns(context, records: records).map { item($0.rawValue, $0.displayName) }
        d["metrics"] = GroupAnalysisEngine.metricOptions(context, records: records).map { m -> [String: Any] in
            ["key": m.key, "title": m.title(english: english), "unit": m.unitText(english: english)]
        }
        d["series"] = GroupAnalysisEngine.seriesOptions(records, english: english).map { s -> [String: Any] in
            ["key": s.key, "title": s.name, "unit": s.unit]
        }
        d["pairs"] = context.pairs.map { item($0.key, $0.title(english: english)) }
        d["phases"] = GroupAnalysisEngine.phases(records, assayPhases: context.assayPhases).map {
            item($0, context.phaseTitle($0, english: english))
        }
        d["sessions"] = GroupAnalysisEngine.sessions(records)
        d["days"] = GroupAnalysisEngine.days(records)
        d["groups"] = groups.map { item($0, $0.isEmpty ? GroupRecord.ungroupedLabel : $0) }
        d["factors"] = GroupAnalysisEngine.factorSources(records, groups: groups).map { item($0.rawValue, $0.displayName) }
        d["modes"] = StatMode.allCases.map { item($0.rawValue, $0.displayName) }
        d["comparisons"] = ComparisonMode.allCases.map { item($0.rawValue, $0.displayName) }
        d["plots"] = GroupPlotKind.allCases.map { item($0.rawValue, $0.displayName) }
        d["errors"] = ErrorBarKind.allCases.map { item($0.rawValue, $0.displayName) }
        d["significance"] = SignificanceLabel.allCases.map { item($0.rawValue, $0.displayName) }
        return d
    }

    // MARK: The result

    static func result(_ r: GroupAnalysisResult, taskName: String, context: GroupAnalysisContext) -> [String: Any] {
        var d: [String: Any] = [:]
        d["metricName"] = r.metricName
        d["unit"] = r.unit
        d["axisTitle"] = r.axisTitle
        d["animalCount"] = r.animalCount
        d["isEmpty"] = r.isEmpty
        d["main"] = r.main.rawValue
        d["mainNote"] = r.mainNote
        d["notes"] = r.notes
        d["crossoverSubjects"] = r.crossoverSubjects
        d["summary"] = GroupAnalysisEngine.summaryText(r, taskName: taskName, context: context)
        d["details"] = GroupReportText.detailLines(r)
        d["statsCsv"] = GroupReportText.statsReportCSV(r, taskName: taskName)
        d["longCsv"] = GroupReportText.longFormatCSV(r, taskName: taskName)
        var rows: [[String: Any]] = []
        for g in r.groups {
            guard let s = r.descriptives[g] else { continue }
            var row: [String: Any] = [:]
            row["group"] = g.isEmpty ? GroupRecord.ungroupedLabel : g
            row["n"] = s.n
            row["mean"] = RFJSON.number(s.mean)
            row["sd"] = RFJSON.number(s.sd)
            row["sem"] = RFJSON.number(s.sem)
            row["median"] = RFJSON.number(s.median)
            row["q1"] = RFJSON.number(s.q1)
            row["q3"] = RFJSON.number(s.q3)
            row["min"] = RFJSON.number(s.min)
            row["max"] = RFJSON.number(s.max)
            rows.append(row)
        }
        d["descriptives"] = rows
        return d
    }

    // MARK: The figure as drawing items

    static func color(_ c: PubColor) -> [Any] {
        [RFJSON.number(c.r), RFJSON.number(c.g), RFJSON.number(c.b), RFJSON.number(c.a)]
    }

    static func figure(_ f: PubFigure) -> [String: Any] {
        var items: [[String: Any]] = []
        for item in f.items {
            switch item {
            case .shape(let path, let fill, let stroke):
                var ops: [Any] = []
                for op in path.ops {
                    switch op {
                    case .move(let p): ops.append(["M", RFJSON.number(p.x), RFJSON.number(p.y)] as [Any])
                    case .line(let p): ops.append(["L", RFJSON.number(p.x), RFJSON.number(p.y)] as [Any])
                    case .curve(let c1, let c2, let p):
                        ops.append(["C", RFJSON.number(c1.x), RFJSON.number(c1.y), RFJSON.number(c2.x), RFJSON.number(c2.y),
                                    RFJSON.number(p.x), RFJSON.number(p.y)] as [Any])
                    case .close: ops.append(["Z"] as [Any])
                    }
                }
                var shape: [String: Any] = [:]
                shape["kind"] = "shape"
                shape["ops"] = ops
                if let fill { shape["fill"] = GroupABI.color(fill) }
                if let s = stroke {
                    var st: [String: Any] = [:]
                    st["color"] = GroupABI.color(s.color)
                    st["width"] = RFJSON.number(s.width)
                    st["dash"] = s.dash.map { RFJSON.number($0) }
                    shape["stroke"] = st
                }
                items.append(shape)
            case .text(let t):
                var text: [String: Any] = [:]
                text["kind"] = "text"
                text["text"] = t.text
                text["x"] = RFJSON.number(t.at.x)
                text["y"] = RFJSON.number(t.at.y)
                text["size"] = RFJSON.number(t.size)
                text["bold"] = t.bold
                text["color"] = GroupABI.color(t.color)
                switch t.anchor {
                case .start: text["anchor"] = "start"
                case .middle: text["anchor"] = "middle"
                case .end: text["anchor"] = "end"
                }
                switch t.baseline {
                case .alphabetic: text["baseline"] = "alphabetic"
                case .middle: text["baseline"] = "middle"
                case .hanging: text["baseline"] = "hanging"
                }
                text["rotation"] = RFJSON.number(t.rotation)
                items.append(text)
            }
        }
        var d: [String: Any] = [:]
        d["width"] = RFJSON.number(f.width)
        d["height"] = RFJSON.number(f.height)
        if let bg = f.background { d["background"] = GroupABI.color(bg) }
        d["items"] = items
        return d
    }
}

/// The group comparison of a task: see the file header. `{paradigm, taskName, sessions, request?, style?, english?}`.
@_cdecl("rf_group_analysis")
public func rf_group_analysis(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_group_analysis: no request"))
    }
    do {
        let request = try RFCoding.decode(GroupABI.Request.self, from: text)
        return rfMakeCString(RFJSON.ok(try GroupABI.run(request)))
    } catch {
        return rfMakeCString(RFJSON.failure((error as? LocalizedError)?.errorDescription ?? String(describing: error)))
    }
}
