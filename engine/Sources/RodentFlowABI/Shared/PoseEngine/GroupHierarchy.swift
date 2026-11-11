// GroupHierarchy.swift — dominance hierarchy from a win / loss matrix. Pure arithmetic, tested against HierarchiaPy
// (tools/tests/GroupBehaviorTest.swift).
//
// wins[i][j] = how many interactions animal i won against animal j.
//
//   David's score with Dij (Gammell et al. 2003; de Vries et al. 2006); normalized DS = (DS + N(N−1)/2) / N, range 0…N−1.
//   Elo rating (Neumann et al. 2011): start 1000, k = 100, in time order.
//   Landau's h′ (de Vries 1995): tied and unknown dyads count ½ each way, plus the expected correction for unknown dyads.
//   Triangle transitivity (Shizuka & McDonald 2012): 4 (Pt − 0.75); only triads with three decided dyads.
//   Directional consistency (van Hooff & Wensing 1987).
//   Steepness: slope of normalized DS on rank (de Vries et al. 2006).

import Foundation

struct DominanceSummary {
    var animals: Int
    var wins: [[Int]]
    var davidScore: [Double]
    var normalizedDS: [Double]
    var elo: [Double]
    /// 1 = highest normalized DS. Ties share the best rank.
    var rank: [Int]
    var totalWins: [Int]
    var totalLosses: [Int]
    var events: Int
    /// Fraction of the N(N−1)/2 dyads with at least one interaction (0…1).
    var dyadsObserved: Double
    var landauH: Double
    var transitivity: Double?
    var directionalConsistency: Double?
    var steepness: Double?
    /// Spearman correlation of David's scores from the first and second half of the events; nil with too few events.
    var splitHalf: Double?
    var interactionsPerAnimal: Double { animals > 0 ? Double(events) / Double(animals) : 0 }
}

enum DominanceMath {
    /// David's score with Dij.
    static func davidsScores(_ w: [[Int]]) -> [Double] {
        let n = w.count
        var D = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0..<n where i != j {
                let t = w[i][j] + w[j][i]
                guard t > 0 else { continue }
                let p = Double(w[i][j]) / Double(t)
                D[i][j] = p - (p - 0.5) / Double(t + 1)
            }
        }
        let wn = (0..<n).map { i in (0..<n).reduce(0.0) { $0 + D[i][$1] } }
        let ln = (0..<n).map { i in (0..<n).reduce(0.0) { $0 + D[$1][i] } }
        return (0..<n).map { i in
            var w2 = 0.0, l2 = 0.0
            for j in 0..<n where j != i {
                w2 += D[i][j] * wn[j]
                l2 += D[j][i] * ln[j]
            }
            return wn[i] + w2 - ln[i] - l2
        }
    }

    static func normalize(_ ds: [Double]) -> [Double] {
        let n = Double(ds.count)
        return ds.map { ($0 + n * (n - 1) / 2) / n }
    }

    /// Landau's h′.
    static func landau(_ w: [[Int]]) -> Double {
        let n = w.count
        guard n > 2 else { return 0 }
        var v = [Double](repeating: 0, count: n)
        var open = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                if w[i][j] > w[j][i] {
                    v[i] += 1
                } else if w[j][i] > w[i][j] {
                    v[j] += 1
                } else {
                    v[i] += 0.5
                    v[j] += 0.5
                    if w[i][j] == 0 { open += 1 }
                }
            }
        }
        let N = Double(n)
        let h = 12 / (N * N * N - N) * v.reduce(0) { $0 + ($1 - (N - 1) / 2) * ($1 - (N - 1) / 2) }
        return h + 6 / (N * N * N - N) * Double(open)
    }

    /// Triangle transitivity; nil when no triad has three decided dyads.
    static func triangleTransitivity(_ w: [[Int]]) -> Double? {
        let n = w.count
        guard n >= 3 else { return nil }
        func dir(_ i: Int, _ j: Int) -> Bool? {
            if w[i][j] > w[j][i] { return true }
            if w[j][i] > w[i][j] { return false }
            return nil
        }
        var transitive = 0, cyclic = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    guard let ij = dir(i, j), let jk = dir(j, k), let ik = dir(i, k) else { continue }
                    // i→j→k→i (or the reverse) is the only cyclic pattern.
                    if ij == jk && ij != ik { cyclic += 1 } else { transitive += 1 }
                }
            }
        }
        guard transitive + cyclic > 0 else { return nil }
        return 4 * (Double(transitive) / Double(transitive + cyclic) - 0.75)
    }

    static func directionalConsistency(_ w: [[Int]]) -> Double? {
        let n = w.count
        var high = 0, low = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                high += max(w[i][j], w[j][i])
                low += min(w[i][j], w[j][i])
            }
        }
        return high + low > 0 ? Double(high - low) / Double(high + low) : nil
    }

    /// Absolute slope of normalized DS on rank.
    static func steepness(_ normDS: [Double]) -> Double? {
        guard normDS.count >= 2 else { return nil }
        let y = normDS.sorted(by: >)
        let n = Double(y.count)
        let meanX = (n + 1) / 2, meanY = y.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for (i, v) in y.enumerated() {
            let dx = Double(i + 1) - meanX
            sxy += dx * (v - meanY)
            sxx += dx * dx
        }
        return sxx > 0 ? abs(sxy / sxx) : nil
    }

    /// Elo ratings after the events in order (winner, loser).
    static func elo(animals n: Int, events: [(winner: Int, loser: Int)], start: Double = 1000, k: Double = 100) -> [Double] {
        var r = [Double](repeating: start, count: n)
        for e in events {
            let expected = 1 / (1 + pow(10, (r[e.loser] - r[e.winner]) / 400))
            let change = k * (1 - expected)
            r[e.winner] += change
            r[e.loser] -= change
        }
        return r
    }

    /// Spearman correlation (average ranks for ties); nil when either side has no variance.
    static func spearman(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count >= 3 else { return nil }
        func ranks(_ v: [Double]) -> [Double] {
            let order = v.indices.sorted { v[$0] < v[$1] }
            var out = [Double](repeating: 0, count: v.count)
            var i = 0
            while i < order.count {
                var j = i
                while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
                let r = Double(i + j) / 2 + 1
                for q in i...j { out[order[q]] = r }
                i = j + 1
            }
            return out
        }
        let ra = ranks(a), rb = ranks(b)
        let ma = ra.reduce(0, +) / Double(ra.count), mb = rb.reduce(0, +) / Double(rb.count)
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in ra.indices {
            sab += (ra[i] - ma) * (rb[i] - mb)
            saa += (ra[i] - ma) * (ra[i] - ma)
            sbb += (rb[i] - mb) * (rb[i] - mb)
        }
        return saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : nil
    }

    private static func matrix(animals n: Int, events: ArraySlice<(winner: Int, loser: Int)>) -> [[Int]] {
        var w = [[Int]](repeating: [Int](repeating: 0, count: n), count: n)
        for e in events { w[e.winner][e.loser] += 1 }
        return w
    }

    /// Everything the report needs from the events, in time order.
    static func summary(animals n: Int, events: [(winner: Int, loser: Int)]) -> DominanceSummary {
        let w = matrix(animals: n, events: events[...])
        let ds = davidsScores(w)
        let norm = normalize(ds)
        let totalWins = w.map { $0.reduce(0, +) }
        let totalLosses = (0..<n).map { j in w.reduce(0) { $0 + $1[j] } }
        let order = (0..<n).sorted { norm[$0] > norm[$1] }
        var rank = [Int](repeating: 0, count: n)
        for (i, a) in order.enumerated() {
            rank[a] = i > 0 && abs(norm[a] - norm[order[i - 1]]) < 1e-9 ? rank[order[i - 1]] : i + 1
        }
        var observed = 0
        for i in 0..<n {
            for j in (i + 1)..<n where w[i][j] + w[j][i] > 0 { observed += 1 }
        }
        let dyads = n * (n - 1) / 2
        var half: Double?
        // At least five interactions per half, or the correlation means nothing.
        if events.count >= 10 {
            let mid = events.count / 2
            half = spearman(davidsScores(matrix(animals: n, events: events[..<mid])),
                            davidsScores(matrix(animals: n, events: events[mid...])))
        }
        return DominanceSummary(animals: n, wins: w, davidScore: ds, normalizedDS: norm, elo: elo(animals: n, events: events), rank: rank,
                                totalWins: totalWins, totalLosses: totalLosses, events: events.count,
                                dyadsObserved: dyads > 0 ? Double(observed) / Double(dyads) : 0, landauH: landau(w),
                                transitivity: triangleTransitivity(w), directionalConsistency: directionalConsistency(w),
                                steepness: steepness(norm), splitHalf: half)
    }
}
