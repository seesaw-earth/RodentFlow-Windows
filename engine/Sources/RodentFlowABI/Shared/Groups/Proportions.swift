// Proportions.swift — 0/1 measures between groups (RodentFlow 2.1): the first choice in the visual cliff, whether an
// animal stepped down, entered the dark side, ate, attacked… Each animal is 0 or 1 (stored as 0 / 100 %), so the
// groups are compared as proportions: Fisher's exact test for two groups, a chi-square test of independence for more
// followed by pairwise Fisher's exact tests with Holm correction. Since build 23 this is the main analysis of such a
// measure (figure, brackets, legend, Methods); the t / U test of the 0/1 values is kept only as a secondary line.
// Proportions are shown with Wilson score 95% confidence intervals (Wilson 1927; Brown, Cai & DasGupta 2001).

import Foundation

struct ProportionTest: Codable, Hashable {
    struct Row: Codable, Hashable {
        /// Group name in the output language.
        var group: String
        var events: Int
        var animals: Int
        /// Group label as in the result (`GroupAnalysisResult.groups`).
        var key: String = ""
        var proportion: Double { animals > 0 ? Double(events) / Double(animals) : 0 }
        /// Wilson score 95% confidence interval of the proportion (0–1).
        var wilson: (low: Double, high: Double) { ProportionTests.wilson(events, animals) }
    }
    var name: String
    var rows: [Row]
    var p: Double
    /// Chi-square statistic and degrees of freedom (more than two groups).
    var statistic: Double?
    var df: Int?
    /// Some expected counts are below 5 (chi-square only).
    var smallExpected = false
    /// Two groups: the Fisher test itself; more groups: pairwise two-sided Fisher's exact tests, Holm-corrected
    /// (`groupA` / `groupB` = result group labels, difference = percentage points A − B).
    var pairwise: [PairwiseComparison] = []

    var reportLine: String {
        let counts = rows.map { "\($0.group) \($0.events)/\($0.animals)" }.joined(separator: ", ")
        if let statistic, let df {
            return "\(counts); χ²(\(df)) = \(StatsFormat.number(statistic)), \(StatsFormat.p(p))"
        }
        return "\(counts); \(StatsFormat.p(p))"
    }
}

enum ProportionTests {
    /// Measures that are 0 or 100 (attack_occurred: 0 or 1) per animal by definition (an event happened before the
    /// cut-off, a choice). found_target (Barnes) and tst_became_immobile (TST) come with build 23.
    static let binaryKeys: Set<String> = ["stepped_down", "entered_deep", "first_choice_deep", "entered_pct", "ate_pct",
                                         "found_platform_pct", "spatial_strategy_pct", "attack_occurred", "found_target",
                                         "tst_became_immobile"]

    /// Whether a measure gets the proportion test: a known 0/1 measure.
    static func applies(metricKey: String) -> Bool { binaryKeys.contains(metricKey) }

    /// The animal values are all 0 or 1, or all 0 or 100 (and not all equal in every group by construction).
    static func isBinary(_ values: [Double]) -> Bool {
        guard values.count >= 2 else { return false }
        let set = Set(values.map { ($0 * 1000).rounded() / 1000 })
        return set.isSubset(of: [0, 1]) || set.isSubset(of: [0, 100])
    }

    /// Wilson score interval of k events in n animals (95%); (0, 0) for n = 0.
    static func wilson(_ k: Int, _ n: Int, z: Double = 1.959963984540054) -> (low: Double, high: Double) {
        guard n > 0 else { return (0, 0) }
        let nn = Double(n), p = Double(k) / nn, z2 = z * z
        let centre = (p + z2 / (2 * nn)) / (1 + z2 / nn)
        let half = z * (p * (1 - p) / nn + z2 / (4 * nn * nn)).squareRoot() / (1 + z2 / nn)
        // Exactly 0 / 1 at k = 0 / k = n (the closed form; in doubles centre − half is ~1e-17, not 0).
        return (k <= 0 ? 0 : max(0, centre - half), k >= n ? 1 : min(1, centre + half))
    }

    /// Two-sided Fisher's exact test of two rows, as a pairwise comparison (difference in percentage points).
    static func fisherPair(_ x: ProportionTest.Row, _ y: ProportionTest.Row, method: String) -> PairwiseComparison {
        let p = fisherTwoSided(x.events, x.animals - x.events, y.events, y.animals - y.events)
        return PairwiseComparison(groupA: x.key, groupB: y.key, level: nil, difference: (x.proportion - y.proportion) * 100,
                                  statisticName: "", statistic: 0, p: p, pAdjusted: p, method: method)
    }

    /// Fisher's exact test (two groups) or a chi-square test of independence followed by pairwise Fisher's exact
    /// tests with Holm correction (more groups; only each group against the first with `controlOnly`) of 0/1 animal values.
    static func test(points: [SubjectPoint], groups: [String], english: Bool, controlOnly: Bool = false) -> ProportionTest? {
        let values = points.map(\.value)
        guard isBinary(values) else { return nil }
        let rows: [ProportionTest.Row] = groups.compactMap { g in
            let v = points.filter { $0.group == g }.map(\.value)
            guard !v.isEmpty else { return nil }
            return ProportionTest.Row(group: english ? g : groupDisplayName(g), events: v.filter { $0 > 0 }.count, animals: v.count, key: g)
        }
        guard rows.count >= 2 else { return nil }
        // Both outcomes must occur somewhere; otherwise there is nothing to compare.
        let allEvents = rows.reduce(0) { $0 + $1.events }, allAnimals = rows.reduce(0) { $0 + $1.animals }
        guard allEvents > 0, allEvents < allAnimals else { return nil }
        if rows.count == 2 {
            let a = rows[0].events, b = rows[0].animals - a, c = rows[1].events, d = rows[1].animals - c
            var out = ProportionTest(name: "Fisher's exact test", rows: rows, p: fisherTwoSided(a, b, c, d))
            out.pairwise = [fisherPair(rows[0], rows[1], method: "Fisher's exact test")]
            return out
        }
        var pairs: [PairwiseComparison] = []
        for i in 0..<rows.count {
            for j in (i + 1)..<rows.count where !controlOnly || i == 0 {
                pairs.append(fisherPair(rows[i], rows[j], method: "Fisher's exact test (Holm)"))
            }
        }
        let adjusted = Stats.holm(pairs.map(\.p))
        for i in pairs.indices { pairs[i].pAdjusted = adjusted[i] }
        // 2 × k chi-square test of independence.
        let n = Double(rows.reduce(0) { $0 + $1.animals })
        let events = Double(rows.reduce(0) { $0 + $1.events })
        guard n > 0, events > 0, events < n else {
            return ProportionTest(name: "Chi-square test", rows: rows, p: 1, statistic: 0, df: rows.count - 1, pairwise: pairs)
        }
        var chi = 0.0
        var small = false
        for r in rows {
            let e1 = Double(r.animals) * events / n, e0 = Double(r.animals) * (n - events) / n
            if e1 < 5 || e0 < 5 { small = true }
            if e1 > 0 { chi += pow(Double(r.events) - e1, 2) / e1 }
            if e0 > 0 { chi += pow(Double(r.animals - r.events) - e0, 2) / e0 }
        }
        let df = rows.count - 1
        return ProportionTest(name: "Chi-square test", rows: rows, p: Distributions.chiSquareSF(chi, df: Double(df)),
                              statistic: chi, df: df, smallExpected: small, pairwise: pairs)
    }

    /// Two-sided Fisher's exact test of the 2 × 2 table [[a, b], [c, d]]: the sum of the probabilities of all tables
    /// with the same margins that are no more likely than the observed one.
    static func fisherTwoSided(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
        let r1 = a + b, r2 = c + d, c1 = a + c, n = a + b + c + d
        guard n > 0, r1 > 0, r2 > 0, c1 > 0, c1 < n else { return 1 }
        func lnC(_ n: Int, _ k: Int) -> Double {
            SpecialFunctions.lnGamma(Double(n) + 1) - SpecialFunctions.lnGamma(Double(k) + 1) - SpecialFunctions.lnGamma(Double(n - k) + 1)
        }
        let denom = lnC(n, c1)
        func prob(_ x: Int) -> Double { exp(lnC(r1, x) + lnC(r2, c1 - x) - denom) }
        let observed = prob(a)
        var p = 0.0
        for x in max(0, c1 - r2)...min(r1, c1) {
            let px = prob(x)
            if px <= observed * (1 + 1e-7) { p += px }
        }
        return min(1, p)
    }
}
