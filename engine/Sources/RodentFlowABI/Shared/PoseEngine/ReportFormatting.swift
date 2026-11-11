// ReportFormatting.swift — interface-independent helpers for presenting a report: the natural
// scale of a headline measure and the plain-text data behind a figure. Foundation only, so the
// logic is unit-testable outside the app.

import Foundation

/// Bounded measures that have a natural scale.
struct MetricScale {
    let range: ClosedRange<Double>
    let reference: Double?
    let referenceLabel: String?

    /// The reference point comes from the measure itself (MetricValue.reference, set by its analyzer), so a key
    /// shared by two tasks (Y-maze and T-maze alternation) gets the reference of its own task.
    init?(_ m: MetricValue) {
        guard let v = m.value, v.isFinite, m.valueText == nil else { return nil }
        let isIndex = m.key.hasSuffix("_index") || m.key == "di" || m.key == "turn_bias"
        if isIndex, (-1.0...1.0).contains(v) {
            range = -1...1
            reference = m.reference ?? 0
            referenceLabel = m.referenceLabel ?? L10n.tr("0 = 无偏好")
        } else if m.unit == "%", (0.0...100.0).contains(v) {
            range = 0...100
            reference = m.reference
            referenceLabel = m.reference == nil ? nil : m.referenceLabel
        } else if let ref = m.reference, ref > 0, m.unit.isEmpty, v >= 0 {
            // Ratios (SI ratio: 1 = the same time in both phases): 0 to twice the reference, or up to the value.
            range = 0...max(2 * ref, (v * 1.1).rounded(.up))
            reference = ref
            referenceLabel = m.referenceLabel
        } else {
            return nil
        }
    }

    /// Tick label of the scale: percent, signed index or plain number.
    func label(_ x: Double) -> String {
        if range.lowerBound == 0 && range.upperBound == 100 { return String(format: "%.0f%%", x) }
        if range.lowerBound < 0 { return x > 0 ? String(format: "+%.0f", x) : String(format: "%.0f", x) }
        return AnalysisContext.num(x)
    }
}

// MARK: - Time-course labels

/// Axis labels of time courses (series contract: x = bin centre in minutes, the label names the unit and the
/// bin width), as stored with a session in English and shown in the interface language.
enum TimeCourseLabel {
    /// "1-min" / "30-s".
    static func widthEnglish(_ bin: Double) -> String {
        bin >= 60 && abs(bin.truncatingRemainder(dividingBy: 60)) < 0.01 ? "\(AnalysisContext.num(bin / 60))-min" : "\(AnalysisContext.num(bin))-s"
    }

    /// Stored series label, e.g. "Time (min), 1-min bins" (English; seconds = x in seconds).
    static func english(bin: Double, seconds: Bool = false) -> String {
        (seconds ? "Time (s), " : "Time (min), ") + widthEnglish(bin) + " bins"
    }

    /// The same label in the interface language.
    static func interface(bin: Double, seconds: Bool = false) -> String {
        let whole = bin >= 60 && abs(bin.truncatingRemainder(dividingBy: 60)) < 0.01
        let width = whole ? AnalysisContext.num(bin / 60) : AnalysisContext.num(bin)
        if seconds { return L10n.tr("时间（秒），每段 \(width) 秒") }
        return whole ? L10n.tr("时间（分钟），每段 \(width) 分钟") : L10n.tr("时间（分钟），每段 \(width) 秒")
    }

    /// Interface text of a stored English label made by `english` (other labels, e.g. "Minute" of RodentFlow 2.1 build
    /// 22 and earlier or classic sessions, are returned unchanged).
    static func display(_ stored: String) -> String {
        guard L10n.isChinese else { return stored }
        let parts = stored.components(separatedBy: ", ")
        guard parts.count == 2, parts[1].hasSuffix(" bins"),
              let seconds = ["Time (min)": false, "Time (s)": true][parts[0]] else { return stored }
        let width = String(parts[1].dropLast(" bins".count))
        if width.hasSuffix("-min"), let v = Double(width.dropLast(4)) { return interface(bin: v * 60, seconds: seconds) }
        if width.hasSuffix("-s"), let v = Double(width.dropLast(2)) { return interface(bin: v, seconds: seconds) }
        return stored
    }
}

// MARK: - English copy of a report (figures written to files)

/// A report's display texts in English (titles, captions, labels, legends), for figures saved as files: a figure
/// exported from a Chinese interface reads like the rest of the export. Numbers and colours are unchanged.
enum ReportEnglish {
    static func text(_ s: String) -> String {
        let e = L10n.english(s)
        guard L10n.hasHan(e) else { return e }
        let sentence = L10n.reportText(s)
        return L10n.hasHan(sentence) || sentence.hasPrefix("[An English translation") ? e : sentence
    }

    static func maybe(_ s: String?) -> String? { s.map { text($0) } }

    static func metric(_ m: MetricValue) -> MetricValue {
        var out = m
        out.title = L10n.metricLabel(m.title, key: m.key)
        out.unit = text(m.unit)
        out.info = maybe(m.info)
        out.censored = maybe(m.censored)
        out.valueText = maybe(m.valueText)
        out.referenceLabel = maybe(m.referenceLabel)
        return out
    }

    static func block(_ b: ReportBlock) -> ReportBlock {
        var out = b
        out.title = text(b.title)
        out.caption = maybe(b.caption)
        func epochs(_ e: [Epoch]) -> [Epoch] { e.map { (e0: Epoch) -> Epoch in var x = e0; x.name = text(e0.name); return x } }
        switch b.kind {
        case .arena(var d):
            d.zones = d.zones.map { (z0: Zone) -> Zone in var z = z0; z.title = text(z0.title); return z }
            d.unit = text(d.unit)
            out.kind = .arena(d)
        case .timeline(var d):
            d.tracks = d.tracks.map { (t0: TimelineTrack) -> TimelineTrack in var t = t0; t.name = text(t0.name); t.innerName = maybe(t0.innerName); return t }
            d.epochs = epochs(d.epochs)
            out.kind = .timeline(d)
        case .bars(var d):
            d.items = d.items.map { (i0: BarItem) -> BarItem in var i = i0; i.label = text(i0.label); i.group = maybe(i0.group); return i }
            d.unit = text(d.unit)
            d.referenceLabel = maybe(d.referenceLabel)
            out.kind = .bars(d)
        case .line(var d):
            d.series = d.series.map { (s0: LineSeries) -> LineSeries in var s = s0; s.name = text(s0.name); return s }
            d.xLabel = text(d.xLabel)
            d.yLabel = text(d.yLabel)
            d.epochs = epochs(d.epochs)
            d.referenceYLabel = maybe(d.referenceYLabel)
            d.referenceXLabel = maybe(d.referenceXLabel)
            out.kind = .line(d)
        case .polar(var d):
            d.unit = text(d.unit)
            out.kind = .polar(d)
        case .table(var d):
            d.columns = d.columns.map { (c: String) -> String in text(c) }
            d.rows = d.rows.map { (row: [String]) -> [String] in row.map { (c: String) -> String in text(c) } }
            out.kind = .table(d)
        }
        return out
    }
}

// MARK: - CSV for a block

/// Plain-text data behind a figure. Labels go through `L10n.english` so the copied table is in
/// English whatever the interface language.
enum BlockCSV {
    /// Cheap check used by menus: `make` returns a table for exactly these blocks.
    static func hasData(_ block: ReportBlock) -> Bool {
        switch block.kind {
        case .arena: return false
        case .bars(let d): return !d.items.isEmpty
        case .line(let d): return d.series.contains { !$0.points.isEmpty }
        case .timeline(let d): return d.tracks.contains { !$0.bouts.isEmpty }
        case .polar(let d): return !d.values.isEmpty
        case .table(let d): return !d.rows.isEmpty
        }
    }

    static func make(_ block: ReportBlock) -> String? {
        func esc(_ s: String) -> String {
            let e = L10n.english(s)
            return e.contains(",") || e.contains("\"") ? "\"" + e.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : e
        }
        func num(_ v: Double) -> String { v.isFinite ? String(format: "%.4g", v) : "" }
        var lines: [String] = []
        switch block.kind {
        case .arena:
            return nil
        case .bars(let d):
            let grouped = d.items.contains { $0.group != nil }
            lines.append(grouped ? "group,category,value" : "category,value")
            for i in d.items {
                lines.append((grouped ? esc(i.group ?? "") + "," : "") + esc(i.label) + "," + num(i.value))
            }
        case .line(let d):
            lines.append("series," + esc(d.xLabel) + "," + esc(d.yLabel))
            for s in d.series {
                for p in s.points { lines.append(esc(s.name) + "," + num(p.x) + "," + num(p.y)) }
            }
        case .timeline(let d):
            lines.append("behavior,start_s,end_s,duration_s")
            for t in d.tracks {
                for b in t.bouts { lines.append(esc(t.name) + "," + num(b.start) + "," + num(b.end) + "," + num(b.end - b.start)) }
            }
        case .polar(let d):
            let width = 360.0 / Double(max(1, d.values.count))
            lines.append("bin_start_deg,bin_end_deg,value_" + esc(d.unit))
            for (i, v) in d.values.enumerated() {
                lines.append(num(Double(i) * width) + "," + num(Double(i + 1) * width) + "," + num(v))
            }
        case .table(let d):
            lines.append(d.columns.map(esc).joined(separator: ","))
            for r in d.rows { lines.append(r.map(esc).joined(separator: ",")) }
        }
        return lines.count > 1 ? lines.joined(separator: "\n") + "\n" : nil
    }
}
