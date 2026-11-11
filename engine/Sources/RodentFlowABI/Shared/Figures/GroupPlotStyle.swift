// GroupPlotStyle.swift — how a group comparison is drawn (RodentFlow 2.0: iOS build 15, Mac build 14):
// plot type, error bars, significance brackets, Y range, grayscale. Remembered per task on this device, used
// on screen and in every export so both always match. Foundation only (shared by iOS, macOS and the tests).
//
// Conventions: dot plots with the summary statistic are preferred over bars alone for small samples
// (Weissgerber et al. 2015, PLoS Biol 13:e1002128); box plots follow Tukey (median, quartiles, whiskers to the
// most extreme value within 1.5 × IQR; McGill, Tukey & Larsen 1978); violins are Gaussian kernel densities with
// Silverman's bandwidth (Silverman 1986), scaled to the same maximum width.

import Foundation

enum GroupPlotKind: String, Codable, CaseIterable, Identifiable {
    /// Every animal as a dot, with the mean and error bar (the previous look).
    case dots
    case barDots = "bar_dots"
    case box
    case violin
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dots: return L("Dots + mean", "点 + 均值")
        case .barDots: return L("Bar + dots", "柱 + 点")
        case .box: return L("Box + dots", "箱线 + 点")
        case .violin: return L("Violin + dots", "小提琴 + 点")
        }
    }
}

enum ErrorBarKind: String, Codable, CaseIterable, Identifiable {
    case sem, sd, ci95
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sem: return "SEM"
        case .sd: return "SD"
        case .ci95: return "95% CI"
        }
    }

    /// English phrase for figure legends.
    var legendText: String {
        switch self {
        case .sem: return "mean ± SEM"
        case .sd: return "mean ± SD"
        case .ci95: return "mean with 95% confidence interval"
        }
    }

    /// The legend phrase in English (exports) or the interface language (caption under the figure on screen).
    func legendText(english: Bool) -> String {
        let en = english || !Lang.isChinese
        switch self {
        case .sem: return en ? "mean ± SEM" : "均值 ± SEM"
        case .sd: return en ? "mean ± SD" : "均值 ± SD"
        case .ci95: return en ? "mean with 95% confidence interval" : "均值及 95% 置信区间"
        }
    }

    /// Lower and upper end of the bar around the mean of `d`.
    func bounds(_ d: Descriptives) -> (low: Double, high: Double) {
        guard d.n >= 2 else { return (d.mean, d.mean) }
        switch self {
        case .sem: return (d.mean - d.sem, d.mean + d.sem)
        case .sd: return (d.mean - d.sd, d.mean + d.sd)
        case .ci95:
            let t = Distributions.tQuantile(0.975, df: Double(d.n - 1))
            let h = t.isFinite ? t * d.sem : 0
            return (d.mean - h, d.mean + h)
        }
    }
}

enum SignificanceLabel: String, Codable, CaseIterable, Identifiable {
    case stars, exact
    var id: String { rawValue }
    var displayName: String { self == .stars ? L("Stars (*)", "星号（*）") : L("Exact p", "精确 p 值") }
}

struct GroupPlotStyle: Codable, Equatable {
    var kind: GroupPlotKind = .dots
    var error: ErrorBarKind = .sem
    var showPoints = true
    /// Brackets with stars / p over the groups (from the pairwise comparisons on screen).
    var showSignificance = true
    var significance: SignificanceLabel = .stars
    /// Also draw brackets for comparisons with p ≥ 0.05 ("ns").
    var showNonsignificant = false
    /// Fixed Y range (nil = automatic).
    var yMin: Double? = nil
    var yMax: Double? = nil
    /// Black, white and grays only (each group a different gray and marker), for grayscale printing.
    var grayscale = false

    init() {}

    var isDefault: Bool { self == GroupPlotStyle() }

    enum CodingKeys: String, CodingKey { case kind, error, showPoints, showSignificance, significance, showNonsignificant, yMin, yMax, grayscale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.v(.kind, GroupPlotKind.dots)
        error = c.v(.error, ErrorBarKind.sem)
        showPoints = c.v(.showPoints, true)
        showSignificance = c.v(.showSignificance, true)
        significance = c.v(.significance, SignificanceLabel.stars)
        showNonsignificant = c.v(.showNonsignificant, false)
        yMin = c.v(.yMin, nil as Double?)
        yMax = c.v(.yMax, nil as Double?)
        grayscale = c.v(.grayscale, false)
    }

    /// English description of what the marks show (figure legends).
    var legendDescription: String { legendDescription(english: true) }

    /// What the marks show, in English (exports) or the interface language (caption under the figure on screen).
    func legendDescription(english: Bool) -> String {
        if english || !Lang.isChinese {
            let pts = showPoints ? " Each dot is one animal." : ""
            switch kind {
            case .dots: return "Lines show the \(error.legendText(english: true))." + pts
            case .barDots: return "Bars show the \(error.legendText(english: true))." + pts
            case .box: return "Boxes show the median and interquartile range; whiskers extend to the most extreme values within 1.5 × IQR." + pts
            case .violin: return "Violins show the distribution (Gaussian kernel density, Silverman bandwidth) with the median and quartiles." + pts
            }
        }
        let pts = showPoints ? "每个点为一只动物。" : ""
        let err = error.legendText(english: false)
        switch kind {
        case .dots: return "横线和误差线为\(err)。" + pts
        case .barDots: return "柱和误差线为\(err)。" + pts
        case .box: return "箱体为中位数和四分位距；须线延伸到 1.5 × IQR 以内的最远值。" + pts
        case .violin: return "小提琴图为分布（高斯核密度，Silverman 带宽），并标出中位数和四分位数。" + pts
        }
    }

    /// Line dash of a group in grayscale figures: four patterns in turn (solid, dashed, dotted, dash-dot), so groups
    /// that share a gray level or marker still differ; solid lines in color.
    func dash(_ index: Int) -> [Double] {
        guard grayscale else { return [] }
        let patterns: [[Double]] = [[], [2.5, 1.5], [0.7, 1.1], [3.2, 1.1, 0.7, 1.1]]
        return patterns[((index % patterns.count) + patterns.count) % patterns.count]
    }

    /// Text above a significance bracket.
    func label(_ p: Double) -> String {
        guard p.isFinite else { return "" }
        switch significance {
        case .stars: return StatsFormat.stars(p)
        case .exact: return StatsFormat.p(p)
        }
    }

    /// Whether a comparison gets a bracket.
    func bracketed(_ p: Double) -> Bool {
        showSignificance && p.isFinite && (p < 0.05 || showNonsignificant)
    }
}

/// Remembered plot styles (UserDefaults on this device), per task.
enum GroupPlotStyleStore {
    private static let prefix = "groupPlotStyle."

    static func load(task: String) -> GroupPlotStyle {
        guard let data = UserDefaults.standard.data(forKey: prefix + task),
              let style = try? JSONDecoder().decode(GroupPlotStyle.self, from: data) else { return GroupPlotStyle() }
        return style
    }

    static func save(_ style: GroupPlotStyle, task: String) {
        if style.isDefault {
            UserDefaults.standard.removeObject(forKey: prefix + task)
        } else if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: prefix + task)
        }
    }
}

// MARK: - Summary geometry (shared by the screen chart and the publication figure)

enum GroupGeometry {
    struct Box: Hashable {
        var q1: Double
        var median: Double
        var q3: Double
        var whiskerLow: Double
        var whiskerHigh: Double
    }

    /// Tukey box: quartiles (type 7) and whiskers to the most extreme values within 1.5 × IQR.
    static func box(_ values: [Double]) -> Box? {
        let v = values.filter { $0.isFinite }.sorted()
        guard let first = v.first, let last = v.last else { return nil }
        let q1 = Stats.quantile(v, 0.25), med = Stats.quantile(v, 0.5), q3 = Stats.quantile(v, 0.75)
        let iqr = q3 - q1
        let lo = v.first { $0 >= q1 - 1.5 * iqr } ?? first
        let hi = v.last { $0 <= q3 + 1.5 * iqr } ?? last
        return Box(q1: q1, median: med, q3: q3, whiskerLow: lo, whiskerHigh: hi)
    }

    /// Gaussian kernel density on `points` values between the data range ± 2 bandwidths (Silverman's rule:
    /// 0.9 · min(SD, IQR / 1.34) · n^−1/5). Returns (y, density) pairs; empty for fewer than 2 distinct values.
    static func violin(_ values: [Double], points: Int = 48) -> [(y: Double, density: Double)] {
        let v = values.filter { $0.isFinite }
        guard v.count >= 2, let lo = v.min(), let hi = v.max(), hi > lo else { return [] }
        let sd = Stats.sd(v)
        let iqr = Stats.quantile(v, 0.75) - Stats.quantile(v, 0.25)
        var spread = min(sd, iqr > 0 ? iqr / 1.34 : sd)
        if !(spread > 0) { spread = sd > 0 ? sd : (hi - lo) / 4 }
        let h = 0.9 * spread * pow(Double(v.count), -0.2)
        guard h > 0 else { return [] }
        let a = lo - 2 * h, b = hi + 2 * h
        let norm = 1 / (Double(v.count) * h * (2 * Double.pi).squareRoot())
        return (0..<points).map { i -> (y: Double, density: Double) in
            let y = a + (b - a) * Double(i) / Double(points - 1)
            let d = v.reduce(0.0) { s, x in
                let z = (y - x) / h
                return s + exp(-0.5 * z * z)
            } * norm
            return (y: y, density: d)
        }
    }

    /// Automatic Y range of a group figure: data, error bars and whiskers, with room for brackets.
    static func autoRange(values: [Double], extra: [Double] = [], includeZero: Bool) -> (Double, Double) {
        let all = (values + extra).filter { $0.isFinite }
        guard var lo = all.min(), var hi = all.max() else { return (0, 1) }
        if includeZero { lo = min(lo, 0); hi = max(hi, 0) }
        if hi - lo < 1e-12 { hi = lo + 1 }
        let pad = (hi - lo) * 0.06
        return (lo < 0 || !includeZero ? lo - pad : lo, hi + pad)
    }

    /// "Nice" axis ticks (1, 2, 2.5, 5 × 10^k) covering [lo, hi].
    static func ticks(_ lo: Double, _ hi: Double, target: Int = 5) -> [Double] {
        guard hi > lo, lo.isFinite, hi.isFinite else { return [lo] }
        let raw = (hi - lo) / Double(max(2, target))
        let mag = pow(10, floor(log10(raw)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0].map { $0 * mag }.first { $0 >= raw } ?? 10 * mag
        var t = ceil(lo / step - 1e-9) * step
        var out: [Double] = []
        while t <= hi + step * 1e-9 && out.count < 50 {
            out.append(abs(t) < step * 1e-9 ? 0 : t)
            t += step
        }
        return out
    }

    /// Bracket rows for pairwise comparisons over groups at x positions 0…k−1 (shorter spans lower, no overlap
    /// on one row).
    static func bracketRows(_ pairs: [(a: Int, b: Int)]) -> [Int] {
        let order = pairs.indices.sorted { i, j in
            let si = abs(pairs[i].b - pairs[i].a), sj = abs(pairs[j].b - pairs[j].a)
            return si != sj ? si < sj : min(pairs[i].a, pairs[i].b) < min(pairs[j].a, pairs[j].b)
        }
        var rows = [Int](repeating: 0, count: pairs.count)
        var occupied: [[ClosedRange<Int>]] = []
        for i in order {
            let lo = min(pairs[i].a, pairs[i].b), hi = max(pairs[i].a, pairs[i].b)
            var r = 0
            // Brackets that only share an end group fit on one row (they are drawn slightly inset).
            while r < occupied.count && occupied[r].contains(where: { $0.lowerBound < hi && lo < $0.upperBound }) { r += 1 }
            if r == occupied.count { occupied.append([]) }
            occupied[r].append(lo...hi)
            rows[i] = r
        }
        return rows
    }
}
