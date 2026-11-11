// AnalyzersWaterMaze.swift — Morris water maze from pose data (RodentFlow 2.0: iOS build 13, Mac build 12).
//
// The same keypoint tracking as the open field (MousePose6, one animal); only the data processing differs:
//   • acquisition / visible platform / reversal: escape latency (body center on the platform for ≥ a set
//     time), path to the platform, swim speed, path efficiency, mean proximity (Gallagher), cumulative search
//     error (1-s bins minus the ideal straight swim), heading errors (trajectory and head direction),
//     quadrant times, thigmotaxis, floating, and a Pathfinder-style search-strategy call with a cognitive
//     score;
//   • probe (platform removed): mean proximity to the former platform (the most sensitive probe measure,
//     Maei et al. 2009), quadrant times (also in the first 30 s and per time bin), platform crossings,
//     platform-zone time and entries, first-crossing latency and the search entropy H.
// A swimming mouse often has its tail base under water: positions use the body center keypoint and fall
// back to the ear midpoint (or neck) and then the nose when it is missing.

import Foundation

// MARK: - Pool geometry (cm)

struct WaterMazeGeometry {
    let center: V2
    let radius: Double
    let platform: V2
    let platformRadius: Double
    /// Radius of the platform zone (the "Z" zone of the probe test).
    let zoneRadius: Double
    /// Width of the thigmotaxis (wall) zone.
    let wallZone: Double
    /// Direction of the platform from the pool center (radians, arena coordinates: x right, y down).
    let platformAngle: Double

    static func from(_ cal: ArenaCalibration, params p: AnalysisParams, mapping: ArenaMapping) -> WaterMazeGeometry? {
        guard cal.kind == .circle, mapping.isMetric, let marker = cal.markers["platform"] else { return nil }
        let e = mapping.extent
        let c = V2(e.x / 2, e.y / 2)
        let r = max(e.x / 2, 1)
        let pt = mapping.toArena(marker)
        guard pt.isFinite else { return nil }
        let angle = atan2(pt.y - c.y, pt.x - c.x)
        return WaterMazeGeometry(center: c, radius: r, platform: pt,
                                 platformRadius: max(0.5, p.mwmPlatformDiameter / 2),
                                 zoneRadius: max(0.5, p.mwmZoneRadius),
                                 wallZone: clamp(p.mwmWallZone, 0, r * 0.9),
                                 platformAngle: angle)
    }

    /// Quadrant of a point: 0 = target (platform direction ± 45°), 1 = adjacent counter-clockwise on screen,
    /// 2 = opposite, 3 = adjacent clockwise on screen.
    func quadrant(_ q: V2) -> Int {
        var d = atan2(q.y - center.y, q.x - center.x) - platformAngle
        while d > Double.pi { d -= 2 * Double.pi }
        while d <= -Double.pi { d += 2 * Double.pi }
        let a = abs(d)
        if a <= Double.pi / 4 { return 0 }
        if a > 3 * Double.pi / 4 { return 2 }
        // Arena y points down: a negative angle is counter-clockwise as seen on screen.
        return d < 0 ? 1 : 3
    }

    /// Wedge of quadrant k (same numbering as `quadrant`) for drawing.
    func quadrantPolygon(_ k: Int) -> [V2] {
        let offsets = [0.0, -Double.pi / 2, Double.pi, Double.pi / 2]
        let base = platformAngle + offsets[max(0, min(3, k))]
        var poly: [V2] = [center]
        for s in 0...16 {
            let a = base - Double.pi / 4 + Double.pi / 2 * Double(s) / 16
            poly.append(V2(center.x + radius * cos(a), center.y + radius * sin(a)))
        }
        return poly
    }

    func distanceToWall(_ q: V2) -> Double { radius - q.distance(to: center) }
}

// MARK: - Search strategies (Pathfinder-style rules)

/// Search strategy of one swim path. Rules and default thresholds follow Pathfinder (Cooke et al. 2019,
/// F1000Research 8:1521), checked from the most to the least spatially specific; distance thresholds are
/// scaled with the pool diameter relative to the 110-cm pool of the published defaults.
enum WaterMazeStrategy: Int, CaseIterable {
    case unclassified = 0
    case directPath, focalSearch, directedSearch, indirectSearch, chaining, scanning, thigmotaxis, randomSearch

    var key: String {
        switch self {
        case .unclassified: return "unclassified"
        case .directPath: return "direct_path"
        case .focalSearch: return "focal_search"
        case .directedSearch: return "directed_search"
        case .indirectSearch: return "indirect_search"
        case .chaining: return "chaining"
        case .scanning: return "scanning"
        case .thigmotaxis: return "thigmotaxis"
        case .randomSearch: return "random_search"
        }
    }

    var title: String {
        switch self {
        case .unclassified: return L10n.tr("无法分类")
        case .directPath: return L10n.tr("直线路径")
        case .focalSearch: return L10n.tr("聚焦搜索")
        case .directedSearch: return L10n.tr("定向搜索")
        case .indirectSearch: return L10n.tr("间接搜索")
        case .chaining: return L10n.tr("链式搜索")
        case .scanning: return L10n.tr("扫描")
        case .thigmotaxis: return L10n.tr("贴壁")
        case .randomSearch: return L10n.tr("随机搜索")
        }
    }

    /// Spatial (hippocampus-dependent) strategies.
    var isSpatial: Bool { [.directPath, .focalSearch, .directedSearch, .indirectSearch].contains(self) }

    /// Cognitive score (direct 6 … thigmotaxis 0), as used with Pathfinder calls in the literature.
    var cognitiveScore: Double? {
        switch self {
        case .directPath: return 6
        case .directedSearch: return 5
        case .focalSearch, .indirectSearch: return 4
        case .chaining: return 3
        case .scanning: return 2
        case .randomSearch: return 1
        case .thigmotaxis: return 0
        case .unclassified: return nil
        }
    }
}

struct WaterMazePathFeatures {
    /// Ideal path error = cumulative search error (cm; 1-s bins).
    var ipe: Double = .nan
    /// Mean angle between the swim direction and the direction to the platform (°).
    var headingError: Double = .nan
    /// Fraction of the path inside the angular corridor from the start towards the platform.
    var corridorFraction: Double = 0
    /// Path length (cm).
    var distance: Double = 0
    /// Mean distance of the path from its own centroid (cm).
    var centroidSpread: Double = .nan
    /// Mean distance to the platform center (cm).
    var meanGoalDistance: Double = .nan
    /// Fraction of time in the chaining annulus (the ring at the platform's distance from the center).
    var annulusFraction: Double = 0
    var quadrantsVisited = 0
    /// Fraction of the pool's grid cells visited.
    var areaFraction: Double = 0
    /// Mean distance to the pool center (cm).
    var meanCenterDistance: Double = .nan
    /// Fraction of time in the full and in the small (half-width) thigmotaxis zone.
    var wallFraction: Double = 0
    var smallWallFraction: Double = 0
}

enum WaterMazeClassifier {
    static func classify(_ f: WaterMazePathFeatures, radius r: Double) -> WaterMazeStrategy {
        let s = max(0.2, 2 * r / 110)
        if f.ipe.isFinite, f.headingError.isFinite, f.ipe <= 125 * s, f.headingError <= 40 { return .directPath }
        if f.centroidSpread.isFinite, f.meanGoalDistance.isFinite, f.centroidSpread <= 0.3 * r, f.meanGoalDistance <= 0.3 * r,
           f.distance >= 100 * s, f.distance <= 400 * s { return .focalSearch }
        if f.corridorFraction >= 0.7, f.distance <= 400 * s, f.ipe.isFinite, f.ipe <= 1500 * s { return .directedSearch }
        if f.ipe.isFinite, f.ipe <= 300 * s { return .indirectSearch }
        if f.annulusFraction >= 0.9, f.quadrantsVisited >= 4, f.areaFraction <= 0.4 { return .chaining }
        if f.areaFraction >= 0.05, f.areaFraction <= 0.2, f.meanCenterDistance.isFinite, f.meanCenterDistance <= 0.6 * r { return .scanning }
        if f.wallFraction >= 0.65, f.smallWallFraction >= 0.35, f.distance >= 400 * s { return .thigmotaxis }
        if f.areaFraction >= 0.1 { return .randomSearch }
        return .unclassified
    }
}

// MARK: - Analyzer

extension MemoryAnalyzers {

    static func waterMaze(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let n = c.n
        let probe = c.session.phase == "Probe"
        guard let g = WaterMazeGeometry.from(c.session.calibration, params: p, mapping: c.fs.mapping) else {
            r.warnings.append(L10n.tr("需要圆形水池标定，并把 P 手柄放到平台中心（探索测试时为原平台位置）。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let win = (0..<n).filter { tb.inWindow[$0] }
        guard !win.isEmpty else {
            r.metrics = c.locomotionMetrics()
            return r
        }
        let s0 = tb.windowStartTime

        // Position: body center, else ear midpoint / neck, else nose.
        var pos = [V2?](repeating: nil, count: n)
        for i in 0..<n { pos[i] = a.pos(.bodyCenter, i) ?? a.headBase(i) ?? a.pos(.nose, i) }
        // Held position (a short tracking gap keeps the last place, as the zone masks do).
        var held = [V2?](repeating: nil, count: n)
        var lastQ: V2?
        for i in 0..<n {
            if let q = pos[i] { lastQ = q }
            held[i] = lastQ
        }

        // Escape: body center within platform radius + margin, staying for the set time.
        let reach = g.platformRadius + max(0, p.mwmPlatformMargin)
        var escapeIndex: Int?
        if !probe {
            let stayNeeded = max(0, p.mwmEscapeStay)
            var k = 0
            while k < win.count {
                let i = win[k]
                guard let q = held[i], q.distance(to: g.platform) <= reach else { k += 1; continue }
                var j = k
                while j + 1 < win.count, let qn = held[win[j + 1]], qn.distance(to: g.platform) <= reach { j += 1 }
                let stay = tb.t[win[j]] + tb.dur[win[j]] - tb.t[i]
                let reachedEnd = j == win.count - 1
                if stay >= stayNeeded - 1e-9 || (reachedEnd && stay >= stayNeeded * 0.5) {
                    escapeIndex = i
                    break
                }
                k = j + 1
            }
        }
        let escapeTime = escapeIndex.map { tb.t[$0] }
        // Frames of the swim that is analysed: the window, up to reaching the platform.
        var inTrial = [Bool](repeating: false, count: n)
        for i in win {
            if let e = escapeTime, tb.t[i] >= e { continue }
            inTrial[i] = true
        }
        let trialFrames = win.filter { inTrial[$0] }
        let trialTime = trialFrames.reduce(0.0) { $0 + tb.dur[$1] }
        let latency = escapeTime.map { $0 - s0 } ?? tb.windowDuration

        // Path, start and speed.
        let path = c.distance(.bodyCenter, onlyWhere: inTrial)
        let start = trialFrames.lazy.compactMap { pos[$0] }.first
        let d0 = start.map { $0.distance(to: g.platform) }
        let speed = trialTime > 0 ? path / trialTime : nil

        // Time-weighted zone fractions over the analysed swim.
        var tq = [Double](repeating: 0, count: 4)
        var tKnown = 0.0, tZone = 0.0, tWall = 0.0, tWallSmall = 0.0, tAnnulus = 0.0
        var proxSum = 0.0, centerSum = 0.0
        var quadrant = [Double](repeating: .nan, count: n)
        var distPlatform = [Double](repeating: .nan, count: n)
        var zoneMask = [Bool](repeating: false, count: n)
        var wallMask = [Bool](repeating: false, count: n)
        var platMask = [Bool](repeating: false, count: n)
        let ringRadius = g.platform.distance(to: g.center)
        let ringHalf = 10 * max(0.2, 2 * g.radius / 110)
        for i in 0..<n {
            guard let q = held[i] else { continue }
            let k = g.quadrant(q)
            let dp = q.distance(to: g.platform)
            quadrant[i] = Double(k)
            distPlatform[i] = dp
            zoneMask[i] = dp <= g.zoneRadius
            platMask[i] = dp <= g.platformRadius
            let dw = g.distanceToWall(q)
            wallMask[i] = dw <= g.wallZone
            guard inTrial[i] else { continue }
            let w = tb.dur[i]
            tKnown += w
            tq[k] += w
            if zoneMask[i] { tZone += w }
            if wallMask[i] { tWall += w }
            if dw <= g.wallZone / 2 { tWallSmall += w }
            if abs(q.distance(to: g.center) - ringRadius) <= ringHalf { tAnnulus += w }
            proxSum += dp * w
            centerSum += q.distance(to: g.center) * w
        }
        func pct(_ x: Double) -> Double? { tKnown > 0 ? x / tKnown * 100 : nil }
        let meanProximity: Double? = tKnown > 0 ? proxSum / tKnown : nil

        // Cumulative search error (Gallagher): 1-s bins of mean distance minus the ideal straight swim at
        // the animal's mean speed from its start point.
        var cse: Double?
        var binMeans: [Double] = []
        if let d0, let first = trialFrames.first {
            let v = speed ?? 0
            let t0 = tb.t[first]
            var sums: [Double] = []
            var counts: [Double] = []
            for i in trialFrames {
                guard let q = pos[i] else { continue }
                let b = Int((tb.t[i] - t0).rounded(.down))
                guard b >= 0, b < 100_000 else { continue }
                while sums.count <= b { sums.append(0); counts.append(0) }
                sums[b] += q.distance(to: g.platform)
                counts[b] += 1
            }
            var actual = 0.0, ideal = 0.0
            for b in sums.indices where counts[b] > 0 {
                let m = sums[b] / counts[b]
                binMeans.append(m)
                actual += m
                ideal += max(0, d0 - v * (Double(b) + 0.5))
            }
            if !binMeans.isEmpty { cse = actual - ideal }
        }

        // Heading errors: trajectory direction vs direction to the platform.
        var initialHeading: Double?
        if let start {
            for i in trialFrames {
                guard let q = pos[i], q.distance(to: start) >= 10 else { continue }
                initialHeading = Angle.diff((q - start).screenAngleDeg, (g.platform - start).screenAngleDeg)
                break
            }
        }
        var headingSum = 0.0, headingN = 0.0
        let lag = max(1, Int((0.25 / tb.dt).rounded()))
        var idx = 0
        while idx + lag < trialFrames.count {
            let i = trialFrames[idx], j = trialFrames[idx + lag]
            if let q0 = pos[i], let q1 = pos[j], q1.distance(to: q0) >= 1, tb.t[j] - tb.t[i] <= 1 {
                headingSum += Angle.diff((q1 - q0).screenAngleDeg, (g.platform - q0).screenAngleDeg)
                headingN += 1
            }
            idx += lag
        }
        let meanHeading: Double? = headingN > 0 ? headingSum / headingN : nil
        // Head direction (ear midpoint → nose) relative to the platform in the first 2 s.
        var headSum = 0.0, headN = 0.0
        for i in trialFrames where tb.t[i] - s0 <= 2 {
            guard a.hd[i].isFinite, let base = a.headBase(i) else { continue }
            headSum += Angle.diff(a.hd[i], (g.platform - base).screenAngleDeg)
            headN += 1
        }
        let headError: Double? = headN > 0 ? headSum / headN : nil

        // Floating: body speed below the threshold, sustained.
        let rawFloat = (0..<n).map { i -> Bool in
            let v = i < a.speed.count ? a.speed[i] : .nan
            return v.isFinite && v < p.mwmFloatSpeed
        }
        let floating = AnalysisContext.and(Bouts.sustained(rawFloat, tb, minDuration: p.mwmFloatMin), inTrial)
        let tFloat = tb.total(floating)
        let floatPct: Double? = trialTime > 0 ? tFloat / trialTime * 100 : nil

        // Crossings and zone entries (probe), first crossing.
        func entries(_ m: [Bool]) -> Int {
            var count = 0
            var prev = false
            for i in trialFrames {
                if m[i] && !prev { count += 1 }
                prev = m[i]
            }
            return count
        }
        let crossings = entries(platMask)
        let zoneEntries = entries(zoneMask)
        let firstCrossing = trialFrames.first { platMask[$0] }.map { tb.t[$0] - s0 }

        // Strategy features on the analysed swim.
        var f = WaterMazePathFeatures()
        f.distance = path
        f.ipe = cse ?? .nan
        f.headingError = meanHeading ?? .nan
        f.meanGoalDistance = meanProximity ?? .nan
        f.meanCenterDistance = tKnown > 0 ? centerSum / tKnown : .nan
        f.wallFraction = tKnown > 0 ? tWall / tKnown : 0
        f.smallWallFraction = tKnown > 0 ? tWallSmall / tKnown : 0
        f.annulusFraction = tKnown > 0 ? tAnnulus / tKnown : 0
        f.quadrantsVisited = tq.filter { $0 > 0 }.count
        var sx = 0.0, sy = 0.0, sw = 0.0
        for i in trialFrames { if let q = pos[i] { sx += q.x * tb.dur[i]; sy += q.y * tb.dur[i]; sw += tb.dur[i] } }
        if sw > 0 {
            let centroid = V2(sx / sw, sy / sw)
            var spread = 0.0
            for i in trialFrames { if let q = pos[i] { spread += q.distance(to: centroid) * tb.dur[i] } }
            f.centroidSpread = spread / sw
        }
        if let start {
            let goal = (g.platform - start).screenAngleDeg
            var inside = 0, counted = 0
            for i in trialFrames {
                guard let q = pos[i], q.distance(to: start) >= 5 else { continue }
                counted += 1
                if Angle.diff((q - start).screenAngleDeg, goal) <= max(1, p.mwmCorridor) / 2 { inside += 1 }
            }
            f.corridorFraction = counted > 0 ? Double(inside) / Double(counted) : 0
        }
        let cell = max(2, 2 * g.radius / 20)
        let cols = Int((2 * g.radius / cell).rounded(.up))
        var poolCells = 0
        var visited = Set<Int>()
        for row in 0..<cols {
            for col in 0..<cols {
                let q = V2(g.center.x - g.radius + (Double(col) + 0.5) * cell, g.center.y - g.radius + (Double(row) + 0.5) * cell)
                if q.distance(to: g.center) <= g.radius { poolCells += 1 }
            }
        }
        for i in trialFrames {
            guard let q = pos[i] else { continue }
            let col = Int(((q.x - (g.center.x - g.radius)) / cell).rounded(.down))
            let row = Int(((q.y - (g.center.y - g.radius)) / cell).rounded(.down))
            guard col >= 0, row >= 0, col < cols, row < cols else { continue }
            visited.insert(row * cols + col)
        }
        f.areaFraction = poolCells > 0 ? min(1, Double(visited.count) / Double(poolCells)) : 0
        let strategy = WaterMazeClassifier.classify(f, radius: g.radius)

        // Search entropy H (probe): error entropy around the former platform + path entropy.
        var entropy: Double?
        if probe && sw > 0 {
            let mx = sx / sw, my = sy / sw
            var err = 0.0, cxx = 0.0, cyy = 0.0, cxy = 0.0
            for i in trialFrames {
                guard let q = pos[i] else { continue }
                let w = tb.dur[i]
                let dp = q.distance(to: g.platform)
                err += dp * dp * w
                cxx += (q.x - mx) * (q.x - mx) * w
                cyy += (q.y - my) * (q.y - my) * w
                cxy += (q.x - mx) * (q.y - my) * w
            }
            err /= sw; cxx /= sw; cyy /= sw; cxy /= sw
            let tr = (cxx + cyy) / 2
            let root = (((cxx - cyy) / 2) * ((cxx - cyy) / 2) + cxy * cxy).squareRoot()
            let l1 = max(tr + root, 1e-6), l2 = max(tr - root, 1e-6)
            if err > 0 { entropy = log(err) + 0.5 * log(l1 * l2) }
        }

        // Probe: target quadrant in the first 30 s and per time bin.
        var target30: Double?
        if probe {
            var t30 = 0.0, all30 = 0.0
            for i in trialFrames where tb.t[i] - s0 < 30 {
                guard quadrant[i].isFinite else { continue }
                all30 += tb.dur[i]
                if quadrant[i] == 0 { t30 += tb.dur[i] }
            }
            if all30 > 0 { target30 = t30 / all30 * 100 }
        }

        // MARK: Metrics
        let num = AnalysisContext.num
        if probe {
            r.metrics = [
                c.m("mean_proximity", L10n.tr("平均距原平台距离"), meanProximity, "cm", 1, info: L10n.tr("到原平台中心距离的时间加权平均（Gallagher 指标）；越小越好")),
                c.m("target_quadrant_pct", L10n.tr("目标象限时间"), pct(tq[0]), "%", 1, info: L10n.tr("原平台方向 ±45°；随机水平为 25%"))
                    .withReference(25, L10n.tr("25% = 随机水平")),
                c.m("opposite_quadrant_pct", L10n.tr("对侧象限时间"), pct(tq[2]), "%", 1),
                c.m("adjacent_ccw_pct", L10n.tr("相邻象限（逆时针）时间"), pct(tq[1]), "%", 1),
                c.m("adjacent_cw_pct", L10n.tr("相邻象限（顺时针）时间"), pct(tq[3]), "%", 1),
                c.m("target_quadrant_30s_pct", L10n.tr("前 30 s 目标象限时间"), target30, "%", 1, info: L10n.tr("探索测试中记忆会消退，前 30 s 通常更敏感")),
                c.m("platform_crossings", L10n.tr("穿越原平台次数"), Double(crossings), "", 0),
                c.m("first_crossing_latency", L10n.tr("首次穿越潜伏期"), firstCrossing, "s", 1),
                c.m("zone_pct", L10n.tr("平台区时间"), pct(tZone), "%", 1, info: String(format: L10n.tr("以原平台为中心、半径 %@ cm 的区域"), num(g.zoneRadius))),
                c.m("zone_entries", L10n.tr("进入平台区次数"), Double(zoneEntries), "", 0),
                c.m("cse", L10n.tr("累计搜索误差（CIPL）"), cse, "cm", 0, info: L10n.tr("1 s 分段平均距离之和减去直线游向平台的理想值")),
                c.m("entropy", L10n.tr("搜索熵 H"), entropy, "", 2, info: L10n.tr("越小表示搜索越集中、越靠近原平台")),
                c.m("initial_heading_error", L10n.tr("起始朝向误差"), initialHeading, "°", 0, info: L10n.tr("最初 10 cm 游动方向与平台方向的夹角")),
                c.m("head_platform_error", L10n.tr("初始头朝向误差"), headError, "°", 0, info: L10n.tr("入水后 2 s 内头朝向（两耳中点 → 鼻尖）与平台方向的平均夹角")),
                c.m("distance", L10n.tr("总路程"), path / 100, "m", 2),
                c.m("swim_speed", L10n.tr("平均游速"), speed, "cm/s", 1),
                c.m("thigmotaxis_pct", L10n.tr("贴壁时间"), pct(tWall), "%", 1),
                c.m("floating_pct", L10n.tr("漂浮时间"), floatPct, "%", 1)
            ]
            r.primaryKey = "mean_proximity"
        } else {
            let found = escapeIndex != nil
            let efficiency: Double? = {
                guard found, let d0, path > 0 else { return nil }
                return min(1, max(0, d0 - g.platformRadius) / path)
            }()
            r.metrics = [
                c.m("escape_latency", L10n.tr("逃避潜伏期"), latency, "s", 1,
                    info: String(format: L10n.tr("身体中心到达平台并停留 ≥ %@ s；未找到时记为试次时长"), num(p.mwmEscapeStay)))
                    .censoring(L10n.tr("未找到平台"), if: !found),
                c.m("found_platform_pct", L10n.tr("找到平台"), found ? 100 : 0, "%", 0, info: L10n.tr("100 = 本次找到平台；组平均即找到平台的比例")),
                c.m("path_length", L10n.tr("到平台路径长度"), path / 100, "m", 2),
                c.m("swim_speed", L10n.tr("平均游速"), speed, "cm/s", 1),
                c.m("path_efficiency", L10n.tr("路径效率"), efficiency, "", 2, info: L10n.tr("入水点到平台边缘的直线距离 ÷ 实际路程（1 = 直线）")),
                c.m("mean_proximity", L10n.tr("平均距平台距离"), meanProximity, "cm", 1),
                c.m("cse", L10n.tr("累计搜索误差（CIPL）"), cse, "cm", 0, info: L10n.tr("1 s 分段平均距离之和减去直线游向平台的理想值")),
                c.m("initial_heading_error", L10n.tr("起始朝向误差"), initialHeading, "°", 0, info: L10n.tr("最初 10 cm 游动方向与平台方向的夹角")),
                c.m("mean_heading_error", L10n.tr("平均朝向误差"), meanHeading, "°", 0),
                c.m("head_platform_error", L10n.tr("初始头朝向误差"), headError, "°", 0, info: L10n.tr("入水后 2 s 内头朝向（两耳中点 → 鼻尖）与平台方向的平均夹角")),
                c.m("target_quadrant_pct", L10n.tr("目标象限时间"), pct(tq[0]), "%", 1).withReference(25, L10n.tr("25% = 随机水平")),
                c.m("opposite_quadrant_pct", L10n.tr("对侧象限时间"), pct(tq[2]), "%", 1),
                c.m("thigmotaxis_pct", L10n.tr("贴壁时间"), pct(tWall), "%", 1),
                c.m("floating_pct", L10n.tr("漂浮时间"), floatPct, "%", 1),
                c.m("strategy_score", L10n.tr("搜索策略认知评分"), strategy.cognitiveScore, "", 0, info: L10n.tr("直线 6、定向 5、聚焦 / 间接 4、链式 3、扫描 2、随机 1、贴壁 0")),
                c.m("spatial_strategy_pct", L10n.tr("空间策略"), strategy == .unclassified ? nil : (strategy.isSpatial ? 100 : 0), "%", 0,
                    info: L10n.tr("100 = 直线、聚焦、定向或间接搜索；组平均即空间策略的比例")),
                c.m("strategy_code", L10n.tr("搜索策略代码"), Double(strategy.rawValue), "", 0,
                    info: L10n.tr("1 直线路径、2 聚焦搜索、3 定向搜索、4 间接搜索、5 链式、6 扫描、7 贴壁、8 随机、0 无法分类"))
            ]
            r.primaryKey = "escape_latency"
        }

        // MARK: Figures
        var dots: [PlotDot] = []
        if let start { dots.append(PlotDot(p: start, color: .accent, radius: 2.6)) }
        if let e = escapeIndex, let q = pos[e] ?? held[e] { dots.append(PlotDot(p: q, color: .target, radius: 3)) }
        if probe {
            var prev = false
            for i in trialFrames {
                if platMask[i] && !prev, let q = held[i] { dots.append(PlotDot(p: q, color: .target, radius: 2.2)) }
                prev = platMask[i]
            }
        }
        let paths = [PlotPath(color: .accent, segments: c.segments(.bodyCenter, onlyWhere: inTrial))]
        r.blocks.append(c.trajectoryBlock(caption: probe ? L10n.tr("探索测试全程的游泳路径；蓝点为入水点，绿点为穿越原平台处")
                                                         : L10n.tr("入水到找到平台的游泳路径；蓝点为入水点，绿点为到达平台处"),
                                          dots: dots, paths: paths))

        // Occupancy of the analysed swim only (the time sitting on the platform is left out).
        let hcell = max(1, max(p.spatialBin, 2 * g.radius / 40))
        let hcols = max(1, Int((c.extent.x / hcell).rounded(.up)))
        let hrows = max(1, Int((c.extent.y / hcell).rounded(.up)))
        var hv = [Double](repeating: 0, count: hcols * hrows)
        for i in trialFrames {
            guard let q = a.pos(.bodyCenter, i) else { continue }
            let cx = Int(q.x / hcell), cy = Int(q.y / hcell)
            guard cx >= 0, cy >= 0, cx < hcols, cy < hrows else { continue }
            hv[cy * hcols + cx] += tb.dur[i]
        }
        for row in 0..<hrows {
            for col in 0..<hcols where V2((Double(col) + 0.5) * hcell, (Double(row) + 0.5) * hcell).distance(to: g.center) > g.radius {
                hv[row * hcols + col] = .nan
            }
        }
        r.blocks.append(c.heatBlock(L10n.tr("停留热图"),
                                    caption: probe ? L10n.tr("探索测试全程身体中心的停留时间；原平台周围的亮区即搜索集中处")
                                                   : L10n.tr("找到平台之前身体中心的停留时间（不含在平台上的时间）"),
                                    grid: HeatGrid(columns: hcols, rows: hrows, cell: hcell, values: hv), keypoint: .bodyCenter))

        // No bars without a known position in the swim (before build 23 they were drawn as 0 %).
        let quadrants: [(String, Double?, ColorKey)] = [(L10n.tr("目标"), pct(tq[0]), .target), (L10n.tr("相邻（逆时针）"), pct(tq[1]), .neutral),
                                                        (L10n.tr("对侧"), pct(tq[2]), .error), (L10n.tr("相邻（顺时针）"), pct(tq[3]), .neutral)]
        let qItems = quadrants.compactMap { q in q.1.map { BarItem(label: q.0, value: $0, color: q.2) } }
        if !qItems.isEmpty {
            r.blocks.append(ReportBlock(title: L10n.tr("象限时间"), caption: L10n.tr("虚线为随机水平 25%"),
                                        kind: .bars(BarData(items: qItems, unit: "%", decimals: 1, referenceLine: 25, referenceLabel: L10n.tr("25% = 随机水平")))))
        }

        var distPts: [LinePoint] = []
        let dstep = max(1, trialFrames.count / 300)
        for (j, i) in trialFrames.enumerated() where j % dstep == 0 || j == trialFrames.count - 1 {
            if let q = pos[i] { distPts.append(LinePoint(x: tb.t[i] - s0, y: q.distance(to: g.platform))) }
        }
        if !distPts.isEmpty {
            r.blocks.append(ReportBlock(title: L10n.tr("到平台的距离"), caption: L10n.tr("虚线为平台边缘"),
                                        kind: .line(LineData(series: [LineSeries(name: L10n.tr("距离"), color: .accent, points: distPts)],
                                                             xLabel: "s", yLabel: "cm", referenceY: g.platformRadius, referenceYLabel: L10n.tr("平台边缘")))))
        }

        if probe {
            // Full bins at their centres (series contract); a bin without a known position has no point.
            var qPts: [LinePoint] = []
            var pPts: [LinePoint] = []
            let probeBin = max(5, p.timeBin)
            for b in c.courseBins(probeBin, seconds: true) {
                var tt = 0.0, tall = 0.0, ps = 0.0
                for i in tb.indices(from: b.start, to: b.end) where inTrial[i] && quadrant[i].isFinite {
                    tall += tb.dur[i]
                    if quadrant[i] == 0 { tt += tb.dur[i] }
                    ps += distPlatform[i] * tb.dur[i]
                }
                guard tall > 0 else { continue }
                qPts.append(LinePoint(x: b.x, y: tt / tall * 100))
                pPts.append(LinePoint(x: b.x, y: ps / tall))
            }
            if qPts.count > 1 {
                r.blocks.append(ReportBlock(title: L10n.tr("分段目标象限时间"), caption: L10n.tr("每段画在中点；虚线为随机水平 25%"),
                                            kind: .line(LineData(series: [LineSeries(name: L10n.tr("目标象限"), color: .target, points: qPts)],
                                                                 xLabel: c.courseAxis(probeBin, seconds: true), yLabel: "%", yRange: 0...100, referenceY: 25,
                                                                 referenceYLabel: L10n.tr("25% = 随机水平")))))
                r.blocks.append(ReportBlock(title: L10n.tr("分段平均距离"), caption: L10n.tr("每段画在中点"),
                                            kind: .line(LineData(series: [LineSeries(name: L10n.tr("平均距离"), color: .accent, points: pPts)],
                                                                 xLabel: c.courseAxis(probeBin, seconds: true), yLabel: "cm"))))
            }
        } else {
            func fmt(_ v: Double, _ d: Int) -> String { v.isFinite ? String(format: "%.\(d)f", v) : "—" }
            let rows: [[String]] = [
                [L10n.tr("策略"), strategy.title],
                [L10n.tr("认知评分"), strategy.cognitiveScore.map { fmt($0, 0) + " / 6" } ?? "—"],
                [L10n.tr("理想路径误差 IPE"), fmt(f.ipe, 0) + " cm"],
                [L10n.tr("平均朝向误差"), fmt(f.headingError, 0) + "°"],
                [L10n.tr("定向通道内"), fmt(f.corridorFraction * 100, 0) + "%"],
                [L10n.tr("路程"), fmt(f.distance, 0) + " cm"],
                [L10n.tr("距路径质心平均距离"), fmt(f.centroidSpread, 1) + " cm"],
                [L10n.tr("覆盖面积"), fmt(f.areaFraction * 100, 0) + "%"],
                [L10n.tr("链式环带内"), fmt(f.annulusFraction * 100, 0) + "%"],
                [L10n.tr("贴壁区内"), fmt(f.wallFraction * 100, 0) + "%"]
            ]
            r.blocks.append(ReportBlock(title: L10n.tr("搜索策略"), caption: L10n.tr("Pathfinder 规则；阈值见方法说明"),
                                        kind: .table(TableData(columns: [L10n.tr("项目"), L10n.tr("数值")], rows: rows,
                                                               rowColors: [strategy.isSpatial ? ColorKey.target : ColorKey.neutral]))))
        }

        // Timeline / review.
        var tracks = [TimelineTrack(name: L10n.tr("平台区"), color: .target, bouts: Bouts.find(AnalysisContext.and(zoneMask, inTrial), tb, mergeGap: 0.2)),
                      TimelineTrack(name: L10n.tr("贴壁"), color: .periphery, bouts: Bouts.find(AnalysisContext.and(wallMask, inTrial), tb, mergeGap: 0.3)),
                      TimelineTrack(name: L10n.tr("漂浮"), color: .freezing, bouts: Bouts.find(floating, tb))]
        if let e = escapeIndex {
            let after = (0..<n).map { tb.inWindow[$0] && $0 >= e }
            tracks.append(TimelineTrack(name: L10n.tr("在平台上"), color: .escape, bouts: Bouts.find(after, tb)))
        }
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks

        r.frameColumns = [("mwm_trial", AnalysisContext.flag(inTrial)),
                          ("mwm_dist_platform_cm", distPlatform),
                          ("mwm_quadrant", quadrant),
                          ("mwm_platform_zone", AnalysisContext.flag(zoneMask)),
                          ("mwm_wall_zone", AnalysisContext.flag(wallMask)),
                          ("mwm_floating", AnalysisContext.flag(floating))]

        // MARK: Warnings and methods
        if !probe && escapeIndex == nil {
            r.warnings.append(String(format: L10n.tr("在 %@ s 内没有找到平台：潜伏期记为试次时长，路径和策略按整个试次计算。"), num((tb.windowDuration * 10).rounded() / 10)))
        }
        if let fp = floatPct, fp > 20 {
            r.warnings.append(String(format: L10n.tr("漂浮时间占 %@%%：漂浮是非认知因素，会拉长潜伏期；请核对，或按实验室标准考虑排除。"), num(fp.rounded())))
        }
        if !probe, let wp = pct(tWall), wp > 50 {
            r.warnings.append(String(format: L10n.tr("贴壁时间占 %@%%：贴壁（多见于最初几次训练或焦虑样表型）会拉长潜伏期，与空间记忆没有直接关系。"), num(wp.rounded())))
        }
        if p.windowLength <= 0 {
            r.warnings.append(L10n.tr("“分析时长”为 0（到视频结尾）：通常应设为最长试次时间（如 60 s），否则被捞出水后的画面也会计入。"))
        }
        if let start, start.distance(to: g.platform) <= reach {
            r.warnings.append(L10n.tr("分析起点时动物已在平台上或紧挨平台：请检查“分析起点”是否设为小鼠入水的时刻，以及 P 手柄的位置。"))
        }

        if probe {
            r.methods.append(String(format: L10n.tr("探索测试（平台已撤去）分析整个分析时间段，位置用身体中心（缺失时用两耳中点或鼻尖）。象限以原平台为中心划分（目标象限为原平台方向 ±45°）；平台区半径 %@ cm；穿越次数按进入原平台范围（半径 %@ cm）计数。"),
                                    num(g.zoneRadius), num(g.platformRadius)))
        } else {
            r.methods.append(String(format: L10n.tr("位置用身体中心（缺失时用两耳中点或鼻尖）。平台半径 %@ cm；身体中心进入平台半径 + %@ cm 并停留 ≥ %@ s 记为找到平台。潜伏期从分析起点（入水）算起，未找到时记为试次时长；路程、游速和其他指标只统计找到平台之前的部分。"),
                                    num(g.platformRadius), num(max(0, p.mwmPlatformMargin)), num(p.mwmEscapeStay)))
        }
        r.methods.append(String(format: L10n.tr("平均距离为到平台中心距离的时间加权平均（Gallagher 指标）；累计搜索误差为按 1 s 分段的平均距离之和，减去以同样平均速度从入水点直线游向平台的理想值。贴壁为距池壁 ≤ %@ cm，漂浮为速度 < %@ cm/s 持续 ≥ %@ s。"),
                                num(g.wallZone), num(p.mwmFloatSpeed), num(p.mwmFloatMin)))
        if probe {
            r.methods.append(L10n.tr("搜索熵 H = ln(σd²) + ln(σa·σb)：σd² 为到原平台中心距离的均方，σa、σb 为路径沿两个主轴的标准差（参照 Maei et al. 2009）；越小表示搜索越集中、越靠近原平台。"))
        } else {
            r.methods.append(L10n.tr("搜索策略按 Pathfinder（Cooke et al. 2019）已发表的默认规则依次判定：直线路径、聚焦、定向、间接、链式、扫描、贴壁、随机；距离阈值按水池直径相对 110 cm 缩放。认知评分：直线 6、定向 5、聚焦 / 间接 4、链式 3、扫描 2、随机 1、贴壁 0。"))
        }
        if c.session.phase == "Reversal" {
            r.methods.append(L10n.tr("反转学习：P 为新平台位置；平台移到对侧时，对侧象限即原平台所在象限，可作为坚持原位置的指标。"))
        }
        return r
    }
}
