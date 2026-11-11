// PubArenaFigure.swift — trajectories and occupancy heat maps as publication figures (RodentFlow 2.0: iOS build 15,
// Mac build 14): one animal, all animals of a task in one multi-panel figure (one row per group), and the mean
// occupancy of each group. Heat maps of a figure share one color scale (the largest cell of all panels) with a
// color bar in seconds, so animals can be compared directly. Colors follow the app's heat ramp, square-root
// scaled as on screen. Foundation only.
// Build 23: group means average each animal's sessions first (n = animals); every mark color is the one on screen
// (ReportPalette), with a legend row for the colored marks; head-direction arrows are drawn.

import Foundation

enum PubArenaColors {
    private static let stops: [(Double, Double, Double)] = [(0.12, 0.10, 0.36), (0.16, 0.38, 0.62), (0.13, 0.62, 0.60), (0.48, 0.80, 0.38), (0.99, 0.88, 0.22)]

    static func heat(_ t: Double) -> PubColor {
        let x = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let f = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return PubColor(r: a.0 + (b.0 - a.0) * f, g: a.1 + (b.1 - a.1) * f, b: a.2 + (b.2 - a.2) * f)
    }

    static func zone(_ role: ZoneRole) -> PubColor {
        switch role {
        case .center, .arm: return PubColor(r: 0.365, g: 0.396, b: 0.945)
        case .periphery, .corner, .shelter: return PubColor(r: 0.137, g: 0.639, b: 0.690)
        case .social, .interaction: return PubColor(r: 0.949, g: 0.420, b: 0.380)
        case .novel, .choice, .cue: return PubColor(r: 0.961, g: 0.620, b: 0.106)
        case .familiar: return PubColor(r: 0.0, g: 0.447, b: 0.698)
        case .open: return PubColor(r: 0.95, g: 0.70, b: 0.10)
        case .light: return PubColor(r: 0.98, g: 0.78, b: 0.18)
        case .dark: return PubColor(r: 0.30, g: 0.32, b: 0.42)
        case .target, .quadrant: return PubColor(r: 0.0, g: 0.620, b: 0.451)
        default: return PubColor.gray(0.56)
        }
    }

    /// The on-screen color of a mark (ReportPalette.color), as RGB. `.accent` (the trajectory; the app tint on screen) is
    /// printed as Okabe–Ito blue, a colour-blind-safe blue close to the tint, so exported figures do not depend on the
    /// device's accent colour.
    static func mark(_ key: ColorKey) -> PubColor {
        let okabeBlue = PubColor(r: 0.0, g: 0.447, b: 0.698), okabeGreen = PubColor(r: 0.0, g: 0.620, b: 0.451)
        let okabeVermillion = PubColor(r: 0.835, g: 0.369, b: 0.0), okabePurple = PubColor(r: 0.800, g: 0.475, b: 0.655)
        let amber = PubColor(r: 0.961, g: 0.620, b: 0.106), coral = PubColor(r: 0.949, g: 0.420, b: 0.380)
        let indigo = PubColor(r: 0.365, g: 0.396, b: 0.945), teal = PubColor(r: 0.137, g: 0.639, b: 0.690)
        let gray = PubColor(r: 0.557, g: 0.557, b: 0.576), red = PubColor(r: 0.92, g: 0.26, b: 0.24), pink = PubColor(r: 0.91, g: 0.30, b: 0.56)
        switch key {
        case .accent: return okabeBlue
        case .neutral, .object, .closed: return gray
        case .warning, .novel: return amber
        case .social: return coral
        case .familiar, .ccw: return okabeBlue
        case .center, .freezing: return indigo
        case .periphery, .shelter: return teal
        case .open: return PubColor(r: 0.95, g: 0.70, b: 0.10)
        case .light: return PubColor(r: 0.98, g: 0.78, b: 0.18)
        case .dark: return PubColor(r: 0.30, g: 0.32, b: 0.42)
        case .sniff, .poke: return pink
        case .headDip, .error: return red
        case .sap: return PubColor(r: 0.616, g: 0.388, b: 0.898)
        case .target, .escape: return okabeGreen
        case .cw: return okabeVermillion
        case .animalA: return PubColor(r: AnimalColors.blue.r, g: AnimalColors.blue.g, b: AnimalColors.blue.b)
        case .animalB: return PubColor(r: AnimalColors.red.r, g: AnimalColors.red.g, b: AnimalColors.red.b)
        case .animalC, .animalD, .animalE, .animalF, .animalG, .animalH, .animalI, .animalJ:
            let all: [ColorKey] = [.animalA, .animalB, .animalC, .animalD, .animalE, .animalF, .animalG, .animalH, .animalI, .animalJ]
            let c = AnimalColors.rgb(all.firstIndex(of: key) ?? 0)
            return PubColor(r: c.r, g: c.g, b: c.b)
        case .nose: return PubColor(r: 1.0, g: 0.231, b: 0.188)
        case .body: return PubColor(r: 0.196, g: 0.678, b: 0.902)
        case .tail: return PubColor(r: 0.686, g: 0.322, b: 0.871)
        case .series1: return okabeBlue
        case .series2: return okabeGreen
        case .series3: return okabeVermillion
        case .series4: return okabePurple
        case .attack: return PubColor(r: 0.84, g: 0.18, b: 0.13)
        case .clinch: return PubColor(r: 0.42, g: 0.05, b: 0.04)
        case .chase: return PubColor(r: 0.90, g: 0.62, b: 0.00)
        case .keepDown: return PubColor(r: 0.56, g: 0.27, b: 0.68)
        case .threat: return PubColor(r: 0.94, g: 0.84, b: 0.26)
        case .upright: return PubColor(r: 0.55, g: 0.38, b: 0.12)
        case .mount: return PubColor(r: 0.00, g: 0.45, b: 0.70)
        case .investigate: return PubColor(r: 0.34, g: 0.71, b: 0.91)
        case .follow: return PubColor(r: 0.00, g: 0.62, b: 0.45)
        default: return okabeBlue
        }
    }

    /// English name of what a mark color stands for (legend row of the exported figures).
    static func markName(_ key: ColorKey) -> String {
        switch key {
        case .accent: return "event"
        case .neutral: return "other"
        case .warning: return "to check"
        case .social: return "social"
        case .object: return "object"
        case .novel: return "novel"
        case .familiar: return "familiar"
        case .center: return "centre"
        case .periphery: return "periphery"
        case .open: return "open"
        case .closed: return "closed"
        case .light: return "light side"
        case .dark: return "dark side"
        case .freezing: return "freezing"
        case .sniff: return "sniffing"
        case .headDip: return "head dip"
        case .sap: return "stretched-attend posture"
        case .poke: return "nose poke"
        case .target: return "target"
        case .error: return "error"
        case .shelter: return "shelter"
        case .escape: return "escape"
        case .cw: return "clockwise"
        case .ccw: return "counter-clockwise"
        case .animalA: return "animal A"
        case .animalB: return "animal B"
        case .animalC, .animalD, .animalE, .animalF, .animalG, .animalH, .animalI, .animalJ:
            let all: [ColorKey] = [.animalA, .animalB, .animalC, .animalD, .animalE, .animalF, .animalG, .animalH, .animalI, .animalJ]
            return "animal \((all.firstIndex(of: key) ?? 0) + 1)"
        case .nose: return "nose"
        case .body: return "body"
        case .tail: return "tail"
        case .series1: return "series 1"
        case .series2: return "series 2"
        case .series3: return "series 3"
        case .series4: return "series 4"
        case .attack: return "attack"
        case .clinch: return "clinch"
        case .chase: return "chase"
        case .keepDown: return "keep down"
        case .threat: return "threat"
        case .upright: return "upright"
        case .mount: return "mount"
        case .investigate: return "investigation"
        case .follow: return "following"
        default: return key.rawValue
        }
    }
}

struct ArenaPanel {
    var group: String
    var label: String
    var plot: ArenaPlotData
    /// Animal identity (sessions of one animal are averaged first in the group means); "" = a separate animal.
    var subject: String = ""
}

enum PubArenaFigure {
    /// Largest cell (seconds) over the heat maps of `plots`.
    static func maxHeat(_ plots: [ArenaPlotData]) -> Double {
        plots.compactMap { $0.heat?.values.filter { $0.isFinite }.max() }.max() ?? 0
    }

    /// Mean occupancy (seconds per cell) of several heat maps. Grids with another size are resampled by position in
    /// the arena (nearest cell); a cell outside the arena in every map stays blank.
    static func average(_ plots: [ArenaPlotData]) -> ArenaPlotData? {
        guard let base = plots.first(where: { $0.heat != nil }), let g0 = base.heat else { return nil }
        var sum = [Double](repeating: 0, count: g0.values.count)
        var count = [Int](repeating: 0, count: g0.values.count)
        for p in plots {
            guard let g = p.heat else { continue }
            let same = g.columns == g0.columns && g.rows == g0.rows
            for r in 0..<g0.rows {
                for c in 0..<g0.columns {
                    let v: Double
                    if same {
                        v = g.values[r * g.columns + c]
                    } else {
                        let fx = (Double(c) + 0.5) / Double(g0.columns), fy = (Double(r) + 0.5) / Double(g0.rows)
                        let cc = min(g.columns - 1, max(0, Int(fx * Double(g.columns)))), rr = min(g.rows - 1, max(0, Int(fy * Double(g.rows))))
                        v = g.values[rr * g.columns + cc]
                    }
                    guard v.isFinite else { continue }
                    sum[r * g0.columns + c] += v
                    count[r * g0.columns + c] += 1
                }
            }
        }
        var out = base
        out.heat = HeatGrid(columns: g0.columns, rows: g0.rows, cell: g0.cell,
                            values: zip(sum, count).map { $1 > 0 ? $0 / Double($1) : .nan })
        out.paths = []
        out.dots = []
        out.arrows = []
        return out
    }

    /// Draws one arena plot into `rect` (points) of `fig`. Heat maps use `vmax` (shared) or their own maximum.
    static func draw(_ plot: ArenaPlotData, into fig: inout PubFigure, x: Double, y: Double, w: Double, h: Double,
                     style: FigureStyle, vmax: Double?, lineScale: Double = 1) {
        let e = plot.extent
        guard e.x > 0, e.y > 0, w > 0, h > 0 else { return }
        let s = min(w / e.x, h / e.y)
        let ox = x + (w - e.x * s) / 2, oy = y + (h - e.y * s) / 2
        func p(_ v: V2) -> PubPoint { PubPoint(ox + v.x * s, oy + v.y * s) }
        func poly(_ pts: [V2]) -> PubPath { PubPath.polyline(pts.map(p), closed: true) }
        let lw = 0.5 * lineScale
        if let arena = plot.arena, arena.role == .arena, style.shows(.arenaOutline) {
            fig.shape(poly(arena.outline(segments: 96)), fill: PubColor.gray(0.95), stroke: PubColor.gray(0.55), width: lw)
        }
        if let heat = plot.heat {
            let top = vmax ?? (heat.values.filter { $0.isFinite }.max() ?? 0)
            if top > 0 {
                let cw = heat.cell * s
                // Cells of one color step drawn as one path (small vector files).
                var steps = [PubPath](repeating: PubPath(), count: 33)
                for r in 0..<heat.rows {
                    for c in 0..<heat.columns {
                        let v = heat.values[r * heat.columns + c]
                        guard v.isFinite else { continue }
                        let k = Int((min(1, max(0, v / top)).squareRoot() * 32).rounded())
                        let rect = PubPath.rect(ox + Double(c) * cw, oy + Double(r) * cw, cw + 0.15, cw + 0.15)
                        steps[k].ops += rect.ops
                    }
                }
                for k in steps.indices where !steps[k].ops.isEmpty { fig.fill(steps[k], PubArenaColors.heat(Double(k) / 32)) }
            }
        }
        for z in plot.zones where z.role != .arena && style.shows(z) {
            let color = PubArenaColors.zone(z.role)
            let fill: PubColor? = plot.heat == nil && !z.outlineOnly && z.role != .hole ? color.opacity(0.12) : nil
            let stroke = plot.heat == nil ? color.opacity(0.85) : PubColor.white.opacity(0.85)
            fig.items.append(.shape(poly(z.outline(segments: 64)), fill: fill,
                                    stroke: PubStroke(color: stroke, width: lw, dash: z.outlineOnly ? [1.5, 1.5] : [])))
        }
        if style.shows(.trajectory) {
            for path in plot.paths {
                var pp = PubPath()
                for seg in path.segments where seg.count > 1 { pp.ops += PubPath.polyline(seg.map(p)).ops }
                if !pp.ops.isEmpty { fig.stroke(pp, PubArenaColors.mark(path.color).opacity(path.opacity), 0.35 * lineScale) }
            }
        }
        if style.shows(.dots) {
            for d in plot.dots.prefix(1500) {
                let q = p(d.p)
                fig.fill(PubPath.circle(q.x, q.y, max(0.5, d.radius * 0.35 * lineScale)), PubArenaColors.mark(d.color).opacity(0.85))
            }
        }
        if style.shows(.arrows) {
            for a in plot.arrows {
                let p0 = p(a.from), p1 = p(a.to)
                let angle = atan2(p1.y - p0.y, p1.x - p0.x)
                let head = 1.8 * lineScale
                var path = PubPath.segment(p0.x, p0.y, p1.x, p1.y)
                path.move(p1.x, p1.y); path.line(p1.x - head * cos(angle - 0.5), p1.y - head * sin(angle - 0.5))
                path.move(p1.x, p1.y); path.line(p1.x - head * cos(angle + 0.5), p1.y - head * sin(angle + 0.5))
                fig.stroke(path, PubArenaColors.mark(a.color).opacity(0.75), 0.45 * lineScale)
            }
        }
    }

    /// Colors that carry a meaning in `plots` (event dots, the paths of two animals, arrows), in order of appearance.
    static func legendEntries(_ plots: [ArenaPlotData], style: FigureStyle) -> [(key: ColorKey, arrow: Bool)] {
        var out: [(key: ColorKey, arrow: Bool)] = []
        func add(_ k: ColorKey, arrow: Bool) { if !out.contains(where: { $0.key == k && $0.arrow == arrow }) { out.append((key: k, arrow: arrow)) } }
        for plot in plots {
            if style.shows(.trajectory) && Set(plot.paths.map(\.color)).count > 1 { for path in plot.paths { add(path.color, arrow: false) } }
            if style.shows(.dots) { for d in plot.dots { add(d.color, arrow: false) } }
            if style.shows(.arrows) { for a in plot.arrows { add(a.color, arrow: true) } }
        }
        return out
    }

    private static func legendText(_ e: (key: ColorKey, arrow: Bool)) -> String { e.arrow ? "heading" : PubArenaColors.markName(e.key) }

    /// Height of the legend row(s) of `entries` within `maxWidth`.
    static func legendHeight(_ entries: [(key: ColorKey, arrow: Bool)], maxWidth: Double, font f: Double) -> Double {
        guard !entries.isEmpty else { return 0 }
        var x = 0.0, rows = 1.0
        for e in entries {
            let w = f * 1.4 + PubTextMetrics.width(legendText(e), size: f) + f * 0.9
            if x + w > maxWidth && x > 0 { x = 0; rows += 1 }
            x += w
        }
        return rows * f * 1.3
    }

    /// One legend row (wrapped) of colored marks: a dot or an arrow, then its name.
    static func drawLegend(_ entries: [(key: ColorKey, arrow: Bool)], into fig: inout PubFigure, x: Double, y: Double, maxWidth: Double, font f: Double) {
        var cx = x, cy = y + f * 0.65
        for e in entries {
            let text = legendText(e)
            let w = f * 1.4 + PubTextMetrics.width(text, size: f) + f * 0.9
            if cx + w > x + maxWidth && cx > x { cx = x; cy += f * 1.3 }
            let color = PubArenaColors.mark(e.key)
            if e.arrow {
                var path = PubPath.segment(cx, cy, cx + f * 1.0, cy)
                path.move(cx + f * 1.0, cy); path.line(cx + f * 0.7, cy - f * 0.22)
                path.move(cx + f * 1.0, cy); path.line(cx + f * 0.7, cy + f * 0.22)
                fig.stroke(path, color, 0.6)
            } else {
                fig.fill(PubPath.circle(cx + f * 0.45, cy, f * 0.3), color)
            }
            fig.text(PubText(text: text, at: PubPoint(cx + f * 1.4, cy), size: f, anchor: .start, baseline: .middle))
            cx += w
        }
    }

    /// Vertical color bar (seconds, square-root scale as drawn).
    static func colorBar(into fig: inout PubFigure, x: Double, y: Double, height: Double, vmax: Double, font f: Double, english: Bool) {
        let w = f * 0.8
        let n = 32
        for k in 0..<n {
            let y0 = y + height * (1 - Double(k + 1) / Double(n))
            fig.fill(PubPath.rect(x, y0, w, height / Double(n) + 0.1), PubArenaColors.heat((Double(k) + 0.5) / Double(n)))
        }
        fig.stroke(PubPath.rect(x, y, w, height), .ink, 0.4)
        let ticks = GroupGeometry.ticks(0, vmax, target: 4).filter { $0 >= 0 && $0 <= vmax * 1.0001 }
        for t in ticks {
            let yy = y + height * (1 - (t / vmax).squareRoot())
            fig.stroke(PubPath.segment(x + w, yy, x + w + f * 0.3, yy), .ink, 0.4)
            let txt = t < 10 && abs(t - t.rounded()) > 1e-6 ? String(format: "%.1f", t) : String(format: "%.0f", t)
            fig.text(PubText(text: txt, at: PubPoint(x + w + f * 0.45, yy), size: f, anchor: .start, baseline: .middle))
        }
        fig.text(PubText(text: english || !Lang.isChinese ? "Time (s, √ scale)" : "停留时间（s，平方根标度）",
                         at: PubPoint(x + w + f * 3.4, y + height / 2), size: f, anchor: .middle, baseline: .hanging, rotation: 90))
    }

    /// Width taken by a color bar with its labels.
    static func colorBarWidth(font f: Double) -> Double { f * 5.2 }

    /// One plot with an optional title, scale bar and (heat maps) color bar.
    static func single(_ plot: ArenaPlotData, title: String?, style: FigureStyle, settings: FigureExportSettings,
                       vmax: Double?, english: Bool) -> PubFigure {
        let f = settings.font
        let width = settings.widthPt
        let hasHeat = plot.heat != nil
        let barW = hasHeat ? colorBarWidth(font: f) : 0
        let titleH = (title?.isEmpty == false) ? f * 1.6 : 0
        let plotW = width - barW - f
        let aspect = plot.extent.y / max(plot.extent.x, 1e-9)
        let legend = style.shows(.legend) ? legendEntries([plot], style: style) : []
        let legendH = legendHeight(legend, maxWidth: width - f, font: f)
        var fig = PubFigure(width: width, height: settings.heightMM > 0 ? settings.heightPt(aspect: 1) : titleH + plotW * aspect + f * 2.2 + legendH)
        if let title, !title.isEmpty {
            fig.text(PubText(text: title, at: PubPoint(f * 0.5, f * 0.4), size: f, bold: true, anchor: .start, baseline: .hanging))
        }
        let ph = fig.height - titleH - f * 2.2 - legendH
        draw(plot, into: &fig, x: f * 0.5, y: titleH, w: plotW, h: ph, style: style, vmax: vmax)
        if !legend.isEmpty { drawLegend(legend, into: &fig, x: f * 0.5, y: titleH + ph + f * 0.2, maxWidth: width - f, font: f) }
        if style.shows(.scaleBar), plot.unit == "cm" {
            let s = min(plotW / plot.extent.x, ph / plot.extent.y)
            let len = plot.extent.x > 60 ? 20.0 : 10.0
            let y = fig.height - f * 1.2
            fig.stroke(PubPath.segment(f * 0.5, y, f * 0.5 + len * s, y), .ink, 0.8)
            fig.text(PubText(text: String(format: "%.0f cm", len), at: PubPoint(f * 0.5 + len * s + f * 0.4, y), size: f, anchor: .start, baseline: .middle))
        }
        if hasHeat {
            let top = vmax ?? (plot.heat?.values.filter { $0.isFinite }.max() ?? 0)
            if top > 0 { colorBar(into: &fig, x: width - barW, y: titleH + ph * 0.1, height: ph * 0.8, vmax: top, font: f, english: english) }
        }
        return fig
    }

    /// All panels of a task: one row per group (group name on the left), panels wrapped to `columns`, a shared color
    /// scale for heat maps with one color bar.
    static func grid(_ panels: [ArenaPanel], groups: [String], style: FigureStyle, settings: FigureExportSettings,
                     english: Bool, columns: Int = 6) -> PubFigure {
        let f = settings.font
        let width = settings.widthPt
        let hasHeat = panels.contains { $0.plot.heat != nil }
        let vmax = hasHeat ? maxHeat(panels.map(\.plot)) : 0
        let barW = hasHeat ? colorBarWidth(font: f) : 0
        let groupNames = groups.filter { g in panels.contains { $0.group == g } }
        let labelW = (groupNames.map { PubTextMetrics.width(english ? $0 : groupDisplayName($0), size: f, bold: true) }.max() ?? 0) + f
        let cols = max(1, min(columns, panels.isEmpty ? 1 : groupNames.map { g in panels.filter { $0.group == g }.count }.max() ?? 1))
        let cellW = (width - labelW - barW - f * 0.5) / Double(cols)
        let aspect = panels.first.map { $0.plot.extent.y / max($0.plot.extent.x, 1e-9) } ?? 1
        let cellH = cellW * 0.9 * aspect + f * 1.4
        var rows: [(group: String, items: [ArenaPanel])] = []
        for g in groupNames {
            let items = panels.filter { $0.group == g }
            var i = 0
            while i < items.count {
                rows.append((group: g, items: Array(items[i..<min(items.count, i + cols)])))
                i += cols
            }
        }
        let legend = style.shows(.legend) ? legendEntries(panels.map(\.plot), style: style) : []
        let legendH = legendHeight(legend, maxWidth: width - f, font: f)
        let gridH = max(cellH, Double(rows.count) * cellH) + f * 0.6
        var fig = PubFigure(width: width, height: gridH + legendH)
        if !legend.isEmpty { drawLegend(legend, into: &fig, x: f * 0.5, y: gridH - f * 0.2, maxWidth: width - f, font: f) }
        var lastGroup = ""
        for (ri, row) in rows.enumerated() {
            let y = f * 0.3 + Double(ri) * cellH
            if row.group != lastGroup {
                fig.text(PubText(text: english ? row.group : groupDisplayName(row.group), at: PubPoint(f * 0.3, y + cellH / 2), size: f, bold: true,
                                 anchor: .start, baseline: .middle))
                lastGroup = row.group
            }
            for (ci, panel) in row.items.enumerated() {
                let x = labelW + Double(ci) * cellW
                draw(panel.plot, into: &fig, x: x + cellW * 0.05, y: y, w: cellW * 0.9, h: cellH - f * 1.4, style: style,
                     vmax: hasHeat ? vmax : nil, lineScale: 0.7)
                fig.text(PubText(text: panel.label, at: PubPoint(x + cellW / 2, y + cellH - f * 1.25), size: f, anchor: .middle, baseline: .hanging))
            }
        }
        if hasHeat && vmax > 0 {
            colorBar(into: &fig, x: width - barW, y: f * 0.5, height: min(gridH - f, cellH * 2), vmax: vmax, font: f, english: english)
        }
        return fig
    }

    /// One mean heat map per group with one color scale. The sessions of an animal are averaged first, then the
    /// animals, so n = animals (as in the group statistics).
    static func groupAverages(_ panels: [ArenaPanel], groups: [String], style: FigureStyle, settings: FigureExportSettings,
                              english: Bool) -> (figure: PubFigure, averages: [(group: String, n: Int, plot: ArenaPlotData)])? {
        var averages: [(group: String, n: Int, plot: ArenaPlotData)] = []
        for g in groups {
            var order: [String] = []
            var byAnimal: [String: [ArenaPlotData]] = [:]
            for (i, panel) in panels.enumerated() where panel.group == g && panel.plot.heat != nil {
                let key = panel.subject.isEmpty ? "#\(i)" : panel.subject
                if byAnimal[key] == nil { order.append(key) }
                byAnimal[key, default: []].append(panel.plot)
            }
            let animalMeans = order.compactMap { key -> ArenaPlotData? in
                guard let plots = byAnimal[key] else { return nil }
                return average(plots)
            }
            if let avg = average(animalMeans) { averages.append((group: g, n: animalMeans.count, plot: avg)) }
        }
        guard !averages.isEmpty else { return nil }
        let items = averages.map { a in
            ArenaPanel(group: a.group, label: (english ? a.group : groupDisplayName(a.group))
                       + (english || !Lang.isChinese ? " (n = \(a.n) animal\(a.n == 1 ? "" : "s"))" : "（n = \(a.n) 只）"), plot: a.plot)
        }
        // One row: every group mean side by side.
        let f = settings.font
        let width = settings.widthPt
        let vmax = maxHeat(items.map(\.plot))
        let barW = colorBarWidth(font: f)
        let cellW = (width - barW - f * 0.5) / Double(items.count)
        let aspect = items[0].plot.extent.y / max(items[0].plot.extent.x, 1e-9)
        let cellH = cellW * 0.9 * aspect + f * 1.6
        var fig = PubFigure(width: width, height: cellH + f * 0.6)
        for (i, item) in items.enumerated() {
            let x = f * 0.3 + Double(i) * cellW
            draw(item.plot, into: &fig, x: x + cellW * 0.05, y: f * 0.3, w: cellW * 0.9, h: cellH - f * 1.6, style: style, vmax: vmax)
            fig.text(PubText(text: item.label, at: PubPoint(x + cellW / 2, cellH - f * 1.1), size: f, anchor: .middle, baseline: .hanging))
        }
        if vmax > 0 { colorBar(into: &fig, x: width - barW, y: f * 0.5, height: cellH - f * 2, vmax: vmax, font: f, english: english) }
        return (fig, averages)
    }

    /// Mean occupancy per cell as a table (group, animals = n of the mean, row, column, seconds), for the source data
    /// of the group means.
    static func heatCSV(_ averages: [(group: String, n: Int, plot: ArenaPlotData)]) -> String {
        var lines = ["group,animals,row,column,cell_cm,x_center_cm,y_center_cm,mean_seconds"]
        for a in averages {
            guard let g = a.plot.heat else { continue }
            for r in 0..<g.rows {
                for c in 0..<g.columns {
                    let v = g.values[r * g.columns + c]
                    guard v.isFinite else { continue }
                    lines.append("\(a.group.contains(",") ? "\"\(a.group)\"" : a.group),\(a.n),\(r),\(c),\(String(format: "%.3g", g.cell)),"
                                 + String(format: "%.4g,%.4g,%.6g", (Double(c) + 0.5) * g.cell, (Double(r) + 0.5) * g.cell, v))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
