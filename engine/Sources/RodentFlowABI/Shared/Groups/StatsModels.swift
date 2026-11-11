// StatsModels.swift — assumption checks, linear models (two-way ANOVA, ANCOVA) and effect sizes for the
// group comparison (RodentFlow 2.0: iOS build 15, Mac build 14). Pure Foundation, identical on both
// platforms, tested off-device (tools/tests/StatsModelsTest.swift; reference values from SciPy / NumPy).
//
// Methods and references
//   • Shapiro–Wilk W and p: Royston (1995) algorithm AS R94 (as in R's shapiro.test and SciPy), 3 ≤ n ≤ 5000.
//   • Brown–Forsythe test: one-way ANOVA on |y − group median| (Brown & Forsythe 1974).
//   • Pre-tests only give a hint; they never switch the test (Rochon et al. 2012; Zimmerman 2004).
//   • Linear models by least squares with sum-to-zero (effect) coding; each term is tested by comparing the
//     full model with the model without that term (Type III sums of squares, valid for unbalanced cells).
//   • Simple effects use the pooled error of the full two-way model; their pairwise comparisons are
//     Holm-corrected within each family.
//   • ANCOVA: group adjusted for one covariate (centered); homogeneity of regression slopes is checked with the
//     group × covariate interaction; adjusted (estimated marginal) means at the covariate mean.
//   • Effect sizes: η² / partial η² / ω², Hedges' g with an approximate 95% CI (Hedges & Olkin 1985),
//     r = Z / √N for the Mann–Whitney test (Rosenthal 1991; Tomczak & Tomczak 2014), Hodges–Lehmann shift,
//     95% CIs of mean differences (Welch, Tukey simultaneous, or pooled error of the model).

import Foundation

// MARK: - Result types

/// One effect size, with its 95% CI when one is defined.
struct EffectSizeRow: Codable, Hashable, Identifiable {
    /// What is compared, e.g. "WT − KO", "Overall", "Genotype".
    var label: String
    /// e.g. "Hedges' g", "Mean difference", "r", "η²", "partial η²".
    var name: String
    var value: Double
    var low: Double? = nil
    var high: Double? = nil
    var note: String? = nil
    var id: String { label + "|" + name }

    var line: String {
        var s = "\(name) = \(StatsFormat.number(value))"
        if let low, let high { s += " [95% CI \(StatsFormat.number(low)), \(StatsFormat.number(high))]" }
        return s
    }
}

/// Shapiro–Wilk of one group (or of the model residuals).
struct NormalityRow: Codable, Hashable, Identifiable {
    var label: String
    var n: Int
    var w: Double?
    var p: Double?
    var id: String { label }
}

/// Normality and equal-spread checks. A hint only: the chosen test is never changed automatically.
struct AssumptionReport: Codable, Hashable {
    var normality: [NormalityRow] = []
    /// Shapiro–Wilk of the residuals of the model (values minus their group / cell mean).
    var residuals: NormalityRow? = nil
    /// Brown–Forsythe test of equal spread.
    var spread: TestResult? = nil
    var smallestN = 0
    var suggestsNonparametric = false
    /// One-sentence hint shown under the test.
    var suggestion = ""
}

struct ModelTerm: Codable, Hashable, Identifiable {
    var name: String
    var ss: Double
    var df: Double
    var f: Double
    var p: Double
    var partialEta: Double
    var id: String { name }

    func test(dfError: Double) -> TestResult {
        TestResult(name: name, statisticName: "F", statistic: f, df1: df, df2: dfError, p: p,
                   effectName: "partial η²", effect: partialEta)
    }
}

struct TwoWayCell: Codable, Hashable, Identifiable {
    var a: String
    var b: String
    var n: Int
    var mean: Double
    var sd: Double
    var sem: Double
    var id: String { a + "|" + b }
}

struct SimpleEffect: Codable, Hashable, Identifiable {
    /// Factor tested (e.g. "Genotype") and the level of the other factor it is tested at (e.g. "F").
    var factor: String
    var at: String
    var test: TestResult
    var id: String { factor + "|" + at }
}

struct TwoWayReport: Codable, Hashable {
    var factorA: String
    var factorB: String
    var levelsA: [String]
    var levelsB: [String]
    var cells: [TwoWayCell]
    /// A, B and A × B (Type III).
    var terms: [ModelTerm]
    var ssError: Double
    var dfError: Double
    var simpleA: [SimpleEffect]
    var simpleB: [SimpleEffect]
    /// A levels compared within each B level (`level` = B level), Holm-corrected together.
    var pairwiseA: [PairwiseComparison]
    /// B levels compared within each A level (`level` = A level), Holm-corrected together.
    var pairwiseB: [PairwiseComparison]
    var residuals: [Double]
    var animals: Int
    var methodSummary: String
}

struct AdjustedMean: Codable, Hashable, Identifiable {
    var group: String
    var n: Int
    var mean: Double
    var se: Double
    var low: Double
    var high: Double
    var id: String { group }
}

struct ANCOVAReport: Codable, Hashable {
    var covariateKey: String
    var covariateName: String
    var covariateMean: Double
    var group: ModelTerm
    var covariate: ModelTerm
    var dfError: Double
    var slope: Double
    var slopeSE: Double
    /// Group × covariate (homogeneity of regression slopes); nil when it cannot be fitted.
    var slopes: TestResult?
    var adjusted: [AdjustedMean]
    var pairwise: [PairwiseComparison]
    var residuals: [Double]
    var animals: Int
    var notes: [String]
    var methodSummary: String
}

// MARK: - Normal quantile

extension Distributions {
    /// Quantile of the standard normal distribution (Acklam's rational approximation refined by one Halley
    /// step; |error| < 1e-15 in double precision).
    static func normalQuantile(_ p: Double) -> Double {
        guard p > 0 else { return -.infinity }
        guard p < 1 else { return .infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00]
        let low = 0.02425
        var x: Double
        if p < low {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= 1 - low {
            let q = p - 0.5
            let r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let e = 0.5 * erfc(-x / 2.0.squareRoot()) - p
        let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
        x -= u / (1 + x * u / 2)
        return x
    }

    private static let rangeLock = NSLock()
    private static var rangeMemo: [String: Double] = [:]

    /// Upper `alpha` point of the studentized range (k means, df error degrees of freedom), by bisection on
    /// `studentizedRangeCDF`; memoized because the group page recomputes on every redraw.
    static func studentizedRangeQuantile(alpha: Double = 0.05, k: Double, df: Double) -> Double? {
        guard k >= 2, df >= 2 else { return nil }
        let key = "\(alpha)|\(k)|\(df)"
        rangeLock.lock()
        let hit = rangeMemo[key]
        rangeLock.unlock()
        if let hit { return hit }
        var lo = 0.0, hi = 60.0
        for _ in 0..<60 {
            let mid = 0.5 * (lo + hi)
            let cdf = studentizedRangeCDF(mid, k: k, df: df)
            guard cdf.isFinite else { return nil }
            if cdf < 1 - alpha { lo = mid } else { hi = mid }
        }
        let q = 0.5 * (lo + hi)
        rangeLock.lock()
        if rangeMemo.count > 256 { rangeMemo.removeAll() }
        rangeMemo[key] = q
        rangeLock.unlock()
        return q
    }
}

// MARK: - Assumption tests

extension StatTests {
    struct ShapiroWilkResult: Codable, Hashable {
        var w: Double
        var p: Double
        var n: Int
    }

    private static func swPoly(_ cc: [Double], _ x: Double) -> Double {
        var r = cc[0]
        if cc.count > 1 {
            var p = x * cc[cc.count - 1]
            var j = cc.count - 2
            while j >= 1 {
                p = (p + cc[j]) * x
                j -= 1
            }
            r += p
        }
        return r
    }

    /// Shapiro–Wilk test (Royston 1995, AS R94). nil for n < 3, n > 5000 or no spread.
    static func shapiroWilk(_ values: [Double]) -> ShapiroWilkResult? {
        let x = values.filter { $0.isFinite }.sorted()
        let n = x.count
        guard n >= 3, n <= 5000, let first = x.first, let last = x.last else { return nil }
        let range = last - first
        guard range > 1e-12 * Swift.max(abs(first), abs(last), 1e-300) else { return nil }
        let nn2 = n / 2
        var a = [Double](repeating: 0, count: nn2 + 1)
        let an = Double(n)
        if n == 3 {
            a[1] = 0.5.squareRoot()
        } else {
            let an25 = an + 0.25
            var m = [Double](repeating: 0, count: nn2 + 1)
            var summ2 = 0.0
            for i in 1...nn2 {
                m[i] = Distributions.normalQuantile((Double(i) - 0.375) / an25)
                summ2 += m[i] * m[i]
            }
            summ2 *= 2
            let ssumm2 = summ2.squareRoot()
            let rsn = 1 / an.squareRoot()
            let c1 = [0.0, 0.221157, -0.147981, -2.07119, 4.434685, -2.706056]
            let c2 = [0.0, 0.042981, -0.293762, -1.752461, 5.682633, -3.582633]
            let a1 = swPoly(c1, rsn) - m[1] / ssumm2
            let i1: Int
            let fac: Double
            if n > 5 {
                i1 = 3
                let a2 = -m[2] / ssumm2 + swPoly(c2, rsn)
                fac = ((summ2 - 2 * m[1] * m[1] - 2 * m[2] * m[2]) / (1 - 2 * a1 * a1 - 2 * a2 * a2)).squareRoot()
                a[2] = a2
            } else {
                i1 = 2
                fac = ((summ2 - 2 * m[1] * m[1]) / (1 - 2 * a1 * a1)).squareRoot()
            }
            a[1] = a1
            if i1 <= nn2 {
                for i in i1...nn2 { a[i] = -m[i] / fac }
            }
        }
        var coef = [Double](repeating: 0, count: n)
        for i in 1...nn2 {
            coef[i - 1] = -a[i]
            coef[n - i] = a[i]
        }
        let mean = x.reduce(0, +) / an
        var ss = 0.0, num = 0.0
        for i in 0..<n {
            ss += (x[i] - mean) * (x[i] - mean)
            num += coef[i] * x[i]
        }
        guard ss > 0 else { return nil }
        let w = Swift.min(1, num * num / ss)
        if n == 3 {
            let pw = 1.90985931710274 * (asin(w.squareRoot()) - 1.04719755119660)
            return ShapiroWilkResult(w: w, p: Swift.min(1, Swift.max(0, pw)), n: n)
        }
        guard w < 1 else { return ShapiroWilkResult(w: w, p: 1, n: n) }
        var y = log(1 - w)
        let mm: Double, s: Double
        if n <= 11 {
            let gamma = swPoly([-2.273, 0.459], an)
            if y >= gamma { return ShapiroWilkResult(w: w, p: 1e-99, n: n) }
            y = -log(gamma - y)
            mm = swPoly([0.544, -0.39978, 0.025054, -6.714e-4], an)
            s = exp(swPoly([1.3822, -0.77857, 0.062767, -0.0020322], an))
        } else {
            let xx = log(an)
            mm = swPoly([-1.5861, -0.31082, -0.083751, 0.0038915], xx)
            s = exp(swPoly([-0.4803, -0.082676, 0.0030302], xx))
        }
        let p = SpecialFunctions.normalSF((y - mm) / s)
        return ShapiroWilkResult(w: w, p: Swift.min(1, Swift.max(0, p)), n: n)
    }

    /// Brown–Forsythe test of equal spread: one-way ANOVA on absolute deviations from the group medians.
    static func brownForsythe(_ groups: [[Double]]) -> TestResult? {
        let valid = groups.map { $0.filter { $0.isFinite } }.filter { $0.count >= 2 }
        guard valid.count >= 2 else { return nil }
        let deviations = valid.map { g -> [Double] in
            let med = Stats.quantile(g, 0.5)
            return g.map { abs($0 - med) }
        }
        guard let anova = oneWayANOVA(deviations) else { return nil }
        var t = anova.test
        t.name = "Brown–Forsythe test"
        t.effectName = nil
        t.effect = nil
        return t
    }

    /// Normal-approximation z of the Mann–Whitney U (tie-corrected, no continuity correction): the z of
    /// r = Z / √N. Positive when `a` tends to be larger.
    static func mannWhitneyZ(_ a: [Double], _ b: [Double]) -> Double? {
        let n1 = a.count, n2 = b.count
        guard n1 >= 1, n2 >= 1, n1 + n2 >= 3 else { return nil }
        let (r, ties) = Stats.ranks(a + b)
        let u1 = r[0..<n1].reduce(0, +) - Double(n1 * (n1 + 1)) / 2
        let n = Double(n1 + n2)
        let tieTerm = ties.reduce(0.0) { $0 + Double($1 * $1 * $1 - $1) }
        let sigma = (Double(n1 * n2) / 12 * ((n + 1) - tieTerm / (n * (n - 1)))).squareRoot()
        guard sigma > 0 else { return nil }
        return (u1 - Double(n1 * n2) / 2) / sigma
    }

    /// Hodges–Lehmann estimate of the shift a − b (median of all pairwise differences).
    static func hodgesLehmann(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var d: [Double] = []
        d.reserveCapacity(a.count * b.count)
        for x in a { for y in b { d.append(x - y) } }
        return Stats.quantile(d, 0.5)
    }

    /// Approximate 95% CI of Hedges' g (large-sample variance, Hedges & Olkin 1985).
    static func hedgesGCI(_ g: Double, n1: Int, n2: Int) -> (low: Double, high: Double) {
        let a = Double(n1), b = Double(n2)
        let se = ((a + b) / (a * b) + g * g / (2 * (a + b))).squareRoot()
        return (g - 1.959963984540054 * se, g + 1.959963984540054 * se)
    }

    /// ω² of a one-way design (less biased than η²).
    static func omegaSquared(_ groups: [[Double]]) -> Double? {
        let valid = groups.filter { !$0.isEmpty }
        let all = valid.flatMap { $0 }
        let k = Double(valid.count), n = Double(all.count)
        guard k >= 2, n > k else { return nil }
        let grand = Stats.mean(all)
        var ssb = 0.0, ssw = 0.0
        for g in valid {
            let m = Stats.mean(g)
            ssb += Double(g.count) * (m - grand) * (m - grand)
            ssw += g.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        }
        let msw = ssw / (n - k)
        let denom = ssb + ssw + msw
        guard denom > 0 else { return nil }
        return Swift.max(0, (ssb - (k - 1) * msw) / denom)
    }

    /// Normality per group and of the residuals, equal spread, and a one-sentence hint.
    static func assumptions(_ groups: [(label: String, values: [Double])], english: Bool,
                            twoGroups: Bool, residualsOverride: [Double]? = nil) -> AssumptionReport {
        func tx(_ en: String, _ zh: String) -> String { english || !Lang.isChinese ? en : zh }
        var report = AssumptionReport()
        var residuals: [Double] = []
        var anyNonNormal = false
        for (label, values) in groups {
            let v = values.filter { $0.isFinite }
            let sw = shapiroWilk(v)
            report.normality.append(NormalityRow(label: label, n: v.count, w: sw?.w, p: sw?.p))
            if let sw, sw.p < 0.05 { anyNonNormal = true }
            if !v.isEmpty {
                let m = Stats.mean(v)
                residuals += v.map { $0 - m }
            }
        }
        if let r = residualsOverride { residuals = r }
        if let sw = shapiroWilk(residuals) {
            report.residuals = NormalityRow(label: tx("Residuals", "残差"), n: residuals.count, w: sw.w, p: sw.p)
            if sw.p < 0.05 { anyNonNormal = true }
        }
        report.spread = brownForsythe(groups.map { $0.values })
        report.smallestN = groups.map { $0.values.filter { $0.isFinite }.count }.min() ?? 0
        let unequal = (report.spread?.p ?? 1) < 0.05
        var parts: [String] = []
        if anyNonNormal {
            report.suggestsNonparametric = true
            parts.append(tx("At least one group (or the residuals) departs from normality (Shapiro–Wilk p < 0.05): a non-parametric test is suggested; also check for outliers or a skewed measure (e.g. latencies).",
                            "至少一组（或残差）偏离正态（Shapiro–Wilk p < 0.05）：建议用非参数检验；也请检查离群值或偏态指标（如潜伏期）。"))
        } else if unequal && !twoGroups {
            report.suggestsNonparametric = true
            parts.append(tx("Spreads differ between groups (Brown–Forsythe p < 0.05): a non-parametric test is suggested.",
                            "各组离散程度不同（Brown–Forsythe p < 0.05）：建议用非参数检验。"))
        } else if unequal {
            parts.append(tx("Spreads differ (Brown–Forsythe p < 0.05); Welch's t-test does not assume equal variances.",
                            "离散程度不同（Brown–Forsythe p < 0.05）；Welch t 检验本身不要求方差相等。"))
        } else {
            parts.append(tx("No clear departure from normality or equal spread: a parametric test is appropriate.",
                            "未见明显偏离正态或方差不齐：参数检验合适。"))
        }
        if report.smallestN < 8 {
            parts.append(tx("With fewer than 8 animals in a group these checks have little power; they cannot show that the data are normal.",
                            "某组少于 8 只动物时，这些检验的功效很低，不能据此证明数据正态。"))
        }
        parts.append(tx("Hint only: the test is not changed automatically.", "仅作提示，不会自动更换检验。"))
        report.suggestion = parts.joined(separator: " ")
        return report
    }
}

// MARK: - Linear model

struct LinearFit {
    var beta: [Double]
    var sse: Double
    var dfError: Int
    /// (XᵀX)⁻¹
    var inverse: [[Double]]
    var residuals: [Double]
}

enum LinearModel {
    /// Sum-to-zero (effect) coding of a factor level: k − 1 columns; the last level is −1 in every column.
    static func effectCoding(_ levels: [String], _ level: String) -> [Double] {
        guard levels.count >= 2 else { return [] }
        let last = levels[levels.count - 1]
        return (0..<(levels.count - 1)).map { i in level == levels[i] ? 1 : (level == last ? -1 : 0) }
    }

    /// Inverse of a small symmetric positive (semi-)definite matrix by Gauss–Jordan elimination with partial
    /// pivoting; nil when it is singular (rank-deficient design).
    static func invert(_ m: [[Double]]) -> [[Double]]? {
        let p = m.count
        guard p > 0, m.allSatisfy({ $0.count == p }) else { return nil }
        let scale = (0..<p).map { abs(m[$0][$0]) }.max() ?? 0
        guard scale > 0 else { return nil }
        var a = m
        var inv = (0..<p).map { i in (0..<p).map { j in i == j ? 1.0 : 0.0 } }
        for col in 0..<p {
            var pivot = col
            for r in (col + 1)..<max(col + 1, p) where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-11 * scale else { return nil }
            if pivot != col {
                a.swapAt(pivot, col)
                inv.swapAt(pivot, col)
            }
            let d = a[col][col]
            for j in 0..<p {
                a[col][j] /= d
                inv[col][j] /= d
            }
            for r in 0..<p where r != col {
                let f = a[r][col]
                guard f != 0 else { continue }
                for j in 0..<p {
                    a[r][j] -= f * a[col][j]
                    inv[r][j] -= f * inv[col][j]
                }
            }
        }
        return inv
    }

    /// Least-squares fit of y on the columns of x (rows = observations).
    static func fit(_ x: [[Double]], _ y: [Double]) -> LinearFit? {
        let n = y.count
        guard n > 0, x.count == n, let p = x.first?.count, p > 0, n > p else { return nil }
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var xty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            let row = x[i]
            for a in 0..<p {
                xty[a] += row[a] * y[i]
                for b in a..<p { xtx[a][b] += row[a] * row[b] }
            }
        }
        for a in 0..<p { for b in 0..<a { xtx[a][b] = xtx[b][a] } }
        guard let inv = invert(xtx) else { return nil }
        let beta = (0..<p).map { a in (0..<p).reduce(0.0) { $0 + inv[a][$1] * xty[$1] } }
        var sse = 0.0
        var res = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var f = 0.0
            for a in 0..<p { f += x[i][a] * beta[a] }
            res[i] = y[i] - f
            sse += res[i] * res[i]
        }
        return LinearFit(beta: beta, sse: sse, dfError: n - p, inverse: inv, residuals: res)
    }

    /// dᵀ (XᵀX)⁻¹ d
    static func quadratic(_ d: [Double], _ inv: [[Double]]) -> Double {
        var s = 0.0
        for i in d.indices where d[i] != 0 {
            for j in d.indices where d[j] != 0 { s += d[i] * inv[i][j] * d[j] }
        }
        return s
    }
}

// MARK: - Two-way ANOVA and ANCOVA

extension StatTests {
    struct FactorialObservation {
        var a: String
        var b: String
        var value: Double
    }

    struct CovariateObservation {
        var group: String
        var covariate: Double
        var value: Double
    }

    private static func pairwiseFromPooled(_ names: [String], means: [Double], ns: [Int], mse: Double, dfError: Double,
                                           level: String?, method: String) -> [PairwiseComparison] {
        var out: [PairwiseComparison] = []
        let tq = Distributions.tQuantile(0.975, df: dfError)
        for i in 0..<names.count {
            for j in (i + 1)..<max(i + 1, names.count) {
                guard ns[i] > 0, ns[j] > 0 else { continue }
                let diff = means[i] - means[j]
                let se = (mse * (1 / Double(ns[i]) + 1 / Double(ns[j]))).squareRoot()
                guard se > 0 else { continue }
                let t = diff / se
                let p = Distributions.tTwoSidedP(t, df: dfError)
                out.append(PairwiseComparison(groupA: names[i], groupB: names[j], level: level, difference: diff,
                                              statisticName: "t", statistic: t, p: p, pAdjusted: p, method: method,
                                              ciLow: diff - tq * se, ciHigh: diff + tq * se))
            }
        }
        return out
    }

    private static func holmInPlace(_ comps: inout [PairwiseComparison]) {
        let adj = Stats.holm(comps.map(\.p))
        for i in comps.indices { comps[i].pAdjusted = adj[i] }
    }

    /// Between-subjects two-way ANOVA (Type III) with interaction and simple effects. Every A × B cell needs
    /// at least one animal and the error needs ≥ 1 degree of freedom; nil otherwise.
    static func twoWayANOVA(_ input: [FactorialObservation], levelsA wantedA: [String], levelsB wantedB: [String],
                            nameA: String, nameB: String, english: Bool) -> TwoWayReport? {
        func tx(_ en: String, _ zh: String) -> String { english || !Lang.isChinese ? en : zh }
        let obs = input.filter { $0.value.isFinite && wantedA.contains($0.a) && wantedB.contains($0.b) }
        let levelsA = wantedA.filter { a in obs.contains { $0.a == a } }
        let levelsB = wantedB.filter { b in obs.contains { $0.b == b } }
        let na = levelsA.count, nb = levelsB.count
        guard na >= 2, nb >= 2 else { return nil }
        var cellValues: [String: [Double]] = [:]
        for o in obs { cellValues[o.a + "\u{1F}" + o.b, default: []].append(o.value) }
        for a in levelsA { for b in levelsB where (cellValues[a + "\u{1F}" + b]?.isEmpty ?? true) { return nil } }
        let n = obs.count
        let dfE = n - na * nb
        guard dfE >= 1 else { return nil }

        func design(dropA: Bool, dropB: Bool, dropAB: Bool) -> [[Double]] {
            obs.map { o in
                let ca = LinearModel.effectCoding(levelsA, o.a)
                let cb = LinearModel.effectCoding(levelsB, o.b)
                var row: [Double] = [1]
                if !dropA { row += ca }
                if !dropB { row += cb }
                if !dropAB { for x in ca { for y in cb { row.append(x * y) } } }
                return row
            }
        }
        let y = obs.map(\.value)
        guard let full = LinearModel.fit(design(dropA: false, dropB: false, dropAB: false), y) else { return nil }
        let sse = full.sse
        let mse = sse / Double(dfE)
        if Stats.negligible(mse.squareRoot(), scale: y) { return nil }
        func term(_ name: String, _ reduced: LinearFit?, _ df: Int) -> ModelTerm? {
            guard let reduced else { return nil }
            let ss = Swift.max(0, reduced.sse - sse)
            let f = (ss / Double(df)) / mse
            return ModelTerm(name: name, ss: ss, df: Double(df), f: f,
                             p: Distributions.fSF(f, df1: Double(df), df2: Double(dfE)),
                             partialEta: ss + sse > 0 ? ss / (ss + sse) : 0)
        }
        guard let tA = term(nameA, LinearModel.fit(design(dropA: true, dropB: false, dropAB: false), y), na - 1),
              let tB = term(nameB, LinearModel.fit(design(dropA: false, dropB: true, dropAB: false), y), nb - 1),
              let tAB = term(nameA + " × " + nameB, LinearModel.fit(design(dropA: false, dropB: false, dropAB: true), y), (na - 1) * (nb - 1))
        else { return nil }

        var cells: [TwoWayCell] = []
        for a in levelsA {
            for b in levelsB {
                let d = Stats.describe(cellValues[a + "\u{1F}" + b] ?? [])
                cells.append(TwoWayCell(a: a, b: b, n: d.n, mean: d.mean, sd: d.sd, sem: d.sem))
            }
        }
        func cell(_ a: String, _ b: String) -> TwoWayCell? { cells.first { $0.a == a && $0.b == b } }

        // Simple effects with the pooled error of the full model.
        func simple(factor: String, levels: [String], at: String, cellsAt: [TwoWayCell]) -> SimpleEffect? {
            let ns = cellsAt.map { Double($0.n) }
            let total = ns.reduce(0, +)
            guard total > 0, levels.count >= 2 else { return nil }
            let wm = zip(cellsAt, ns).reduce(0.0) { $0 + $1.0.mean * $1.1 } / total
            let ss = zip(cellsAt, ns).reduce(0.0) { $0 + $1.1 * ($1.0.mean - wm) * ($1.0.mean - wm) }
            let df = Double(levels.count - 1)
            let f = (ss / df) / mse
            let t = TestResult(name: String(format: tx("Simple effect of %@ at %@", "%@ 在 %@ 的简单效应"), factor, at),
                               statisticName: "F", statistic: f, df1: df, df2: Double(dfE),
                               p: Distributions.fSF(f, df1: df, df2: Double(dfE)),
                               effectName: "partial η²", effect: ss + sse > 0 ? ss / (ss + sse) : 0)
            return SimpleEffect(factor: factor, at: at, test: t)
        }
        var simpleA: [SimpleEffect] = []
        var pairA: [PairwiseComparison] = []
        for b in levelsB {
            let cs = levelsA.compactMap { cell($0, b) }
            if let s = simple(factor: nameA, levels: levelsA, at: b, cellsAt: cs) { simpleA.append(s) }
            pairA += pairwiseFromPooled(levelsA, means: cs.map(\.mean), ns: cs.map(\.n), mse: mse, dfError: Double(dfE),
                                        level: b, method: "t (pooled two-way error, Holm)")
        }
        var simpleB: [SimpleEffect] = []
        var pairB: [PairwiseComparison] = []
        for a in levelsA {
            let cs = levelsB.compactMap { cell(a, $0) }
            if let s = simple(factor: nameB, levels: levelsB, at: a, cellsAt: cs) { simpleB.append(s) }
            pairB += pairwiseFromPooled(levelsB, means: cs.map(\.mean), ns: cs.map(\.n), mse: mse, dfError: Double(dfE),
                                        level: a, method: "t (pooled two-way error, Holm)")
        }
        holmInPlace(&pairA)
        holmInPlace(&pairB)
        let summary = String(format: tx("Two-way ANOVA (%@ × %@, between animals) with Type III sums of squares; simple effects and pairwise comparisons use the pooled error of the full model (pairwise p Holm-corrected within each family).",
                                        "双因素方差分析（%@ × %@，动物间），Type III 平方和；简单效应和两两比较使用完整模型的合并误差（两两比较在每组比较内做 Holm 校正）。"), nameA, nameB)
        return TwoWayReport(factorA: nameA, factorB: nameB, levelsA: levelsA, levelsB: levelsB, cells: cells,
                            terms: [tA, tB, tAB], ssError: sse, dfError: Double(dfE), simpleA: simpleA, simpleB: simpleB,
                            pairwiseA: pairA, pairwiseB: pairB, residuals: full.residuals, animals: n, methodSummary: summary)
    }

    /// One-way ANCOVA: groups adjusted for one covariate. nil when it cannot be fitted (< 2 groups, too few
    /// animals, no spread of the covariate).
    static func ancova(_ input: [CovariateObservation], groups wanted: [String], covariateKey: String, covariateName: String,
                       english: Bool) -> ANCOVAReport? {
        func tx(_ en: String, _ zh: String) -> String { english || !Lang.isChinese ? en : zh }
        let obs = input.filter { $0.value.isFinite && $0.covariate.isFinite && wanted.contains($0.group) }
        let groups = wanted.filter { g in obs.filter { $0.group == g }.count >= 2 }
        let used = obs.filter { groups.contains($0.group) }
        let k = groups.count, n = used.count
        guard k >= 2, n - k - 1 >= 1 else { return nil }
        let covs = used.map(\.covariate)
        let cm = Stats.mean(covs)
        guard Stats.variance(covs) > 1e-12 * Swift.max(1, cm * cm) else { return nil }
        let y = used.map(\.value)
        func design(dropGroup: Bool, dropCov: Bool, interaction: Bool) -> [[Double]] {
            used.map { o in
                let e = LinearModel.effectCoding(groups, o.group)
                var row: [Double] = [1]
                if !dropGroup { row += e }
                if !dropCov { row.append(o.covariate - cm) }
                if interaction { row += e.map { $0 * (o.covariate - cm) } }
                return row
            }
        }
        guard let full = LinearModel.fit(design(dropGroup: false, dropCov: false, interaction: false), y),
              let noGroup = LinearModel.fit(design(dropGroup: true, dropCov: false, interaction: false), y),
              let noCov = LinearModel.fit(design(dropGroup: false, dropCov: true, interaction: false), y) else { return nil }
        let dfE = Double(n - k - 1)
        let sse = full.sse
        let mse = sse / dfE
        if Stats.negligible(mse.squareRoot(), scale: y) { return nil }
        let ssG = Swift.max(0, noGroup.sse - sse), ssC = Swift.max(0, noCov.sse - sse)
        let fG = (ssG / Double(k - 1)) / mse, fC = ssC / mse
        let groupTerm = ModelTerm(name: tx("Group (adjusted)", "组（校正后）"), ss: ssG, df: Double(k - 1), f: fG,
                                  p: Distributions.fSF(fG, df1: Double(k - 1), df2: dfE), partialEta: ssG / (ssG + sse))
        let covTerm = ModelTerm(name: covariateName, ss: ssC, df: 1, f: fC,
                                p: Distributions.fSF(fC, df1: 1, df2: dfE), partialEta: ssC / (ssC + sse))
        let p = full.beta.count
        let slope = full.beta[p - 1]
        let slopeSE = (full.inverse[p - 1][p - 1] * mse).squareRoot()

        var slopes: TestResult?
        if n - 2 * k >= 1, let inter = LinearModel.fit(design(dropGroup: false, dropCov: false, interaction: true), y) {
            let dfI = Double(n - 2 * k)
            let ssI = Swift.max(0, sse - inter.sse)
            let msI = inter.sse / dfI
            if msI > 0 {
                let f = (ssI / Double(k - 1)) / msI
                slopes = TestResult(name: tx("Group × covariate (equal slopes)", "组 × 协变量（斜率齐性）"), statisticName: "F", statistic: f,
                                    df1: Double(k - 1), df2: dfI, p: Distributions.fSF(f, df1: Double(k - 1), df2: dfI))
            }
        }
        let tq = Distributions.tQuantile(0.975, df: dfE)
        func lvec(_ g: String) -> [Double] { [1] + LinearModel.effectCoding(groups, g) + [0] }
        var adjusted: [AdjustedMean] = []
        for g in groups {
            let l = lvec(g)
            let m = zip(l, full.beta).reduce(0.0) { $0 + $1.0 * $1.1 }
            let se = (LinearModel.quadratic(l, full.inverse) * mse).squareRoot()
            adjusted.append(AdjustedMean(group: g, n: used.filter { $0.group == g }.count, mean: m, se: se,
                                         low: m - tq * se, high: m + tq * se))
        }
        var pairs: [PairwiseComparison] = []
        for i in 0..<k {
            for j in (i + 1)..<max(i + 1, k) {
                let d = zip(lvec(groups[i]), lvec(groups[j])).map { $0 - $1 }
                let diff = adjusted[i].mean - adjusted[j].mean
                let se = (LinearModel.quadratic(d, full.inverse) * mse).squareRoot()
                guard se > 0 else { continue }
                let t = diff / se
                let pv = Distributions.tTwoSidedP(t, df: dfE)
                pairs.append(PairwiseComparison(groupA: groups[i], groupB: groups[j], level: nil, difference: diff,
                                                statisticName: "t", statistic: t, p: pv, pAdjusted: pv,
                                                method: "ANCOVA adjusted means (Holm)", ciLow: diff - tq * se, ciHigh: diff + tq * se))
            }
        }
        holmInPlace(&pairs)
        var notes: [String] = []
        if let s = slopes, s.p < 0.05 {
            notes.append(tx("The slopes of the covariate differ between groups (group × covariate p < 0.05): the adjusted comparison assumes equal slopes and should be interpreted with caution.",
                            "各组协变量的斜率不同（组 × 协变量 p < 0.05）：校正后的比较假设斜率相同，解释时需谨慎。"))
        }
        if let cg = oneWayANOVA(groups.map { g in used.filter { $0.group == g }.map(\.covariate) })?.test, cg.p < 0.05 {
            notes.append(tx("The covariate itself differs between groups (one-way ANOVA p < 0.05). If the treatment changed the covariate, adjusting for it can remove part of the real effect.",
                            "协变量本身在组间不同（单因素方差分析 p < 0.05）。如果处理改变了协变量，校正可能去掉一部分真实效应。"))
        }
        if input.count > used.count {
            notes.append(String(format: tx("%d animal(s) in groups with fewer than 2 animals were left out of the ANCOVA.", "%d 只动物所在的组少于 2 只，未纳入 ANCOVA。"),
                                input.count - used.count))
        }
        let summary = String(format: tx("One-way ANCOVA with %@ as the covariate (centered at its mean, %@); Type III tests; adjusted means at the covariate mean, pairwise differences Holm-corrected. Homogeneity of slopes was checked with the group × covariate interaction.",
                                        "以 %@ 为协变量的单因素 ANCOVA（以其均值 %@ 为中心）；Type III 检验；校正均值取协变量均值处，两两差异做 Holm 校正。斜率齐性用 组 × 协变量 交互作用检验。"),
                             covariateName, StatsFormat.number(cm))
        return ANCOVAReport(covariateKey: covariateKey, covariateName: covariateName, covariateMean: cm, group: groupTerm, covariate: covTerm,
                            dfError: dfE, slope: slope, slopeSE: slopeSE, slopes: slopes, adjusted: adjusted, pairwise: pairs,
                            residuals: full.residuals, animals: n, notes: notes, methodSummary: summary)
    }
}
