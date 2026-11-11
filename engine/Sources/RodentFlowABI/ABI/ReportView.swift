// ReportView.swift — the analysis report as a result page shows it, for the host app.
//
// rf_analyze returns this as "report" when the request sets includeReport. It is the AnalysisReport the
// analyzers built, the same value the Mac and the phone draw:
//
//   page order and cards   RodentStudio/Views/PoseResultFigures.swift   PoseReportView, RPKeyResultCard,
//                                                                       RPQualityCard, RPReportBlockView
//   the figures            Shared/PoseUI/ReportFigures.swift            ArenaPlotView, FrameFigureView,
//                                                                       TimelineChart, BarsChart, …
//
// The host only draws. Everything that is a rule or a piece of geometry comes from here:
//   • zones with their outlines (arena 96 segments, others 64, as both arena views sample them);
//   • the same outlines and each heat-map cell mapped onto the video frame (ArenaMapping.toImage,
//     FigureGeometry.cellCorners) and the crop of the frame (FigureGeometry.frameCrop);
//   • the scale of the headline measure (MetricScale), with its tick labels;
//   • the layers an arena figure offers (FigureLayersSheet.layers, copied below — it lives in PoseUI,
//     which is not part of this library) and its zone families (ZoneFamily.families);
//   • the CSV behind each figure (BlockCSV.make, always English) and the key a figure's layer choice
//     is remembered under (FigureStyleStore.key without its prefix);
//   • an English copy of every text for figures saved to files (ReportEnglish, L10n.reportText).
//
// rf_translate puts the result page's own interface texts ("全部指标", "起点", "%d 条提示" …) through
// L10n.tr, so the Windows page uses the Mac page's words in both languages.
//
// JSON note: corelibs-foundation's JSONSerialization takes Int, Double, Bool, String, arrays,
// dictionaries and NSNull only. Every Double goes through RFJSON.number (NaN → null), every count is
// an Int. Point lists are flat [x0, y0, x1, y1, …] arrays to keep the reply small.

import Foundation

enum ReportView {
    /// The report for the host's result page. `english`: every text in English, as the figures written to
    /// files are on the other platforms; otherwise the interface language set with rf_set_language.
    static func json(_ r: AnalysisReport, session: Session, english: Bool, track: PoseTrack? = nil) -> [String: Any] {
        let scope = session.paradigm.rawValue
        let chinese = !english && Lang.isChinese
        let metrics: [MetricValue] = english ? r.metrics.map { ReportEnglish.metric($0) } : r.metrics
        let blocks: [ReportBlock] = english ? r.blocks.map { ReportEnglish.block($0) } : r.blocks
        let warnings: [String] = english ? r.warnings.map { L10n.reportText($0) } : r.warnings
        let methods: [String] = english ? r.methods.map { L10n.reportText($0) } : r.methods

        var out: [String: Any] = [:]
        out["language"] = chinese ? "zh" : "en"
        out["category"] = session.paradigm.category.rawValue
        out["primaryKey"] = r.primary?.key ?? r.primaryKey
        out["metrics"] = metrics.map { ReportView.metric($0) }
        out["warnings"] = warnings
        out["methods"] = methods
        // One sentence per entry: run together in Chinese, spaced in English (PoseReportView.methodsCard).
        out["methodsText"] = methods.joined(separator: chinese ? "" : " ")
        out["quality"] = ReportView.quality(r.quality, english: english)
        var blockList: [[String: Any]] = []
        for (i, b) in blocks.enumerated() { blockList.append(ReportView.block(b, index: i, scope: scope)) }
        out["blocks"] = blockList
        if let note = r.keyNote, !note.isEmpty { out["keyNote"] = english ? ReportEnglish.text(note) : note }
        if let dark = r.darkAnimal { out["darkAnimal"] = dark }

        // Titles of the figure layers and heat-map backdrops, for the layer dialog.
        var layerTitles: [String: String] = [:]
        for layer in FigureLayer.allCases { layerTitles[layer.rawValue] = layer.title }
        out["layerTitles"] = layerTitles
        var backdropTitles: [String: String] = [:]
        for b in HeatBackdrop.allCases { backdropTitles[b.rawValue] = b.title }
        out["backdropTitles"] = backdropTitles

        // What the review player shows under the video (for the frame-by-frame review, stage C).
        var review: [String: Any] = [:]
        review["tracks"] = r.reviewTracks.map { ReportView.track($0) }
        review["epochs"] = r.reviewEpochs.map { ReportView.epoch($0) }
        review["feedingCandidates"] = ReportView.bouts(r.feedingCandidates)
        if let track { review["qc"] = ReviewABI.qcEvents(track: track, report: r) }
        out["review"] = review
        return out
    }

    // MARK: Measures

    static func metric(_ m: MetricValue) -> [String: Any] {
        var d: [String: Any] = [:]
        d["key"] = m.key
        d["title"] = m.title
        d["unit"] = m.unit
        d["decimals"] = m.decimals
        d["highlight"] = m.highlight
        d["value"] = m.value.map { RFJSON.number($0) } ?? NSNull()
        // As the cards show it: "≥ 300.0" for a censored latency, the value text when there is one.
        d["display"] = m.displayValue
        d["displayUnit"] = m.displayUnit
        if let s = m.info { d["info"] = s }
        if let s = m.censored { d["censored"] = s }
        if let s = m.valueText { d["valueText"] = s }
        if let v = m.reference { d["reference"] = RFJSON.number(v) }
        if let s = m.referenceLabel { d["referenceLabel"] = s }
        if let scale = MetricScale(m) {
            var s: [String: Any] = [:]
            s["low"] = RFJSON.number(scale.range.lowerBound)
            s["high"] = RFJSON.number(scale.range.upperBound)
            s["lowLabel"] = scale.label(scale.range.lowerBound)
            s["highLabel"] = scale.label(scale.range.upperBound)
            if let ref = scale.reference { s["reference"] = RFJSON.number(ref) }
            if let label = scale.referenceLabel { s["referenceLabel"] = label }
            d["scale"] = s
        }
        return d
    }

    static func quality(_ q: QualityInfo, english: Bool) -> [String: Any] {
        var d: [String: Any] = [:]
        d["frames"] = q.frames
        d["framesInWindow"] = q.framesInWindow
        d["windowSeconds"] = RFJSON.number(q.windowSeconds)
        d["detectionRate"] = RFJSON.number(q.detectionRate)
        d["keypointRates"] = q.keypointRates.map { RFJSON.number($0) }
        d["headDirectionRate"] = RFJSON.number(q.headDirectionRate)
        d["sampleRate"] = RFJSON.number(q.sampleRate)
        d["pxPerUnit"] = RFJSON.number(q.pxPerUnit)
        d["unit"] = q.unit
        d["outsideArenaFraction"] = q.outsideArenaFraction.map { RFJSON.number($0) }
        // "A 0.4% · B 1.2%" (RPQualityCard.outsideText): the animals' letters as on the video.
        let animals = q.outsideArenaFraction.count
        var letters: [String] = []
        for i in 0..<animals { letters.append(AnimalColors.letter(i, animals: animals)) }
        d["animalLetters"] = letters
        var keypoints: [[String: Any]] = []
        for k in KP.allCases {
            keypoints.append(["title": english ? L10n.english(k.title) : k.title, "short": k.short])
        }
        d["keypoints"] = keypoints
        return d
    }

    // MARK: Blocks

    static func block(_ b: ReportBlock, index: Int, scope: String) -> [String: Any] {
        var d: [String: Any] = [:]
        d["index"] = index
        d["title"] = b.title
        // FigureStyleStore.key(scope:title:) without its prefix: task + English figure title, the same in
        // both interface languages, so a layer choice is remembered for every animal of the task.
        d["styleKey"] = scope + "." + L10n.english(b.title)
        if let caption = b.caption, !caption.isEmpty { d["caption"] = caption }
        if let csv = BlockCSV.make(b) { d["csv"] = csv }
        switch b.kind {
        case .arena(let a):
            d["kind"] = "arena"
            d["arena"] = ReportView.arena(a)
        case .timeline(let t):
            d["kind"] = "timeline"
            d["timeline"] = ReportView.timeline(t)
        case .bars(let x):
            d["kind"] = "bars"
            d["bars"] = ReportView.bars(x)
        case .line(let x):
            d["kind"] = "line"
            d["line"] = ReportView.line(x)
        case .polar(let x):
            d["kind"] = "polar"
            d["polar"] = ReportView.polar(x)
        case .table(let x):
            d["kind"] = "table"
            d["table"] = ReportView.table(x)
        }
        return d
    }

    // MARK: Arena figures

    static func arena(_ a: ArenaPlotData) -> [String: Any] {
        let mapping = a.mapping
        var d: [String: Any] = [:]
        d["extent"] = ReportView.pair(a.extent)
        d["unit"] = a.unit
        d["zones"] = a.zones.map { ReportView.zone($0, mapping: mapping) }
        if let z = a.arena { d["arena"] = ReportView.zone(z, mapping: mapping) }

        var paths: [[String: Any]] = []
        for p in a.paths {
            var pd: [String: Any] = [:]
            pd["color"] = p.color.rawValue
            pd["width"] = RFJSON.number(p.width)
            pd["opacity"] = RFJSON.number(p.opacity)
            pd["segments"] = p.segments.map { ReportView.flat($0) }
            paths.append(pd)
        }
        d["paths"] = paths

        var dots: [[String: Any]] = []
        for dot in a.dots {
            var dd: [String: Any] = [:]
            dd["x"] = RFJSON.number(dot.p.x)
            dd["y"] = RFJSON.number(dot.p.y)
            dd["color"] = dot.color.rawValue
            dd["radius"] = RFJSON.number(dot.radius)
            dots.append(dd)
        }
        d["dots"] = dots

        var arrows: [[String: Any]] = []
        for arrow in a.arrows {
            var ad: [String: Any] = [:]
            ad["from"] = ReportView.pair(arrow.from)
            ad["to"] = ReportView.pair(arrow.to)
            ad["color"] = arrow.color.rawValue
            arrows.append(ad)
        }
        d["arrows"] = arrows

        if let h = a.heat {
            var hd: [String: Any] = [:]
            hd["columns"] = h.columns
            hd["rows"] = h.rows
            hd["cell"] = RFJSON.number(h.cell)
            hd["values"] = h.values.map { RFJSON.number($0) }
            d["heat"] = hd
        }
        if let k = a.heatKeypoint { d["heatKeypoint"] = k.rawValue }

        d["layers"] = ReportView.layers(a).map { $0.rawValue }
        var families: [[String: Any]] = []
        for f in ZoneFamily.families(a.zones) { families.append(["key": f.key, "title": f.title]) }
        d["zoneFamilies"] = families

        if let m = mapping {
            var f: [String: Any] = [:]
            f["isMetric"] = m.isMetric
            f["frameWidth"] = RFJSON.number(m.frameSize.x)
            f["frameHeight"] = RFJSON.number(m.frameSize.y)
            if let c = FigureGeometry.frameCrop(a) {
                f["crop"] = ["x": RFJSON.number(c.x), "y": RFJSON.number(c.y),
                             "w": RFJSON.number(c.w), "h": RFJSON.number(c.h)]
            }
            // Heat-map cells mapped into the picture (FrameFigureView): 9 numbers per drawn cell —
            // its index in heat.values, then its four corners in upright-frame pixels.
            if m.isMetric, let h = a.heat {
                var cells: [Any] = []
                for row in 0..<h.rows {
                    for col in 0..<h.columns {
                        let i = row * h.columns + col
                        guard i < h.values.count else { continue }
                        let v = h.values[i]
                        guard v.isFinite, v > 0 else { continue }
                        cells.append(i)
                        for p in FigureGeometry.cellCorners(column: col, row: row, cell: h.cell, mapping: m) {
                            cells.append(RFJSON.number(p.x))
                            cells.append(RFJSON.number(p.y))
                        }
                    }
                }
                f["heatCells"] = cells
            }
            d["frame"] = f
        }
        return d
    }

    /// A zone in arena units, and — with a calibrated mapping — the same outline in upright-frame pixels.
    static func zone(_ z: Zone, mapping: ArenaMapping?) -> [String: Any] {
        let outline = z.outline(segments: z.role == .arena ? 96 : 64)
        var d: [String: Any] = [:]
        d["id"] = z.id
        d["title"] = z.title
        d["role"] = z.role.rawValue
        d["family"] = ZoneFamily.key(z.id)
        d["showsLabel"] = z.showsLabel
        d["outlineOnly"] = z.outlineOnly
        d["outline"] = ReportView.flat(outline)
        d["center"] = ReportView.pair(z.center)
        if let m = mapping, m.isMetric {
            d["image"] = ReportView.flat(outline.map { m.toImage($0) })
            d["imageCenter"] = ReportView.pair(m.toImage(z.center))
        }
        return d
    }

    /// The layers an arena figure offers. Copied from FigureLayersSheet.layers (Shared/PoseUI/
    /// ReportFigures.swift), which is UI code and not part of this library; keep the two in step.
    static func layers(_ data: ArenaPlotData) -> [FigureLayer] {
        var out: [FigureLayer] = []
        if data.arena != nil { out.append(.arenaOutline) }
        if data.zones.contains(where: { $0.role != .arena && $0.showsLabel && !$0.title.isEmpty }) { out.append(.zoneLabels) }
        if data.zones.contains(where: { $0.outlineOnly }) { out.append(.investigationRings) }
        let hasPath = data.paths.contains(where: { !$0.segments.isEmpty })
        if hasPath { out.append(contentsOf: [.trajectory, .startEnd]) }
        if !data.dots.isEmpty { out.append(.dots) }
        if !data.arrows.isEmpty { out.append(.arrows) }
        out.append(.scaleBar)
        if data.heat != nil || hasPath { out.append(.legend) }
        return out
    }

    // MARK: Charts

    static func timeline(_ t: TimelineData) -> [String: Any] {
        var d: [String: Any] = [:]
        d["start"] = RFJSON.number(t.start)
        d["end"] = RFJSON.number(t.end)
        d["tracks"] = t.tracks.map { ReportView.track($0) }
        d["epochs"] = t.epochs.map { ReportView.epoch($0) }
        return d
    }

    static func track(_ k: TimelineTrack) -> [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = k.name
        d["color"] = k.color.rawValue
        d["style"] = k.style == .flag ? "flag" : "behavior"
        d["bouts"] = ReportView.bouts(k.bouts)
        d["inner"] = ReportView.bouts(k.inner)
        d["innerColor"] = k.innerColor.rawValue
        if let name = k.innerName { d["innerName"] = name }
        return d
    }

    static func epoch(_ e: Epoch) -> [String: Any] {
        var d: [String: Any] = [:]
        d["name"] = e.name
        d["start"] = RFJSON.number(e.start)
        d["end"] = RFJSON.number(e.end)
        d["color"] = e.color.rawValue
        return d
    }

    static func bars(_ b: BarData) -> [String: Any] {
        var items: [[String: Any]] = []
        for i in b.items {
            var it: [String: Any] = [:]
            it["label"] = i.label
            it["value"] = RFJSON.number(i.value)
            it["color"] = i.color.rawValue
            if let g = i.group { it["group"] = g }
            items.append(it)
        }
        var d: [String: Any] = [:]
        d["items"] = items
        d["unit"] = b.unit
        d["decimals"] = b.decimals
        d["horizontal"] = b.horizontal
        if let ref = b.referenceLine { d["referenceLine"] = RFJSON.number(ref) }
        if let label = b.referenceLabel { d["referenceLabel"] = label }
        return d
    }

    static func line(_ l: LineData) -> [String: Any] {
        var series: [[String: Any]] = []
        for s in l.series {
            var points: [Any] = []
            points.reserveCapacity(s.points.count * 2)
            for p in s.points {
                points.append(RFJSON.number(p.x))
                points.append(RFJSON.number(p.y))
            }
            var sd: [String: Any] = [:]
            sd["name"] = s.name
            sd["color"] = s.color.rawValue
            sd["points"] = points
            sd["dashed"] = s.dashed
            series.append(sd)
        }
        var d: [String: Any] = [:]
        d["series"] = series
        d["xLabel"] = l.xLabel
        d["yLabel"] = l.yLabel
        if let range = l.yRange { d["yRange"] = [RFJSON.number(range.lowerBound), RFJSON.number(range.upperBound)] }
        if let y = l.referenceY { d["referenceY"] = RFJSON.number(y) }
        if let x = l.referenceX { d["referenceX"] = RFJSON.number(x) }
        if let s = l.referenceYLabel { d["referenceYLabel"] = s }
        if let s = l.referenceXLabel { d["referenceXLabel"] = s }
        d["epochs"] = l.epochs.map { ReportView.epoch($0) }
        return d
    }

    static func polar(_ p: PolarData) -> [String: Any] {
        var d: [String: Any] = [:]
        d["values"] = p.values.map { RFJSON.number($0) }
        d["unit"] = p.unit
        d["color"] = p.color.rawValue
        if let v = p.meanAngle { d["meanAngle"] = RFJSON.number(v) }
        if let v = p.resultantLength { d["resultantLength"] = RFJSON.number(v) }
        if let v = p.referenceAngle { d["referenceAngle"] = RFJSON.number(v) }
        return d
    }

    static func table(_ t: TableData) -> [String: Any] {
        var colors: [Any] = []
        for c in t.rowColors { colors.append(c.map { $0.rawValue as Any } ?? NSNull()) }
        var d: [String: Any] = [:]
        d["columns"] = t.columns
        d["rows"] = t.rows
        d["rowColors"] = colors
        return d
    }

    // MARK: Small helpers

    /// [x0, y0, x1, y1, …]; a non-finite coordinate becomes null.
    static func flat(_ points: [V2]) -> [Any] {
        var out: [Any] = []
        out.reserveCapacity(points.count * 2)
        for p in points {
            out.append(RFJSON.number(p.x))
            out.append(RFJSON.number(p.y))
        }
        return out
    }

    static func pair(_ p: V2) -> [Any] { [RFJSON.number(p.x), RFJSON.number(p.y)] }

    /// [start0, end0, start1, end1, …] in video seconds.
    static func bouts(_ list: [Bout]) -> [Any] {
        var out: [Any] = []
        out.reserveCapacity(list.count * 2)
        for b in list {
            out.append(RFJSON.number(b.start))
            out.append(RFJSON.number(b.end))
        }
        return out
    }

    // MARK: Interface texts

    struct TranslateRequest: Decodable {
        /// Chinese source texts, as the apps' L10n.tr receives them (format templates such as "%d 条提示" included).
        var texts: [String]
        /// English whatever the interface language (figures written to files).
        var english: Bool?
    }
}

/// Interface texts through the engine's catalogue: `{"texts": […], "english": false}` → `{"ok": true, "texts": […]}`,
/// one translation per text, in order. With `english` the texts come out in English, otherwise in the language
/// set with rf_set_language. A text the catalogue does not know comes back unchanged.
@_cdecl("rf_translate")
public func rf_translate(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(requestJSON) else {
        return rfMakeCString(RFJSON.failure("rf_translate: no request"))
    }
    do {
        let request = try RFCoding.decode(ReportView.TranslateRequest.self, from: text)
        let english = request.english ?? false
        let out: [String] = request.texts.map { english ? L10n.english($0) : L10n.tr($0) }
        return rfMakeCString(RFJSON.ok(["texts": out]))
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return rfMakeCString(RFJSON.failure(message))
    }
}
