// AnalyzersGroup.swift — several mice in one arena (3–10): group structure, interactions and a dominance hierarchy.
//
// Everything is measured in body lengths (BL), so it needs no calibration: L is the median nose → tail-base distance of
// all mice in the video.
//
//   contact           the bodies (nose–neck–center–tail polylines) of two mice are within 0.35 BL
//   group             a connected set of mice in contact (Live Mouse Tracker, de Chaumont et al. 2019)
//   approach–avoid    over a 0.4 s velocity window, mouse a moves toward its nearest neighbour b ahead of it (cos > 0.8), b
//                     moves away along the same line (cos > 0.5), 0.3–2.5 BL apart, both above 0.6 BL/s (rule of a
//                     long-term rat tracking study, arXiv 2408.08945, scaled to body lengths), lasting ≥ 0.4 s
//   chase             an approach–avoid event at higher speed (the resident–intruder chase rule: a > 2.7, b > 2 BL/s)
//   hierarchy         a beat b once per approach–avoid event (GroupHierarchy.swift)
//
// Contact, nearest-neighbour distance, spread and group sizes hardly change when identities swap (a swap moves no mouse).
// Distance travelled and the nose measures are somewhat sensitive, because a swap looks like a jump to the smoothing; the
// rest per identity depends on identities directly, and those measures are labelled accordingly in the report.

import Foundation

extension ColorKey {
    /// Colour of animal `i` in a group (the first two are the A / B colours).
    static func groupAnimal(_ i: Int) -> ColorKey {
        let all: [ColorKey] = [.animalA, .animalB, .animalC, .animalD, .animalE, .animalF, .animalG, .animalH, .animalI, .animalJ]
        return all[abs(i) % all.count]
    }
}

enum GroupAnalyzers {
    /// One approach–avoid event: `winner` approached, `loser` moved away.
    struct Event {
        var start: Double
        var end: Double
        var winner: Int
        var loser: Int
        var chase: Bool
    }

    /// Median nose → tail-base distance of all animals, arena units.
    static func bodyLength(_ c: AnalysisContext) -> Double? {
        var v: [Double] = []
        let step = max(1, c.n / 3000)
        for f in c.fs.animals {
            var i = 0
            while i < c.n {
                if c.tb.inWindow[i], let a = f.pos(.nose, i), let b = f.pos(.tailBase, i) { v.append(a.distance(to: b)) }
                i += step
            }
        }
        guard v.count >= 10 else { return nil }
        v.sort()
        return v[v.count / 2]
    }

    private static func polyline(_ f: AnimalFeatures, _ i: Int) -> [V2] {
        [f.pos(.nose, i), f.pos(.neck, i), f.pos(.bodyCenter, i), f.pos(.tailBase, i)].compactMap { $0 }
    }

    /// Smallest distance between two polylines, from their points to the other's segments.
    private static func polylineDistance(_ a: [V2], _ b: [V2]) -> Double {
        var d = Double.infinity
        func consider(_ p: [V2], _ q: [V2]) {
            for x in p {
                if q.count == 1 { d = min(d, x.distance(to: q[0])) }
                for s in 0..<max(0, q.count - 1) { d = min(d, pointSegment(x, q[s], q[s + 1]).distance) }
            }
        }
        consider(a, b)
        consider(b, a)
        return d
    }

    static func animalName(_ i: Int) -> String { String(i + 1) }

    static func analyze(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let tb = c.tb, p = c.p, n = c.n
        let animals = c.fs.animals
        let m = animals.count
        guard m >= 2 else {
            r.warnings.append(L10n.tr("此会话只识别了一只鼠，无法计算群体指标。"))
            r.metrics = c.locomotionMetrics()
            r.blocks = [c.trajectoryBlock()]
            return r
        }
        guard let L = bodyLength(c), L > 0 else {
            r.warnings.append(L10n.tr("分析时间段内关键点太少，无法估计体长，群体指标无法计算。"))
            r.blocks = [c.trajectoryBlock()]
            return r
        }
        let centers: [[V2?]] = animals.map { f in (0..<n).map { AggressionAnalyzers.center(f, $0) } }
        // Velocity over a 0.4 s window (± 0.2 s).
        let k = max(1, Int((0.2 / tb.dt).rounded()))
        // A longer span is allowed so that low frame rates and skipped frames still give a velocity.
        let velocity = animals.map { AggressionAnalyzers.velocity($0, t: tb.t, k: k, maxSpan: 1.0) }

        // MARK: Frame by frame

        var pairs: [(a: Int, b: Int)] = []
        for a in 0..<m { for b in (a + 1)..<m { pairs.append((a, b)) } }
        var contact = [[Bool]](repeating: [Bool](repeating: false, count: n), count: pairs.count)
        var overlap = contact
        let contactDist = p.groupContactBL * L, noseDist = p.groupNoseBL * L
        var nndSum = [Double](repeating: .nan, count: n), spread = nndSum, largest = nndSum, groupCount = nndSum
        var movingFraction = nndSum, contactFraction = nndSum
        var nndAnimal = [[Double]](repeating: [Double](repeating: .nan, count: n), count: m)
        var contactAnimal = [[Bool]](repeating: [Bool](repeating: false, count: n), count: m)
        var noseNose = [Int](repeating: 0, count: n), noseTail = noseNose, detected = noseNose
        var together = [Bool](repeating: false, count: n)
        let moveThreshold = 0.25   // BL/s, about 2 cm/s
        var parent = [Int](repeating: 0, count: m)
        func root(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }

        for i in 0..<n where tb.inWindow[i] {
            let here = (0..<m).filter { centers[$0][i] != nil }
            detected[i] = (0..<m).filter { animals[$0].detected[i] }.count
            guard here.count >= 2 else { continue }
            for a in 0..<m { parent[a] = a }
            var nearest = [Double](repeating: .infinity, count: m)
            for (q, pair) in pairs.enumerated() {
                let (a, b) = pair
                guard let ca = centers[a][i], let cb = centers[b][i] else { continue }
                let d = ca.distance(to: cb)
                nearest[a] = min(nearest[a], d)
                nearest[b] = min(nearest[b], d)
                if d < 0.5 * L { overlap[q][i] = true }
                // A nose is about 0.65 body lengths ahead of the body center; a stretched mouse a little more.
                if d < 2 * L {
                    let touching = polylineDistance(polyline(animals[a], i), polyline(animals[b], i)) < contactDist
                    if touching {
                        contact[q][i] = true
                        contactAnimal[a][i] = true
                        contactAnimal[b][i] = true
                        parent[root(a)] = root(b)
                    }
                    if let na = animals[a].pos(.nose, i), let nb = animals[b].pos(.nose, i), na.distance(to: nb) < noseDist { noseNose[i] += 1 }
                    if let na = animals[a].pos(.nose, i), let tb2 = animals[b].pos(.tailBase, i), na.distance(to: tb2) < noseDist { noseTail[i] += 1 }
                    if let nb = animals[b].pos(.nose, i), let ta = animals[a].pos(.tailBase, i), nb.distance(to: ta) < noseDist { noseTail[i] += 1 }
                }
            }
            var size = [Int: Int]()
            for a in here { size[root(a), default: 0] += 1 }
            largest[i] = Double(size.values.max() ?? 1)
            groupCount[i] = Double(size.count)
            together[i] = here.count == m && size.count == 1
            var nnd = 0.0, moving = 0, inContact = 0
            var sx = 0.0, sy = 0.0
            for a in here {
                nndAnimal[a][i] = nearest[a]
                nnd += nearest[a]
                let q = centers[a][i]!
                sx += q.x
                sy += q.y
                if let v = velocity[a][i], v.length / L > moveThreshold { moving += 1 }
                if contactAnimal[a][i] { inContact += 1 }
            }
            let count = Double(here.count)
            nndSum[i] = nnd / count
            let mid = V2(sx / count, sy / count)
            spread[i] = here.reduce(0.0) { $0 + centers[$1][i]!.distance(to: mid) } / count
            movingFraction[i] = Double(moving) / count
            contactFraction[i] = Double(inContact) / count
        }

        // MARK: Approach–avoid events

        var approachRaw: [Int: [Bool]] = [:]
        var chaseRaw: [Int: [Bool]] = [:]
        let empty = [Bool](repeating: false, count: n)
        for i in 0..<n where tb.inWindow[i] {
            for a in 0..<m {
                guard let va = velocity[a][i], va.length / L > p.groupApproachSpeed, let ca = centers[a][i] else { continue }
                // The mouse it is heading for: the nearest one in the direction it moves.
                var target = -1
                var targetDistance = Double.infinity
                for b in 0..<m where b != a {
                    guard let cb = centers[b][i] else { continue }
                    let u = cb - ca
                    let d = u.length / L
                    guard d > 0.3, d < p.groupApproachDist, (AggressionAnalyzers.cosine(va, u) ?? 0) > 0.8 else { continue }
                    if d < targetDistance {
                        targetDistance = d
                        target = b
                    }
                }
                guard target >= 0, let vb = velocity[target][i], vb.length / L > p.groupApproachSpeed,
                      let cb = centers[target][i], (AggressionAnalyzers.cosine(vb, cb - ca) ?? 0) > 0.5 else { continue }
                approachRaw[a * m + target, default: empty][i] = true
                if va.length / L > p.groupChaseSpeed && vb.length / L > 0.75 * p.groupChaseSpeed {
                    chaseRaw[a * m + target, default: empty][i] = true
                }
            }
        }
        var events: [Event] = []
        var chaseSeconds = 0.0
        for key in approachRaw.keys.sorted() {
            let bouts = Bouts.find(Bouts.sustained(approachRaw[key]!, tb, minDuration: p.groupApproachMin, mergeGap: 0.25), tb)
            let chase = chaseRaw[key].map { Bouts.sustained($0, tb, minDuration: p.groupChaseMin, mergeGap: 0.25) } ?? empty
            chaseSeconds += tb.total(chase)
            for b in bouts {
                events.append(Event(start: b.start, end: b.end, winner: key / m, loser: key % m,
                                    chase: (b.i0...min(b.i1, n - 1)).contains { chase[$0] }))
            }
        }
        events.sort { $0.start < $1.start }
        let dominance = DominanceMath.summary(animals: m, events: events.map { (winner: $0.winner, loser: $0.loser) })
        let chases = events.filter(\.chase)

        // MARK: Numbers

        let win = max(tb.windowDuration, 1e-9)
        let minutes = win / 60
        var groupSeconds = [Double](repeating: 0, count: m + 1)
        for i in 0..<n where tb.inWindow[i] && largest[i].isFinite { groupSeconds[Int(largest[i])] += tb.dur[i] }
        let measured = max(groupSeconds.reduce(0, +), 1e-9)
        var complete = 0.0, frames = 0.0
        for i in 0..<n where tb.inWindow[i] {
            frames += 1
            if detected[i] == m { complete += 1 }
        }
        let completeFraction = frames > 0 ? complete / frames : 0
        var contactBouts = 0, risky = 0
        for q in pairs.indices {
            contactBouts += Bouts.find(contact[q], tb, minDuration: 0.2, mergeGap: 0.3).count
            risky += Bouts.find(overlap[q], tb, minDuration: 0.2, mergeGap: 0.3).count
        }
        func pairSeconds(_ count: [Int]) -> Double {
            var s = 0.0
            for i in 0..<n where tb.inWindow[i] { s += Double(count[i]) * tb.dur[i] }
            return s
        }
        let distances = (0..<m).map { c.distance(animal: $0) }
        let meanDistance = distances.reduce(0, +) / Double(m)
        let distMetric = c.fs.isMetric ? c.m("distance_mean", L10n.tr("每只鼠平均路程"), meanDistance / 100, "m", 2)
                                       : c.m("distance_mean", L10n.tr("每只鼠平均路程"), meanDistance, "px", 0)
        r.metrics = [
            c.m("contact_pct", L10n.tr("接触比例"), c.mean(contactFraction).map { $0 * 100 }, "%", 1,
                info: L10n.tr("每只鼠身体与至少一只其他鼠接触的时间比例（各鼠平均）；不依赖个体身份")),
            c.m("isolated_pct", L10n.tr("独处比例"), c.mean(contactFraction).map { 100 - $0 * 100 }, "%", 1, info: L10n.tr("不与任何鼠接触的时间比例（各鼠平均）；不依赖个体身份")),
            c.m("mean_nnd", L10n.tr("最近邻距离"), c.mean(nndSum), c.u, 1, info: L10n.tr("每只鼠到最近一只鼠的身体中心距离的平均；不依赖个体身份")),
            c.m("spread", L10n.tr("群体分散度"), c.mean(spread), c.u, 1, info: L10n.tr("各鼠到群体重心的平均距离；不依赖个体身份")),
            c.m("largest_group", L10n.tr("最大聚集团大小"), c.mean(largest), L10n.tr("只"), 2, info: L10n.tr("每帧最大的接触团（互相接触连成一片的鼠）的只数的平均")),
            c.m("all_together_pct", L10n.tr("全部聚在一起"), c.percent(tb.total(together), win), "%", 1, info: L10n.tr("所有鼠连成一个接触团的时间比例")),
            c.m("moving_pct", L10n.tr("活动比例"), c.mean(movingFraction).map { $0 * 100 }, "%", 1, info: L10n.tr("速度 > 0.25 体长/s 的鼠所占比例的平均")),
            distMetric,
            c.m("contact_rate", L10n.tr("接触次数"), Double(contactBouts) / minutes, L10n.tr("次/分钟"), 1, info: L10n.tr("所有成对组合的身体接触次数（持续 ≥ 0.2 s）")),
            c.m("nose_nose_s", L10n.tr("鼻–鼻接触"), pairSeconds(noseNose), "s", 1, info: L10n.tr("所有成对组合的累计时间")),
            c.m("nose_ano_s", L10n.tr("肛殖区嗅探"), pairSeconds(noseTail), "s", 1, info: L10n.tr("所有成对组合的累计时间")),
            c.m("approach_rate", L10n.tr("接近–回避事件"), Double(events.count) / minutes, L10n.tr("次/分钟"), 1, info: L10n.tr("一只鼠朝最近的鼠移动、对方同方向离开")),
            c.m("chase_rate", L10n.tr("追逐事件"), Double(chases.count) / minutes, L10n.tr("次/分钟"), 1, info: L10n.tr("速度更快的接近–回避事件")),
            c.m("chase_seconds", L10n.tr("追逐总时长"), chaseSeconds, "s", 1),
            c.m("interactions_per_animal", L10n.tr("每只鼠的事件数"), dominance.interactionsPerAnimal, "", 1,
                info: L10n.tr("等级所用事件数 ÷ 只数；文献建议至少 10，最好 20")).withReference(10, L10n.tr("建议 ≥ 10")),
            c.m("dyads_observed_pct", L10n.tr("有事件的鼠对"), dominance.dyadsObserved * 100, "%", 0, info: L10n.tr("至少有一次接近–回避事件的鼠对占全部鼠对的比例")),
            c.m("landau_h", L10n.tr("线性度 h′"), dominance.events > 0 ? dominance.landauH : nil, "", 2, info: L10n.tr("Landau h′（de Vries 1995）；1 = 完全线性。依赖个体身份")),
            c.m("transitivity", L10n.tr("三角传递性 Ttri"), dominance.transitivity, "", 2, info: L10n.tr("Shizuka & McDonald 2012；依赖个体身份")),
            c.m("directional_consistency", L10n.tr("方向一致性"), dominance.directionalConsistency, "", 2, info: L10n.tr("每对鼠中事件方向一致的程度；依赖个体身份")),
            c.m("steepness", L10n.tr("陡度"), dominance.events > 0 ? dominance.steepness : nil, "", 2, info: L10n.tr("标准化 David's score 对名次的斜率；依赖个体身份")),
            c.m("split_half", L10n.tr("前后半一致性"), dominance.splitHalf, "", 2, info: L10n.tr("前一半和后一半事件各算一次 David's score 的 Spearman 相关；身份互换越多，这个值越低")),
            c.m("identity_risk", L10n.tr("身份风险事件"), Double(risky), "", 0, info: L10n.tr("两鼠身体中心贴近（< 0.5 体长）的次数；编号可能在这些时刻互换")),
            c.m("all_detected_pct", L10n.tr("全部检出的帧"), completeFraction * 100, "%", 1)
        ]

        // MARK: Blocks

        let paths = (0..<m).map { PlotPath(color: .groupAnimal($0), segments: c.segments(animal: $0), width: 1, opacity: 0.7) }
        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("每种颜色是一个编号，编号可能在贴身时互换"), paths: paths))
        let bars = (1...m).map { size in
            BarItem(label: String(size), value: groupSeconds[size] / measured * 100, color: size == m ? .accent : .neutral)
        }
        r.blocks.append(ReportBlock(title: L10n.tr("最大聚集团大小的分布"), caption: L10n.tr("横轴：最大接触团的只数；纵轴：时间比例"), kind: .bars(BarData(items: bars, unit: "%"))))

        // Hierarchy: rows sorted by rank.
        let order = (0..<m).sorted { dominance.rank[$0] != dominance.rank[$1] ? dominance.rank[$0] < dominance.rank[$1] : $0 < $1 }
        let cells: [[String]] = order.map { a in
            let contactSeconds = tb.total(contactAnimal[a])
            let nnd = c.mean(nndAnimal[a])
            return [String(dominance.rank[a]), animalName(a), String(format: "%.2f", dominance.normalizedDS[a]), String(format: "%.0f", dominance.elo[a]),
                    String(dominance.totalWins[a]), String(dominance.totalLosses[a]), String(format: "%.0f", contactSeconds / win * 100),
                    nnd.map { String(format: "%.1f", $0) } ?? "—", c.fs.isMetric ? String(format: "%.1f", distances[a] / 100) : String(format: "%.0f", distances[a])]
        }
        r.blocks.append(ReportBlock(title: L10n.tr("等级（预览）"), caption: L10n.tr("编号按接近–回避事件排序：胜 = 接近对方且对方离开。编号不对应具体动物，且可能在贴身时互换"),
                                    kind: .table(TableData(columns: [L10n.tr("名次"), "ID", "NormDS", "Elo", L10n.tr("胜"), L10n.tr("负"), L10n.tr("接触 %"), "NND (\(c.u))", c.fs.isMetric ? L10n.tr("路程 (m)") : L10n.tr("路程 (px)")],
                                                           rows: cells))))
        let matrixRows: [[String]] = order.map { a in [animalName(a)] + order.map { b in a == b ? "—" : String(dominance.wins[a][b]) } }
        r.blocks.append(ReportBlock(title: L10n.tr("胜负矩阵"), caption: L10n.tr("行赢列的次数（按名次排列）"),
                                    kind: .table(TableData(columns: [L10n.tr("胜 \\ 负")] + order.map(animalName), rows: matrixRows))))
        var pairContact = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for (q, pair) in pairs.enumerated() {
            let v = tb.total(contact[q]) / win * 100
            pairContact[pair.a][pair.b] = v
            pairContact[pair.b][pair.a] = v
        }
        let associationRows: [[String]] = (0..<m).map { a in [animalName(a)] + (0..<m).map { b in a == b ? "—" : String(format: "%.0f", pairContact[a][b]) } }
        r.blocks.append(ReportBlock(title: L10n.tr("成对接触（%）"), caption: L10n.tr("每对编号接触的时间比例；依赖个体身份"),
                                    kind: .table(TableData(columns: ["ID"] + (0..<m).map(animalName), rows: associationRows))))

        // Time courses.
        var contactLine: [LinePoint] = [], nndLine: [LinePoint] = [], eventLine: [LinePoint] = []
        for b in c.courseBins(p.timeBin) {
            let range = tb.indices(from: b.start, to: b.end).filter { tb.inWindow[$0] }
            guard !range.isEmpty else { continue }
            func average(_ s: [Double]) -> Double? {
                let v = range.map { s[$0] }.filter(\.isFinite)
                return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
            }
            if let v = average(contactFraction) { contactLine.append(LinePoint(x: b.x, y: v * 100)) }
            if let v = average(nndSum) { nndLine.append(LinePoint(x: b.x, y: v)) }
            eventLine.append(LinePoint(x: b.x, y: Double(events.filter { $0.start >= b.start && $0.start < b.end }.count)))
        }
        if contactLine.count > 1 {
            r.blocks.append(ReportBlock(title: L10n.tr("接触比例的时间进程"), caption: nil,
                                        kind: .line(LineData(series: [LineSeries(name: L10n.tr("接触"), color: .social, points: contactLine)], xLabel: "min", yLabel: "%"))))
            r.series.append(FlowResultSeries(key: "contact_pct_bin", name: "Contact", unit: "%", xLabel: TimeCourseLabel.english(bin: max(p.timeBin, 1)),
                                             x: contactLine.map(\.x), y: contactLine.map(\.y)))
        }
        if nndLine.count > 1 {
            r.blocks.append(ReportBlock(title: L10n.tr("最近邻距离的时间进程"), caption: nil,
                                        kind: .line(LineData(series: [LineSeries(name: L10n.tr("最近邻距离"), color: .accent, points: nndLine)], xLabel: "min", yLabel: c.u))))
            r.series.append(FlowResultSeries(key: "mean_nnd_bin", name: "Nearest-neighbour distance", unit: c.u, xLabel: TimeCourseLabel.english(bin: max(p.timeBin, 1)),
                                             x: nndLine.map(\.x), y: nndLine.map(\.y)))
        }
        if eventLine.count > 1 {
            r.series.append(FlowResultSeries(key: "approach_events_bin", name: "Approach–avoid events", unit: "events", xLabel: TimeCourseLabel.english(bin: max(p.timeBin, 1)),
                                             x: eventLine.map(\.x), y: eventLine.map(\.y)))
        }

        let toBout: (Event) -> Bout = { e in Bout(start: e.start, end: e.end, i0: tb.index(atOrAfter: e.start), i1: max(0, tb.index(atOrAfter: e.end) - 1)) }
        var risk = [Bool](repeating: false, count: n)
        for q in pairs.indices { for i in 0..<n where overlap[q][i] { risk[i] = true } }
        let tracks = [
            TimelineTrack(name: L10n.tr("接近–回避"), color: .follow, bouts: events.map(toBout)),
            TimelineTrack(name: L10n.tr("追逐"), color: .chase, bouts: chases.map(toBout)),
            TimelineTrack(name: L10n.tr("全部聚在一起"), color: .social, bouts: Bouts.find(together, tb, minDuration: 0.5, mergeGap: 0.5))
        ]
        r.blocks.append(ReportBlock(title: L10n.tr("行为时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks + [TimelineTrack(name: L10n.tr("身份风险"), color: .neutral, bouts: Bouts.find(risk, tb, minDuration: 0.2, mergeGap: 0.3), style: .flag)]

        r.frameColumns = [("n_detected", detected.map(Double.init)), ("n_groups", groupCount), ("largest_group", largest), ("mean_nnd", nndSum), ("group_spread", spread),
                          ("fraction_moving", movingFraction), ("fraction_in_contact", contactFraction), ("all_together", AnalysisContext.flag(together))]

        // Per-animal and event tables for the JSON export (identities are arbitrary, so not cross-session metrics).
        r.exportTables["group_ranks"] = [["rank", "id", "norm_david_score", "david_score", "elo", "wins", "losses"]]
            + order.map { a in [String(dominance.rank[a]), animalName(a), String(format: "%.4f", dominance.normalizedDS[a]), String(format: "%.4f", dominance.davidScore[a]),
                                String(format: "%.1f", dominance.elo[a]), String(dominance.totalWins[a]), String(dominance.totalLosses[a])] }
        r.exportTables["group_win_matrix"] = [["winner_row_loser_column"] + (0..<m).map(animalName)]
            + (0..<m).map { a in [animalName(a)] + (0..<m).map { b in String(dominance.wins[a][b]) } }
        r.exportTables["group_contact_pct_matrix"] = [["id"] + (0..<m).map(animalName)]
            + (0..<m).map { a in [animalName(a)] + (0..<m).map { b in String(format: "%.2f", pairContact[a][b]) } }
        r.exportTables["group_events"] = [["start_s", "end_s", "approacher_id", "avoider_id", "is_chase"]]
            + events.map { [String(format: "%.3f", $0.start), String(format: "%.3f", $0.end), animalName($0.winner), animalName($0.loser), $0.chase ? "1" : "0"] }

        // MARK: Warnings and methods

        if completeFraction < 0.8 {
            r.warnings.append(String(format: L10n.tr("只有 %.0f%% 的帧检出了全部 %d 只鼠：指标可能偏差较大，请在回看中确认。"), completeFraction * 100, m))
        }
        if dominance.events == 0 {
            r.warnings.append(L10n.tr("没有检出接近–回避事件，等级无法计算。"))
        } else if dominance.interactionsPerAnimal < 10 {
            r.warnings.append(String(format: L10n.tr("每只鼠只有 %.1f 个事件（文献建议至少 10，最好 20），等级不可靠。可以延长录像。"), dominance.interactionsPerAnimal))
        }
        if let h = dominance.splitHalf, h < 0.5 {
            r.warnings.append(String(format: L10n.tr("前后半段的等级一致性只有 %.2f：可能是编号互换，也可能是等级在变化。"), h))
        }
        if tb.dt > 0.2 {
            r.warnings.append(L10n.tr("采样间隔大于 0.2 s，接近–回避事件的方向和时长不准确。"))
        }
        if c.session.usedInference?.stride ?? c.session.inference.stride > 1 {
            r.warnings.append(L10n.tr("抽帧会让接近–回避事件漏检，也更容易丢失身份，建议逐帧识别。"))
        }
        r.notes.append(L10n.tr("等级和“编号”相关的结果是预览：没有物理标记时，贴身接触会让编号互换，并且会累积（在 7–10 只鼠的验证视频中，大约每 1–3 分钟有一对鼠的编号互换）。编号也不对应具体动物。群体层面的指标（接触、最近邻距离、聚集团）基本不受影响。"))
        r.methods.append(L10n.tr("多只小鼠由多鼠姿态模型逐帧检测，合并重复检测（鼻尖和尾根的平均距离 < 0.25 体长）后，按已知只数做身份匹配：用 5 个直接预测的关键点和匀速预测进行匈牙利匹配，丢失的鼠继续保留、匹配门限随丢失帧数放宽，不新建编号。"))
        r.methods.append(String(format: L10n.tr("距离和速度以体长（BL，所有鼠鼻尖到尾根距离的中位数，本视频 %@ %@）为单位。接触：两鼠身体（鼻尖–颈–身体中心–尾根折线）的最短距离 < %@ BL；聚集团为互相接触连成一片的鼠（de Chaumont et al., 2019）。"), AnalysisContext.num((L * 10).rounded() / 10), c.u, AnalysisContext.num(p.groupContactBL)))
        r.methods.append(String(format: L10n.tr("接近–回避事件：0.4 s 窗口的速度下，一只鼠朝最近的鼠移动（余弦 > 0.8），对方沿同方向离开（余弦 > 0.5），间距 0.3–%@ BL，两鼠速度 > %@ BL/s，持续 ≥ %@ s。规则来自大鼠长期追踪研究（2408.08945），按体长换算，未在小鼠上用人工评分验证。"), AnalysisContext.num(p.groupApproachDist), AnalysisContext.num(p.groupApproachSpeed), AnalysisContext.num(p.groupApproachMin)))
        r.methods.append(L10n.tr("等级：接近者记一次胜。David's score 用 Dij 校正（Gammell et al., 2003），Elo 从 1000 开始、k = 100（Neumann et al., 2011），线性度为 Landau h′（de Vries, 1995），传递性为 Ttri（Shizuka & McDonald, 2012）。"))
        return r
    }
}
