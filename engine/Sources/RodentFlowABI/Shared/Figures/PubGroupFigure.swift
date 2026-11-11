// PubGroupFigure.swift — the group comparison as a publication figure (RodentFlow 2.0: iOS build 15, Mac build 14):
// one value per animal as dots with mean ± error / bars / Tukey boxes / violins, significance brackets from the
// pairwise comparisons, curves across days / sessions / bins, paired measures joined per animal, and Kaplan–Meier
// curves. The group page draws exactly this figure, and every export writes it (PDF, PNG, SVG). Foundation only.
// Build 23: brackets come only from the main analysis (GroupReportText.bracketComparisons); a 0/1 measure is drawn
// as proportions with Wilson 95% CIs; bar charts always start at 0 and a fixed Y range clips marks to the plot
// (values outside are drawn at the edge with a count note); grayscale curves cycle four dash patterns.

import Foundation

/// Figure colors of the groups: the Okabe–Ito based palette of the group page (light variants), or grays.
enum PubPalette {
    static let groupHex: [UInt32] = [0x6B7280, 0x0072B2, 0xD55E00, 0x009E73, 0xCC79A7, 0xB07A00, 0x3A93C3, 0x7F3C8D]
    private static let grays: [Double] = [0.15, 0.55, 0.8, 0.35, 0.65, 0.25, 0.9, 0.45]

    static func group(_ index: Int) -> PubColor {
        PubColor(hex: groupHex[((index % groupHex.count) + groupHex.count) % groupHex.count])
    }

    static func gray(_ index: Int) -> PubColor { PubColor.gray(grays[((index % grays.count) + grays.count) % grays.count]) }

    static func darker(_ c: PubColor) -> PubColor { PubColor(r: c.r * 0.72, g: c.g * 0.72, b: c.b * 0.72, a: c.a) }
}

enum PubGroupFigure {
    private struct Axis {
        var x0: Double, x1: Double, top: Double, bottom: Double
        var lo: Double, hi: Double
        func y(_ v: Double) -> Double { bottom - (v - lo) / max(hi - lo, 1e-12) * (bottom - top) }
    }

    private static func tickText(_ v: Double, step: Double) -> String {
        var decimals = 0
        var scaled = abs(step)
        while decimals < 6 && scaled > 0 && abs(scaled - scaled.rounded()) > 1e-6 * max(1, scaled) {
            scaled *= 10
            decimals += 1
        }
        let s = String(format: "%.\(decimals)f", v)
        return s == "-0" ? "0" : s
    }

    private static func label(_ g: String, _ english: Bool) -> String { english ? g : groupDisplayName(g) }

    /// Group color (or gray) and marker shape.
    private static func paint(_ g: String, index i: Int, colorIndex: [String: Int], style: GroupPlotStyle) -> (color: PubColor, shape: Int) {
        style.grayscale ? (PubPalette.gray(i), i % 4) : (PubPalette.group(colorIndex[g] ?? i), 0)
    }

    /// Color (or gray) and marker of the group at `index` of `drawnGroups` (legend under the on-screen figure).
    static func swatch(_ g: String, index: Int, colorIndex: [String: Int], style: GroupPlotStyle) -> (color: PubColor, shape: Int) {
        paint(g, index: index, colorIndex: colorIndex, style: style)
    }

    /// Groups in the order the figure draws them (their index sets the gray and marker in grayscale).
    static func drawnGroups(_ r: GroupAnalysisResult) -> [String] {
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            if r.main == .proportion, let pr = r.proportion { return pr.rows.filter { $0.animals > 0 }.map(\.key) }
            return r.groups.filter { g in r.points.contains { $0.group == g } }
        case .byDay, .bySession, .withinSession: return r.groups.filter { g in r.subjectSeries.contains { $0.group == g } }
        case .pairedMeasures: return r.groups.filter { g in r.paired.contains { $0.group == g } }
        }
    }

    private static func yAxis(_ fig: inout PubFigure, _ ax: Axis, ticks: [Double], title: String, font f: Double) {
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
        fig.stroke(PubPath.segment(ax.x0, ax.top, ax.x0, ax.bottom), .ink, 0.6)
        for t in ticks {
            let y = ax.y(t)
            fig.stroke(PubPath.segment(ax.x0 - f * 0.35, y, ax.x0, y), .ink, 0.6)
            fig.text(PubText(text: tickText(t, step: step), at: PubPoint(ax.x0 - f * 0.5, y), size: f, anchor: .end, baseline: .middle))
        }
        let maxTick = ticks.map { PubTextMetrics.width(tickText($0, step: step), size: f) }.max() ?? 0
        fig.text(PubText(text: title, at: PubPoint(ax.x0 - f * 0.9 - maxTick, (ax.top + ax.bottom) / 2), size: f,
                         anchor: .middle, baseline: .alphabetic, rotation: -90))
    }

    private static func leftMargin(ticks: [Double], font f: Double) -> Double {
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
        let maxTick = ticks.map { PubTextMetrics.width(tickText($0, step: step), size: f) }.max() ?? f
        return maxTick + f * 2.3
    }

    /// Dots spread sideways so that equal values do not hide each other (a simple deterministic beeswarm).
    private static func swarm(_ ys: [Double], radius r: Double, maxOffset: Double) -> [Double] {
        let order = ys.indices.sorted { ys[$0] < ys[$1] }
        var placed: [(x: Double, y: Double)] = []
        var out = [Double](repeating: 0, count: ys.count)
        let d = r * 1.1
        for i in order {
            let y = ys[i]
            var chosen = 0.0
            var k = 0
            while true {
                let step = Double((k + 1) / 2) * d * (k % 2 == 0 ? 1 : -1)
                if abs(step) > maxOffset { chosen = 0; break }
                if !placed.contains(where: { ($0.x - step) * ($0.x - step) + ($0.y - y) * ($0.y - y) < (1.9 * r) * (1.9 * r) }) {
                    chosen = step
                    break
                }
                k += 1
            }
            placed.append((x: chosen, y: y))
            out[i] = chosen
        }
        return out
    }

    // MARK: Public

    static func build(_ r: GroupAnalysisResult, colorIndex: [String: Int], style: GroupPlotStyle,
                      settings: FigureExportSettings, showAnimals: Bool = false) -> PubFigure {
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            if r.main == .proportion, let pr = r.proportion { return proportions(r, pr, colorIndex: colorIndex, style: style, settings: settings) }
            return independent(r, colorIndex: colorIndex, style: style, settings: settings)
        case .byDay, .bySession, .withinSession: return curves(r, colorIndex: colorIndex, style: style, settings: settings, showAnimals: showAnimals)
        case .pairedMeasures: return paired(r, colorIndex: colorIndex, style: style, settings: settings)
        }
    }

    // MARK: Y range

    /// The automatic Y range of the figure (what a fixed range is seeded with when it is switched on).
    static func autoYRange(_ r: GroupAnalysisResult, style: GroupPlotStyle, showAnimals: Bool = false) -> (low: Double, high: Double) {
        var auto = style
        auto.yMin = nil
        auto.yMax = nil
        let range: (Double, Double)
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            if r.main == .proportion && r.proportion != nil { return (0, 100) }
            let groups = r.groups.filter { g in r.points.contains { $0.group == g } }
            range = independentAutoRange(r, groups: groups, values: groups.map { g in r.points.filter { $0.group == g }.map(\.value) }, style: auto)
        case .byDay, .bySession, .withinSession:
            range = curveAutoRange(r, summary: curveSummary(r, style: auto), showAnimals: showAnimals)
        case .pairedMeasures:
            range = pairedAutoRange(r)
        }
        return (low: range.0, high: range.1)
    }

    private static func independentAutoRange(_ r: GroupAnalysisResult, groups: [String], values: [[Double]], style: GroupPlotStyle) -> (Double, Double) {
        // Data, error bars, whiskers; bars start at zero.
        var extra: [Double] = []
        for g in groups {
            if let d = r.descriptives[g], d.n > 0 {
                let e = style.error.bounds(d)
                extra += [e.low, e.high, d.mean]
            }
        }
        if style.kind == .violin {
            for v in values {
                let dv = GroupGeometry.violin(v)
                if let a = dv.first?.y, let b = dv.last?.y { extra += [a, b] }
            }
        }
        let all = values.flatMap { $0 }
        let nonNegative = (all + extra).allSatisfy { $0 >= 0 }
        let wantsZero = style.kind == .barDots || (nonNegative && (all.min() ?? 0) < 0.5 * (all.max() ?? 0))
        var (lo, hi) = GroupGeometry.autoRange(values: all, extra: extra, includeZero: wantsZero)
        if nonNegative && wantsZero { lo = max(0, lo) }
        return (lo, hi)
    }

    private static func curveAutoRange(_ r: GroupAnalysisResult, summary: [String: [CurveMark]], showAnimals: Bool) -> (Double, Double) {
        let extra = summary.values.flatMap { $0 }.flatMap { [$0.low, $0.high] }
        let animalValues = showAnimals ? r.subjectSeries.flatMap { $0.values.compactMap { $0 } } : []
        var (lo, hi) = GroupGeometry.autoRange(values: extra + animalValues, includeZero: (extra + animalValues).allSatisfy { $0 >= 0 })
        if (extra + animalValues).allSatisfy({ $0 >= 0 }) { lo = max(0, lo) }
        return (lo, hi)
    }

    private static func pairedAutoRange(_ r: GroupAnalysisResult) -> (Double, Double) {
        let all = r.paired.flatMap { [$0.a, $0.b] }
        var (lo, hi) = GroupGeometry.autoRange(values: all, includeZero: all.allSatisfy { $0 >= 0 })
        if all.allSatisfy({ $0 >= 0 }) { lo = max(0, lo) }
        return (lo, hi)
    }

    /// The style's fixed range over the automatic one. Bars always start at 0 (a bar from another baseline
    /// misstates its length).
    private static func yRange(_ auto: (Double, Double), style: GroupPlotStyle, bars: Bool) -> (Double, Double) {
        var (lo, hi) = auto
        if let a = style.yMin { lo = a }
        if let b = style.yMax { hi = b }
        if bars { lo = min(lo, 0); hi = max(hi, 0) }
        if hi <= lo { hi = lo + 1 }
        return (lo, hi)
    }

    /// One line under the plot saying how many values fall outside a fixed Y range.
    private static func rangeNote(_ fig: inout PubFigure, _ text: String, x: Double, font f: Double) {
        fig.text(PubText(text: text, at: PubPoint(x, fig.height - f * 0.8), size: f * 0.9, color: .secondaryInk, anchor: .start, baseline: .middle))
    }

    private static func outsideText(_ count: Int, animals: Bool, drawn: Bool, english: Bool) -> String {
        if english || !Lang.isChinese {
            let what = animals ? (count == 1 ? "animal value lies" : "animal values lie") : (count == 1 ? "value lies" : "values lie")
            return "\(count) \(what) outside the Y-axis range" + (drawn ? "; drawn at its edge (open symbols)." : ".")
        }
        return "\(count) 个" + (animals ? "动物数值" : "数值") + "超出 Y 轴范围" + (drawn ? "，画在边缘（空心符号）。" : "。")
    }

    /// Values drawn in the figure, one row per animal, plus the summary rows (figure source data).
    static func sourceDataCSV(_ r: GroupAnalysisResult, style: GroupPlotStyle) -> String {
        func n(_ v: Double) -> String { v.isFinite ? String(format: "%.6g", v) : "" }
        var lines: [String] = []
        switch r.request.design {
        case .betweenGroups, .phaseChange:
            lines.append("group,animal_id,value")
            for p in r.points {
                let row: [String] = [csv(p.group), csv(p.subject), n(p.value)]
                lines.append(row.joined(separator: ","))
            }
            lines.append("")
            lines.append("group,n,mean,sd,sem,error_low,error_high,error_kind,median,q1,q3")
            for g in r.groups {
                guard let d = r.descriptives[g], d.n > 0 else { continue }
                let e = style.error.bounds(d)
                let count: String = String(d.n)
                // A proportion figure draws Wilson intervals (next block), not these error bars.
                let drawn = r.main != .proportion
                let row: [String] = [csv(g), count, n(d.mean), n(d.sd), n(d.sem), drawn ? n(e.low) : "", drawn ? n(e.high) : "",
                                     drawn ? style.error.rawValue : "not drawn (Wilson CI below)",
                                     n(d.median), n(d.q1), n(d.q3)]
                lines.append(row.joined(separator: ","))
            }
            if r.main == .proportion, let pr = r.proportion {
                lines.append("")
                lines.append("group,animals,with_outcome,percent,wilson_low_pct,wilson_high_pct")
                for row in pr.rows {
                    let w = row.wilson
                    let cells: [String] = [csv(row.key.isEmpty ? row.group : row.key), String(row.animals), String(row.events),
                                           n(row.proportion * 100), n(w.low * 100), n(w.high * 100)]
                    lines.append(cells.joined(separator: ","))
                }
            }
        case .byDay, .bySession, .withinSession:
            lines.append("group,animal_id,level,value")
            for s in r.subjectSeries {
                for (j, v) in s.values.enumerated() where j < r.levels.count {
                    if let v {
                        let row: [String] = [csv(s.group), csv(s.subject), n(r.levels[j]), n(v)]
                        lines.append(row.joined(separator: ","))
                    }
                }
            }
            lines.append("")
            // The error drawn is the style's (SEM, SD or 95% CI); sem stays in its own column.
            lines.append("group,level,n,mean,sem,sd,error_low,error_high,error_kind")
            for c in r.curves {
                let count: String = String(c.n)
                let j = r.levels.firstIndex(of: c.level)
                let v = r.subjectSeries.filter { $0.group == c.group }.compactMap { s -> Double? in
                    guard let j, j < s.values.count else { return nil }
                    return s.values[j]
                }
                let d = Stats.describe(v)
                let e = style.error.bounds(d)
                let row: [String] = [csv(c.group), n(c.level), count, n(c.mean), n(c.sem), n(d.sd), n(e.low), n(e.high), style.error.rawValue]
                lines.append(row.joined(separator: ","))
            }
        case .pairedMeasures:
            lines.append("group,animal_id,\(csv(r.pairLabelA)),\(csv(r.pairLabelB))")
            for p in r.paired {
                let row: [String] = [csv(p.group), csv(p.subject), n(p.a), n(p.b)]
                lines.append(row.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csv(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    // MARK: One value per animal

    private static func independent(_ r: GroupAnalysisResult, colorIndex: [String: Int], style: GroupPlotStyle,
                                    settings: FigureExportSettings) -> PubFigure {
        let f = settings.font
        let groups = r.groups.filter { g in r.points.contains { $0.group == g } }
        let k = max(groups.count, 1)
        let width = settings.widthPt
        var fig = PubFigure(width: width, height: settings.heightPt(aspect: 0.72))
        let values = groups.map { g in r.points.filter { $0.group == g }.map(\.value) }

        let (lo, hi) = yRange(independentAutoRange(r, groups: groups, values: values, style: style), style: style, bars: style.kind == .barDots)
        let ticks = GroupGeometry.ticks(lo, hi)
        let outside = values.flatMap { $0 }.filter { $0 < lo || $0 > hi }.count

        // Brackets: comparisons of the main analysis only.
        let (pairs, labels) = bracketPairs(r, groups: groups, style: style)
        let rows = GroupGeometry.bracketRows(pairs)
        let rowH = f * 1.6
        let bracketSpace = pairs.isEmpty ? 0 : Double((rows.max() ?? 0) + 1) * rowH

        let left = leftMargin(ticks: ticks, font: f)
        let slot = (width - left - f * 0.8) / Double(k)
        let groupLabels = groups.map { PubTextMetrics.wrap(label($0, r.english), size: f, maxWidth: slot * 0.95) }
        let labelLines = Double(groupLabels.map(\.count).max() ?? 1)
        let bottomSpace = f * (labelLines * 1.2 + 0.9) + (outside > 0 ? f * 1.4 : 0)
        var ax = Axis(x0: left, x1: width - f * 0.8, top: f * 0.6 + bracketSpace, bottom: fig.height - bottomSpace, lo: lo, hi: hi)
        if ax.bottom - ax.top < f * 4 { ax.bottom = ax.top + f * 4; fig.height = ax.bottom + bottomSpace }
        let axis = ax
        // Marks never leave the plot: values beyond a fixed range sit at its edge.
        func cy(_ v: Double) -> Double { axis.y(min(max(v, lo), hi)) }
        yAxis(&fig, ax, ticks: ticks, title: r.axisTitle, font: f)
        fig.stroke(PubPath.segment(ax.x0, ax.bottom, ax.x1, ax.bottom), .ink, 0.6)

        let radius = max(1.1, f * 0.25)
        for (i, g) in groups.enumerated() {
            let cx = ax.x0 + slot * (Double(i) + 0.5)
            let (color, shape) = paint(g, index: i, colorIndex: colorIndex, style: style)
            let line = style.grayscale ? PubColor.black : PubPalette.darker(color)
            let v = values[i]
            let half = min(slot * 0.3, f * 3.2)
            if let d = r.descriptives[g], d.n > 0 {
                let e = style.error.bounds(d)
                switch style.kind {
                case .barDots:
                    let y0 = cy(0), y1 = cy(d.mean)
                    fig.shape(PubPath.rect(cx - half, min(y0, y1), 2 * half, abs(y1 - y0)),
                              fill: style.grayscale ? color.opacity(0.55) : color.opacity(0.35), stroke: line, width: 0.6)
                    errorBar(&fig, cx: cx, low: cy(e.low), high: cy(e.high), cap: half * 0.45, color: line)
                case .dots:
                    fig.stroke(PubPath.segment(cx - half, cy(d.mean), cx + half, cy(d.mean)), line, 1.1)
                    errorBar(&fig, cx: cx, low: cy(e.low), high: cy(e.high), cap: half * 0.45, color: line)
                case .box:
                    if let b = GroupGeometry.box(v) {
                        fig.shape(PubPath.rect(cx - half, cy(b.q3), 2 * half, cy(b.q1) - cy(b.q3)),
                                  fill: color.opacity(style.grayscale ? 0.45 : 0.18), stroke: line, width: 0.6)
                        fig.stroke(PubPath.segment(cx - half, cy(b.median), cx + half, cy(b.median)), line, 1.1)
                        fig.stroke(PubPath.segment(cx, cy(b.q3), cx, cy(b.whiskerHigh)), line, 0.6)
                        fig.stroke(PubPath.segment(cx, cy(b.q1), cx, cy(b.whiskerLow)), line, 0.6)
                        fig.stroke(PubPath.segment(cx - half * 0.4, cy(b.whiskerHigh), cx + half * 0.4, cy(b.whiskerHigh)), line, 0.6)
                        fig.stroke(PubPath.segment(cx - half * 0.4, cy(b.whiskerLow), cx + half * 0.4, cy(b.whiskerLow)), line, 0.6)
                    }
                case .violin:
                    let dens = GroupGeometry.violin(v)
                    let maxD = dens.map(\.density).max() ?? 0
                    if maxD > 0 {
                        let w = min(slot * 0.4, f * 4)
                        let right = dens.map { PubPoint(cx + w * $0.density / maxD, cy($0.y)) }
                        let leftSide = dens.reversed().map { PubPoint(cx - w * $0.density / maxD, cy($0.y)) }
                        fig.shape(PubPath.polyline(right + leftSide, closed: true), fill: color.opacity(style.grayscale ? 0.45 : 0.2), stroke: line, width: 0.6)
                    }
                    if let b = GroupGeometry.box(v) {
                        fig.stroke(PubPath.segment(cx - half * 0.55, cy(b.median), cx + half * 0.55, cy(b.median)), line, 1.1)
                        fig.stroke(PubPath.segment(cx - half * 0.35, cy(b.q1), cx + half * 0.35, cy(b.q1)), line, 0.6, dash: [1.2, 1.2])
                        fig.stroke(PubPath.segment(cx - half * 0.35, cy(b.q3), cx + half * 0.35, cy(b.q3)), line, 0.6, dash: [1.2, 1.2])
                    }
                }
            }
            if style.showPoints {
                let ys = v.map { cy($0) }
                let dx = swarm(ys, radius: radius, maxOffset: slot * 0.36)
                for (j, y) in ys.enumerated() {
                    let path = PubPath.marker(shape, cx + dx[j], y, radius)
                    if v[j] < lo || v[j] > hi {
                        fig.shape(path, fill: .white, stroke: line, width: 0.6)
                    } else if style.grayscale {
                        fig.shape(path, fill: color, stroke: .black, width: 0.4)
                    } else {
                        fig.shape(path, fill: color.opacity(0.9), stroke: .white, width: 0.3)
                    }
                }
            }
            for (li, text) in groupLabels[i].enumerated() {
                fig.text(PubText(text: text, at: PubPoint(cx, ax.bottom + f * (0.5 + 1.15 * Double(li))), size: f, anchor: .middle, baseline: .hanging))
            }
        }
        // Reference line: no change (phase differences) or the measure's reference value when it is tested.
        let reference: Double? = r.request.design == .phaseChange ? 0 : (r.request.testAgainstChance ? r.chance : nil)
        if let ref = reference, ref >= lo, ref <= hi {
            fig.stroke(PubPath.segment(ax.x0, ax.y(ref), ax.x1, ax.y(ref)), .secondaryInk, 0.5, dash: [2, 2])
        }
        drawBrackets(&fig, pairs: pairs, labels: labels, rows: rows, ax: ax, slot: slot, font: f)
        if outside > 0 { rangeNote(&fig, outsideText(outside, animals: true, drawn: style.showPoints, english: r.english), x: f * 0.5, font: f) }
        return fig
    }

    /// Bracketed comparisons (indices into `groups`) and their labels.
    private static func bracketPairs(_ r: GroupAnalysisResult, groups: [String], style: GroupPlotStyle) -> (pairs: [(a: Int, b: Int)], labels: [String]) {
        var pairs: [(a: Int, b: Int)] = []
        var labels: [String] = []
        for c in GroupReportText.bracketComparisons(r) where style.bracketed(c.pAdjusted) {
            guard let ia = groups.firstIndex(of: c.groupA), let ib = groups.firstIndex(of: c.groupB) else { continue }
            pairs.append((a: ia, b: ib))
            labels.append(style.label(c.pAdjusted))
        }
        return (pairs, labels)
    }

    private static func drawBrackets(_ fig: inout PubFigure, pairs: [(a: Int, b: Int)], labels: [String], rows: [Int], ax: Axis, slot: Double, font f: Double) {
        let rowH = f * 1.6
        for (pi, pr) in pairs.enumerated() {
            let inset = slot * 0.05
            let xa = ax.x0 + slot * (Double(min(pr.a, pr.b)) + 0.5) + inset, xb = ax.x0 + slot * (Double(max(pr.a, pr.b)) + 0.5) - inset
            let y = ax.top - f * 0.3 - Double(rows[pi]) * rowH
            var path = PubPath()
            path.move(xa, y + f * 0.35); path.line(xa, y); path.line(xb, y); path.line(xb, y + f * 0.35)
            fig.stroke(path, .ink, 0.6)
            fig.text(PubText(text: labels[pi], at: PubPoint((xa + xb) / 2, y - f * 0.2), size: f, anchor: .middle, baseline: .alphabetic))
        }
    }

    private static func errorBar(_ fig: inout PubFigure, cx: Double, low: Double, high: Double, cap: Double, color: PubColor) {
        guard abs(high - low) > 0.01 else { return }
        fig.stroke(PubPath.segment(cx, low, cx, high), color, 0.7)
        fig.stroke(PubPath.segment(cx - cap, low, cx + cap, low), color, 0.7)
        fig.stroke(PubPath.segment(cx - cap, high, cx + cap, high), color, 0.7)
    }

    // MARK: Proportions (0/1 measures)

    /// Percentage of animals with the outcome per group (bar for "Bar + dots", otherwise a point), Wilson 95% CI,
    /// "k/n" under each group, animals as 0 / 100 % dots, brackets from the Fisher tests. The axis is always 0–100 %.
    private static func proportions(_ r: GroupAnalysisResult, _ pr: ProportionTest, colorIndex: [String: Int], style: GroupPlotStyle,
                                    settings: FigureExportSettings) -> PubFigure {
        let f = settings.font
        let rowsData = pr.rows.filter { $0.animals > 0 }
        let groups = rowsData.map(\.key)
        let k = max(groups.count, 1)
        let width = settings.widthPt
        var fig = PubFigure(width: width, height: settings.heightPt(aspect: 0.72))
        let ticks = GroupGeometry.ticks(0, 100)
        let (pairs, labels) = bracketPairs(r, groups: groups, style: style)
        let rows = GroupGeometry.bracketRows(pairs)
        let bracketSpace = pairs.isEmpty ? 0 : Double((rows.max() ?? 0) + 1) * f * 1.6
        let left = leftMargin(ticks: ticks, font: f)
        let slot = (width - left - f * 0.8) / Double(k)
        let groupLabels = groups.map { PubTextMetrics.wrap(label($0, r.english), size: f, maxWidth: slot * 0.95) }
        let labelLines = Double(groupLabels.map(\.count).max() ?? 1) + 1
        let bottomSpace = f * (labelLines * 1.2 + 0.9)
        var ax = Axis(x0: left, x1: width - f * 0.8, top: f * 0.6 + bracketSpace, bottom: fig.height - bottomSpace, lo: 0, hi: 100)
        if ax.bottom - ax.top < f * 4 { ax.bottom = ax.top + f * 4; fig.height = ax.bottom + bottomSpace }
        let english = r.english || !Lang.isChinese
        yAxis(&fig, ax, ticks: ticks, title: r.metricName + (english ? " (% of animals)" : "（动物百分比）"), font: f)
        fig.stroke(PubPath.segment(ax.x0, ax.bottom, ax.x1, ax.bottom), .ink, 0.6)
        let radius = max(1.1, f * 0.25)
        for (i, row) in rowsData.enumerated() {
            let g = row.key
            let cx = ax.x0 + slot * (Double(i) + 0.5)
            let (color, shape) = paint(g, index: i, colorIndex: colorIndex, style: style)
            let line = style.grayscale ? PubColor.black : PubPalette.darker(color)
            let half = min(slot * 0.3, f * 3.2)
            let pct = row.proportion * 100
            let w = row.wilson
            if style.kind == .barDots {
                let y0 = ax.y(0), y1 = ax.y(pct)
                fig.shape(PubPath.rect(cx - half, min(y0, y1), 2 * half, abs(y1 - y0)),
                          fill: style.grayscale ? color.opacity(0.55) : color.opacity(0.35), stroke: line, width: 0.6)
            }
            errorBar(&fig, cx: cx, low: ax.y(w.low * 100), high: ax.y(w.high * 100), cap: half * 0.45, color: line)
            if style.kind != .barDots {
                fig.shape(PubPath.marker(shape, cx, ax.y(pct), f * 0.42), fill: color, stroke: line, width: 0.6)
            }
            if style.showPoints {
                let ys = r.points.filter { $0.group == g }.map { ax.y($0.value > 0 ? 100 : 0) }
                let dx = swarm(ys, radius: radius, maxOffset: slot * 0.36)
                for (j, y) in ys.enumerated() {
                    let path = PubPath.marker(shape, cx + dx[j], y, radius)
                    if style.grayscale {
                        fig.shape(path, fill: color, stroke: .black, width: 0.4)
                    } else {
                        fig.shape(path, fill: color.opacity(0.9), stroke: .white, width: 0.3)
                    }
                }
            }
            for (li, text) in groupLabels[i].enumerated() {
                fig.text(PubText(text: text, at: PubPoint(cx, ax.bottom + f * (0.5 + 1.15 * Double(li))), size: f, anchor: .middle, baseline: .hanging))
            }
            fig.text(PubText(text: "\(row.events)/\(row.animals)", at: PubPoint(cx, ax.bottom + f * (0.5 + 1.15 * Double(groupLabels[i].count))),
                             size: f, color: .secondaryInk, anchor: .middle, baseline: .hanging))
        }
        drawBrackets(&fig, pairs: pairs, labels: labels, rows: rows, ax: ax, slot: slot, font: f)
        return fig
    }

    // MARK: Legends of curves and Kaplan–Meier figures

    /// Legend entries: name, color, marker, and (grayscale) the line dash drawn as a short sample.
    private static func legendRow(_ fig: inout PubFigure, entries: [(String, PubColor, Int, [Double])], x: Double, y: Double, font f: Double,
                                  maxWidth: Double, withLine: Bool) {
        var cx = x
        var cy = y
        let sample = withLine ? f * 1.4 : 0
        for (name, color, shape, dash) in entries {
            let w = f * 1.3 + sample + PubTextMetrics.width(name, size: f) + f * 0.9
            if cx + w > x + maxWidth && cx > x { cx = x; cy += f * 1.3 }
            if withLine { fig.stroke(PubPath.segment(cx, cy, cx + sample + f * 0.7, cy), .black, 0.8, dash: dash) }
            fig.shape(PubPath.marker(shape, cx + sample / 2 + f * 0.35, cy, f * 0.3), fill: color, stroke: withLine ? PubColor.black : nil, width: 0.3)
            fig.text(PubText(text: name, at: PubPoint(cx + sample + f * 0.9, cy), size: f, anchor: .start, baseline: .middle))
            cx += w
        }
    }

    private static func legendHeight(_ names: [String], font f: Double, maxWidth: Double, withLine: Bool) -> Double {
        var cx = 0.0, rowsCount = 1.0
        let sample = withLine ? f * 1.4 : 0
        for name in names {
            let w = f * 1.3 + sample + PubTextMetrics.width(name, size: f) + f * 0.9
            if cx + w > maxWidth && cx > 0 { cx = 0; rowsCount += 1 }
            cx += w
        }
        return rowsCount * f * 1.3
    }

    // MARK: Curves (days, sessions, bins)

    private struct CurveMark {
        var x: Double
        var mean: Double
        var low: Double
        var high: Double
    }

    /// Mean and error (the style's kind) per group and level, from the animal values.
    private static func curveSummary(_ r: GroupAnalysisResult, style: GroupPlotStyle) -> [String: [CurveMark]] {
        var summary: [String: [CurveMark]] = [:]
        for g in r.groups {
            let gs = r.subjectSeries.filter { $0.group == g }
            for (j, x) in r.levels.enumerated() {
                let v = gs.compactMap { j < $0.values.count ? $0.values[j] : nil }
                guard !v.isEmpty else { continue }
                let d = Stats.describe(v)
                let e = style.error.bounds(d)
                summary[g, default: []].append(CurveMark(x: x, mean: d.mean, low: e.low, high: e.high))
            }
        }
        return summary
    }

    private static func curves(_ r: GroupAnalysisResult, colorIndex: [String: Int], style: GroupPlotStyle,
                               settings: FigureExportSettings, showAnimals: Bool) -> PubFigure {
        let f = settings.font
        let width = settings.widthPt
        var fig = PubFigure(width: width, height: settings.heightPt(aspect: 0.62))
        let groups = r.groups.filter { g in r.subjectSeries.contains { $0.group == g } }
        let levels = r.levels
        let summary = curveSummary(r, style: style)
        let (lo, hi) = yRange(curveAutoRange(r, summary: summary, showAnimals: showAnimals), style: style, bars: false)
        let ticks = GroupGeometry.ticks(lo, hi)
        var outside = summary.values.flatMap { $0 }.filter { $0.mean < lo || $0.mean > hi }.count
        if showAnimals { outside += r.subjectSeries.flatMap { $0.values.compactMap { $0 } }.filter { $0 < lo || $0 > hi }.count }
        let left = leftMargin(ticks: ticks, font: f)
        let legendNames = groups.map { label($0, r.english) }
        let legendH = legendHeight(legendNames, font: f, maxWidth: width - left - f, withLine: style.grayscale)
        let bottomSpace = f * 3.0 + (outside > 0 ? f * 1.4 : 0)
        var ax = Axis(x0: left, x1: width - f * 0.8, top: f * 0.8 + legendH, bottom: fig.height - bottomSpace, lo: lo, hi: hi)
        if ax.bottom - ax.top < f * 4 { ax.bottom = ax.top + f * 4; fig.height = ax.bottom + bottomSpace }
        let axis = ax
        func cy(_ v: Double) -> Double { axis.y(min(max(v, lo), hi)) }
        yAxis(&fig, ax, ticks: ticks, title: r.axisTitle, font: f)
        fig.stroke(PubPath.segment(ax.x0, ax.bottom, ax.x1, ax.bottom), .ink, 0.6)
        // X: whole-number levels (days, sessions, CS) are ticked at each level; bin centres sit inside their bins,
        // with nice ticks over the bins' full span.
        let xmin = levels.first ?? 0, xmax = levels.last ?? 1
        let whole = levels.allSatisfy { abs($0 - $0.rounded()) < 1e-9 }
        let spacing = zip(levels.dropFirst(), levels).map { $0 - $1 }.min() ?? 1
        let dlo = whole ? xmin : xmin - spacing / 2, dhi = whole ? xmax : xmax + spacing / 2
        let span = max(dhi - dlo, 1e-9)
        let pad = whole ? (ax.x1 - ax.x0) * 0.05 : 0
        func px(_ x: Double) -> Double { levels.count <= 1 ? (ax.x0 + ax.x1) / 2 : ax.x0 + pad + (x - dlo) / span * (ax.x1 - ax.x0 - 2 * pad) }
        let xticks: [Double]
        if levels.count <= 1 || (whole && levels.count <= 12) {
            xticks = levels
        } else {
            xticks = GroupGeometry.ticks(dlo, dhi).filter { $0 >= dlo - 1e-9 && $0 <= dhi + 1e-9 }
        }
        let xstep = xticks.count > 1 ? xticks[1] - xticks[0] : 1
        for t in xticks {
            fig.stroke(PubPath.segment(px(t), ax.bottom, px(t), ax.bottom + f * 0.35), .ink, 0.6)
            fig.text(PubText(text: tickText(t, step: xstep), at: PubPoint(px(t), ax.bottom + f * 0.5), size: f, anchor: .middle, baseline: .hanging))
        }
        fig.text(PubText(text: r.levelLabel, at: PubPoint((ax.x0 + ax.x1) / 2, ax.bottom + f * 1.8), size: f, anchor: .middle, baseline: .hanging))
        var legend: [(String, PubColor, Int, [Double])] = []
        for (i, g) in groups.enumerated() {
            let (color, shape) = paint(g, index: i, colorIndex: colorIndex, style: style)
            let line = style.grayscale ? PubColor.black : color
            let dash = style.dash(i)
            legend.append((label(g, r.english), color, shape, dash))
            if showAnimals {
                for s in r.subjectSeries where s.group == g {
                    let pts = s.values.enumerated().compactMap { item -> PubPoint? in
                        guard let v = item.element, item.offset < levels.count else { return nil }
                        return PubPoint(px(levels[item.offset]), cy(v))
                    }
                    if pts.count > 1 { fig.stroke(PubPath.polyline(pts), line.opacity(0.25), 0.4) }
                }
            }
            let pts = summary[g] ?? []
            if pts.count > 1 { fig.stroke(PubPath.polyline(pts.map { PubPoint(px($0.x), cy($0.mean)) }), line, 0.9, dash: dash) }
            for p in pts {
                errorBar(&fig, cx: px(p.x), low: cy(p.low), high: cy(p.high), cap: f * 0.3, color: line)
                let marker = PubPath.marker(shape, px(p.x), cy(p.mean), f * 0.3)
                if p.mean < lo || p.mean > hi {
                    fig.shape(marker, fill: .white, stroke: line, width: 0.6)
                } else {
                    fig.shape(marker, fill: color, stroke: style.grayscale ? .black : .white, width: 0.3)
                }
            }
        }
        legendRow(&fig, entries: legend, x: left, y: f * 0.7, font: f, maxWidth: width - left - f, withLine: style.grayscale)
        if outside > 0 { rangeNote(&fig, outsideText(outside, animals: false, drawn: true, english: r.english), x: f * 0.5, font: f) }
        return fig
    }

    // MARK: Paired measures

    private static func paired(_ r: GroupAnalysisResult, colorIndex: [String: Int], style: GroupPlotStyle,
                               settings: FigureExportSettings) -> PubFigure {
        let f = settings.font
        let width = settings.widthPt
        var fig = PubFigure(width: width, height: settings.heightPt(aspect: 0.72))
        let groups = r.groups.filter { g in r.paired.contains { $0.group == g } }
        let (lo, hi) = yRange(pairedAutoRange(r), style: style, bars: false)
        let outside = r.paired.flatMap { [$0.a, $0.b] }.filter { $0 < lo || $0 > hi }.count
        let ticks = GroupGeometry.ticks(lo, hi)
        let left = leftMargin(ticks: ticks, font: f)
        let bottomSpace = f * 3.2 + (outside > 0 ? f * 1.4 : 0)
        var ax = Axis(x0: left, x1: width - f * 0.8, top: f * 0.8, bottom: fig.height - bottomSpace, lo: lo, hi: hi)
        if ax.bottom - ax.top < f * 4 { ax.bottom = ax.top + f * 4; fig.height = ax.bottom + bottomSpace }
        let axis = ax
        func cy(_ v: Double) -> Double { axis.y(min(max(v, lo), hi)) }
        yAxis(&fig, ax, ticks: ticks, title: r.axisTitle, font: f)
        fig.stroke(PubPath.segment(ax.x0, ax.bottom, ax.x1, ax.bottom), .ink, 0.6)
        let slot = (ax.x1 - ax.x0) / Double(max(groups.count, 1))
        for (i, g) in groups.enumerated() {
            let (color, shape) = paint(g, index: i, colorIndex: colorIndex, style: style)
            let line = style.grayscale ? PubColor.black : color
            let xa = ax.x0 + slot * (Double(i) + 0.3), xb = ax.x0 + slot * (Double(i) + 0.7)
            let pts = r.paired.filter { $0.group == g }
            for p in pts {
                fig.stroke(PubPath.segment(xa, cy(p.a), xb, cy(p.b)), line.opacity(0.45), 0.5)
                for (x, v) in [(xa, p.a), (xb, p.b)] {
                    let marker = PubPath.marker(shape, x, cy(v), f * 0.24)
                    if v < lo || v > hi {
                        fig.shape(marker, fill: .white, stroke: line, width: 0.5)
                    } else {
                        fig.shape(marker, fill: color, stroke: nil)
                    }
                }
            }
            if !pts.isEmpty {
                let ma = Stats.mean(pts.map(\.a)), mb = Stats.mean(pts.map(\.b))
                let w = slot * 0.12
                fig.stroke(PubPath.segment(xa - w, cy(ma), xa + w, cy(ma)), PubPalette.darker(line), 1.3)
                fig.stroke(PubPath.segment(xb - w, cy(mb), xb + w, cy(mb)), PubPalette.darker(line), 1.3)
            }
            fig.text(PubText(text: r.pairLabelA, at: PubPoint(xa, ax.bottom + f * 0.5), size: f, anchor: .middle, baseline: .hanging))
            fig.text(PubText(text: r.pairLabelB, at: PubPoint(xb, ax.bottom + f * 0.5), size: f, anchor: .middle, baseline: .hanging))
            fig.text(PubText(text: label(g, r.english), at: PubPoint((xa + xb) / 2, ax.bottom + f * 1.75), size: f, bold: true, anchor: .middle, baseline: .hanging))
        }
        if outside > 0 { rangeNote(&fig, outsideText(outside, animals: true, drawn: true, english: r.english), x: f * 0.5, font: f) }
        return fig
    }

    // MARK: Kaplan–Meier

    static func survival(_ s: SurvivalResult, groups: [String], english: Bool, colorIndex: [String: Int], style: GroupPlotStyle,
                         settings: FigureExportSettings) -> PubFigure {
        let f = settings.font
        let width = settings.widthPt
        var fig = PubFigure(width: width, height: settings.heightPt(aspect: 0.62))
        let present = groups.filter { g in s.steps.contains { $0.group == g } }
        let tmax = max(s.steps.map(\.time).max() ?? 1, 1)
        let ticks = [0, 0.25, 0.5, 0.75, 1.0]
        let left = leftMargin(ticks: ticks, font: f)
        let names = present.map { label($0, english) }
        let legendH = legendHeight(names, font: f, maxWidth: width - left - f, withLine: style.grayscale)
        var ax = Axis(x0: left, x1: width - f * 0.8, top: f * 0.8 + legendH, bottom: fig.height - f * 3.0, lo: 0, hi: 1)
        if ax.bottom - ax.top < f * 4 { ax.bottom = ax.top + f * 4; fig.height = ax.bottom + f * 3.0 }
        let title = english || !Lang.isChinese ? "Proportion without " + s.eventName : "尚未" + s.eventName + "的比例"
        yAxis(&fig, ax, ticks: ticks, title: title, font: f)
        fig.stroke(PubPath.segment(ax.x0, ax.bottom, ax.x1, ax.bottom), .ink, 0.6)
        let xt = GroupGeometry.ticks(0, tmax)
        let xstep = xt.count > 1 ? xt[1] - xt[0] : 1
        let xmax = max(tmax, xt.last ?? tmax)
        func px(_ t: Double) -> Double { ax.x0 + t / xmax * (ax.x1 - ax.x0) }
        for t in xt {
            fig.stroke(PubPath.segment(px(t), ax.bottom, px(t), ax.bottom + f * 0.35), .ink, 0.6)
            fig.text(PubText(text: tickText(t, step: xstep), at: PubPoint(px(t), ax.bottom + f * 0.5), size: f, anchor: .middle, baseline: .hanging))
        }
        fig.text(PubText(text: english || !Lang.isChinese ? "Latency (s)" : "潜伏期 (s)", at: PubPoint((ax.x0 + ax.x1) / 2, ax.bottom + f * 1.8),
                         size: f, anchor: .middle, baseline: .hanging))
        var legend: [(String, PubColor, Int, [Double])] = []
        for g in present {
            // Gray, marker and dash by the group's place in `groups` (the groups drawn in the other figures and the
            // on-screen legend), so a group without Kaplan–Meier data does not shift the others.
            let i = groups.firstIndex(of: g) ?? 0
            let (color, shape) = paint(g, index: i, colorIndex: colorIndex, style: style)
            let line = style.grayscale ? PubColor.black : color
            let dash = style.dash(i)
            legend.append((label(g, english), color, shape, dash))
            let pts = s.steps.filter { $0.group == g }.map { PubPoint(px($0.time), ax.y($0.survival)) }
            if pts.count > 1 { fig.stroke(PubPath.polyline(pts), line, 0.9, dash: dash) }
            for c in s.censored where c.group == g {
                let x = px(c.time), y = ax.y(c.survival), h = f * 0.3
                if style.grayscale {
                    // Censoring marks keep the group's marker shape (open) so the groups stay apart in print.
                    fig.shape(PubPath.marker(shape, x, y, h * 0.9), fill: .white, stroke: .black, width: 0.6)
                } else {
                    fig.stroke(PubPath.segment(x - h, y, x + h, y), line, 0.6)
                    fig.stroke(PubPath.segment(x, y - h, x, y + h), line, 0.6)
                }
            }
        }
        legendRow(&fig, entries: legend, x: left, y: f * 0.7, font: f, maxWidth: width - left - f, withLine: style.grayscale)
        return fig
    }
}
