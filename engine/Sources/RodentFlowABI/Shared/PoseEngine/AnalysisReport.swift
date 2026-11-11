// AnalysisReport.swift — what an analyzer returns: headline metrics plus typed visual blocks.
// The interface renders blocks generically, so a new paradigm only needs a new analyzer.

import Foundation

/// Semantic colors; the interface maps them to the palette (light / dark aware).
enum ColorKey: String {
    case accent, neutral, warning
    case social, object, novel, familiar
    case center, periphery, open, closed, light, dark
    case freezing, sniff, headDip, sap, poke
    case target, error, shelter, escape
    case cw, ccw, animalA, animalB, animalC, animalD, animalE, animalF, animalG, animalH, animalI, animalJ
    case nose, body, tail
    case series1, series2, series3, series4
    // Resident–intruder ethogram: warm = aggression, blue = mounting, cool = social investigation.
    case attack, clinch, chase, keepDown, threat, upright, mount, investigate, follow
}

struct MetricValue: Identifiable {
    let key: String
    var title: String
    let value: Double?
    var unit: String
    let decimals: Int
    var highlight = false
    var info: String?
    /// The stored value is a cut-off because the event did not occur (right-censored latency); short note shown with
    /// it, e.g. "no entry". Cards show "≥ 300.0 s (no entry)"; exports keep the number.
    var censored: String? = nil
    /// Text shown on cards instead of the number (e.g. "Deep" for a 0/100 first choice, "5 / 20"); exports keep the number.
    var valueText: String? = nil
    /// Reference value of the measure (chance / no preference), for the card's scale and one-sample tests.
    var reference: Double? = nil
    var referenceLabel: String? = nil

    var id: String { key }

    var formatted: String {
        guard let v = value, v.isFinite else { return "—" }
        return String(format: "%.\(decimals)f", v)
    }

    /// The value as cards show it: "≥ 300.0" for a censored latency, the value text when there is one.
    var displayValue: String {
        guard let v = value, v.isFinite else { return "—" }
        if let valueText { return valueText }
        return censored != nil ? "≥ " + formatted : formatted
    }

    /// Unit shown next to `displayValue` (none with a value text or without a value).
    var displayUnit: String { value?.isFinite == true && valueText == nil ? unit : "" }

    var formattedWithUnit: String {
        guard value != nil, value?.isFinite == true else { return "—" }
        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
    }

    func censoring(_ note: String, if condition: Bool) -> MetricValue {
        var m = self
        if condition { m.censored = note }
        return m
    }

    func showing(_ text: String?) -> MetricValue {
        var m = self
        m.valueText = text
        return m
    }

    func withReference(_ value: Double, _ label: String) -> MetricValue {
        var m = self
        m.reference = value
        m.referenceLabel = label
        return m
    }

    /// Column header for CSV exports, e.g. "Open arm time (%)".
    var exportHeader: String { unit.isEmpty ? title : "\(title) (\(unit))" }
}

// MARK: - Blocks

/// How a timeline row is drawn: a behaviour (solid bars) or a moment to check (hatched outline,
/// shown apart from the behaviours).
enum TrackStyle {
    case behavior, flag
}

struct TimelineTrack: Identifiable {
    let id = UUID()
    var name: String
    var color: ColorKey
    var bouts: [Bout]
    var style: TrackStyle = .behavior
    /// Sub-bouts drawn as a darker band inside the bars (e.g. clinch inside attacks).
    var inner: [Bout] = []
    var innerColor: ColorKey = .neutral
    var innerName: String? = nil
}

struct Epoch: Identifiable {
    let id = UUID()
    var name: String
    var start: Double
    var end: Double
    var color: ColorKey = .warning
}

struct TimelineData {
    var start: Double
    var end: Double
    var tracks: [TimelineTrack]
    var epochs: [Epoch] = []
}

struct BarItem: Identifiable {
    let id = UUID()
    var label: String
    var value: Double
    var color: ColorKey
    var group: String? = nil
}

struct BarData {
    var items: [BarItem]
    var unit: String
    var decimals = 1
    var referenceLine: Double? = nil
    var horizontal = false
    /// What the reference line is (e.g. "chance 25%"); drawn next to it.
    var referenceLabel: String? = nil
}

struct LinePoint: Hashable {
    var x: Double
    var y: Double
}

struct LineSeries: Identifiable {
    let id = UUID()
    var name: String
    var color: ColorKey
    var points: [LinePoint]
    var dashed = false
}

struct LineData {
    var series: [LineSeries]
    var xLabel: String
    var yLabel: String
    var yRange: ClosedRange<Double>? = nil
    var referenceY: Double? = nil
    var referenceX: Double? = nil
    var epochs: [Epoch] = []
    /// What the reference lines are; drawn next to them.
    var referenceYLabel: String? = nil
    var referenceXLabel: String? = nil
}

struct PolarData {
    /// Value per angular bin, bin 0 starts at 0° (counter-clockwise).
    var values: [Double]
    var unit: String
    var meanAngle: Double?
    var resultantLength: Double?
    /// Optional reference direction (e.g. cue card), degrees.
    var referenceAngle: Double?
    var color: ColorKey = .accent
}

struct TableData {
    var columns: [String]
    var rows: [[String]]
    /// Optional highlight per row.
    var rowColors: [ColorKey?] = []
}

struct PlotPath {
    var color: ColorKey
    /// Polylines; a new segment starts after missing samples.
    var segments: [[V2]]
    var width: Double = 1.2
    var opacity: Double = 0.8
}

struct PlotDot {
    var p: V2
    var color: ColorKey
    var radius: Double = 1.6
}

struct PlotArrow {
    var from: V2
    var to: V2
    var color: ColorKey
}

struct HeatGrid {
    var columns: Int
    var rows: Int
    var cell: Double
    /// Row-major values (seconds); NaN = outside arena.
    var values: [Double]
}

struct ArenaPlotData {
    var extent: V2
    var arena: Zone?
    var zones: [Zone]
    var paths: [PlotPath] = []
    var dots: [PlotDot] = []
    var arrows: [PlotArrow] = []
    var heat: HeatGrid? = nil
    var unit: String
    /// Arena units ↔ upright video pixels, for drawing the plot on the original video frame
    /// ("compare with the original image"). nil when the figure has no video behind it.
    var mapping: ArenaMapping? = nil
    /// Keypoint the heat map counts (for its caption / legend).
    var heatKeypoint: KP? = nil
}

enum ReportBlockKind {
    case arena(ArenaPlotData)
    case timeline(TimelineData)
    case bars(BarData)
    case line(LineData)
    case polar(PolarData)
    case table(TableData)
}

struct ReportBlock: Identifiable {
    let id = UUID()
    var title: String
    var caption: String?
    var kind: ReportBlockKind
}

// MARK: - Report

struct AnalysisReport {
    var metrics: [MetricValue] = []
    var blocks: [ReportBlock] = []
    /// Most important first (Analyzer.run puts tracking and data problems first and `notes` last).
    var warnings: [String] = []
    /// Standing notes of a task (e.g. "rule-based, check against manual scoring"): added after all warnings.
    var notes: [String] = []
    /// One line shown on the key result card under the headline value (e.g. "First choice: deep side").
    var keyNote: String?
    /// Extra per-frame columns for the frame-by-frame CSV (flags, zone membership, …).
    var frameColumns: [(String, [Double])] = []
    var primaryKey: String = ""
    var zones: [Zone] = []
    /// Timeline tracks shown under the review player.
    var reviewTracks: [TimelineTrack] = []
    var reviewEpochs: [Epoch] = []
    /// One sentence per method decision, for a Methods paragraph.
    var methods: [String] = []
    /// Quality summary.
    var quality: QualityInfo = QualityInfo()
    /// Per animal: frames whose tracked body point lies outside the calibrated arena (ArenaBounds; empty
    /// without calibration). Indexed like the track's frames. Only flags; no measure depends on it.
    var outsideArena: [OutsideArenaFrames] = []
    /// Tolerance used for `outsideArena` (cm beyond the arena's edge); nil without calibration.
    var outsideArenaTolerance: Double?
    /// Novelty-suppressed feeding: automatic candidate feeding bouts (video seconds) to check in the review.
    var feedingCandidates: [Bout] = []
    /// Pose model that produced the data (PoseModels.swift).
    var model: String = ""
    /// Series stored with the session for the group comparison's time course (RodentFlow 2.1; English names).
    var series: [FlowResultSeries] = []
    /// Two animals, one dark and one white: index of the dark one (from the fur colour on the back); nil otherwise.
    var darkAnimal: Int?
    /// Group task: per-animal and event tables for the JSON export (identities are arbitrary, so these are not metrics).
    var exportTables: [String: [[String]]] = [:]

    func metric(_ key: String) -> MetricValue? { metrics.first { $0.key == key } }
    var primary: MetricValue? { metric(primaryKey) ?? metrics.first }
}

struct QualityInfo {
    var frames = 0
    var framesInWindow = 0
    var windowSeconds: Double = 0
    var detectionRate: Double = 0
    /// Fraction of frames with each keypoint above the confidence threshold.
    var keypointRates: [Double] = []
    var headDirectionRate: Double = 0
    var sampleRate: Double = 0
    var pxPerUnit: Double = 0
    var unit = "cm"
    /// Per animal: fraction of the analysis window's frames tracked outside the calibrated arena
    /// (empty without calibration).
    var outsideArenaFraction: [Double] = []
}
