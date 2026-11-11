// Zones.swift — arena mapping from a calibration, and the paradigm zones in arena units (cm).
// Zones are the single source of truth for analysis and for drawing on the video / plots.

import Foundation

// MARK: - Mapping from calibration

enum ArenaMapper {
    /// Distance from the maze center to the end of an arm, in cm.
    static func centerToEnd(_ cal: ArenaCalibration) -> Double {
        switch cal.kind {
        case .yMaze: return cal.armLengthCM + cal.armWidthCM * 0.29
        default: return cal.armLengthCM + cal.armWidthCM / 2
        }
    }

    static func mapping(_ cal: ArenaCalibration, frameSize: V2) -> ArenaMapping {
        let fs = V2(max(frameSize.x, 1), max(frameSize.y, 1))
        switch cal.kind {
        case .none:
            return .pixelsOnly(frameSize: fs)

        case .rectangle:
            let w = max(cal.widthCM, 1), h = max(cal.heightCM, 1)
            let src = cal.corners.map { $0.pixels(fs) }
            let dst = [V2(0, 0), V2(w, 0), V2(w, h), V2(0, h)]
            guard let hm = Homography.fit(src: src, dst: dst), let inv = hm.inverse else {
                return .pixelsOnly(frameSize: fs)
            }
            return ArenaMapping(kind: .homography(hm, inv), extent: V2(w, h), frameSize: fs)

        case .circle:
            let c = cal.circleCenter.pixels(fs)
            let e = cal.circleEdge.pixels(fs)
            let rPx = max(c.distance(to: e), 1)
            let d = max(cal.diameterCM, 1)
            let s = (d / 2) / rPx
            return ArenaMapping(kind: .similarity(cmPerPx: s, originPx: c, offsetCM: V2(d / 2, d / 2)), extent: V2(d, d), frameSize: fs)

        case .plusMaze, .yMaze, .tMaze:
            let need = cal.kind == .plusMaze ? 5 : 4
            guard cal.mazePoints.count == need else { return .pixelsOnly(frameSize: fs) }
            let px = cal.mazePoints.map { $0.pixels(fs) }
            let center = px[0]
            let lengths = px.dropFirst().map { $0.distance(to: center) }
            let meanPx = max(lengths.reduce(0, +) / Double(lengths.count), 1)
            let s = centerToEnd(cal) / meanPx
            let rel = px.map { ($0 - center) * s }
            let margin = cal.armWidthCM / 2 + 8
            let minX = (rel.map { $0.x }.min() ?? 0) - margin
            let minY = (rel.map { $0.y }.min() ?? 0) - margin
            let maxX = (rel.map { $0.x }.max() ?? 0) + margin
            let maxY = (rel.map { $0.y }.max() ?? 0) + margin
            return ArenaMapping(kind: .similarity(cmPerPx: s, originPx: center, offsetCM: V2(-minX, -minY)),
                                extent: V2(maxX - minX, maxY - minY), frameSize: fs)
        }
    }
}

// MARK: - Zone

enum ZoneRole: String {
    case arena, center, periphery, chamber, social, object, novel, familiar, cup
    case interaction, corner, enclosure
    case open, closed, mazeCenter, arm, choice
    case light, dark, shelter, target, hole, quadrant, cue
}

enum ZoneShape {
    case polygon([V2])
    case circle(center: V2, radius: Double)
}

struct Zone: Identifiable {
    let id: String
    var title: String
    var role: ZoneRole
    var shape: ZoneShape
    /// Drawn with a label in plots and on the video.
    var showsLabel = true
    /// Drawn as a thin outline only (e.g. sniff zones around cups).
    var outlineOnly = false

    func contains(_ p: V2) -> Bool {
        guard p.isFinite else { return false }
        switch shape {
        case .polygon(let pts): return polygonContains(pts, p)
        case .circle(let c, let r): return p.distance(to: c) <= r
        }
    }

    var center: V2 {
        switch shape {
        case .circle(let c, _): return c
        case .polygon(let pts):
            guard !pts.isEmpty else { return .zero }
            let s = pts.reduce(V2.zero, +)
            return s / Double(pts.count)
        }
    }

    /// Closed outline in arena units (circles sampled as polygons).
    func outline(segments: Int = 64) -> [V2] {
        switch shape {
        case .polygon(let pts): return pts
        case .circle(let c, let r):
            return (0..<segments).map { i in
                let a = Double(i) / Double(segments) * 2 * .pi
                return V2(c.x + r * cos(a), c.y + r * sin(a))
            }
        }
    }

    static func rect(_ id: String, _ title: String, _ role: ZoneRole, x: Double, y: Double, w: Double, h: Double) -> Zone {
        Zone(id: id, title: title, role: role, shape: .polygon([V2(x, y), V2(x + w, y), V2(x + w, y + h), V2(x, y + h)]))
    }

    static func circle(_ id: String, _ title: String, _ role: ZoneRole, _ c: V2, _ r: Double) -> Zone {
        Zone(id: id, title: title, role: role, shape: .circle(center: c, radius: r))
    }
}

// MARK: - Maze geometry (cm)

struct MazeGeometry {
    let center: V2
    let ends: [V2]          // arm end points
    let labels: [String]
    let armWidth: Double
    let centerRadius: Double

    /// Arm rectangle (from the edge of the center region to the arm end).
    func armPolygon(_ i: Int, extraWidth: Double = 0) -> [V2] {
        let dir = (ends[i] - center).normalized
        let n = dir.perp
        let start = center + dir * centerRadius
        let hw = armWidth / 2 + extraWidth
        let end = ends[i]
        return [start + n * hw, end + n * hw, end - n * hw, start - n * hw]
    }

    /// Index of the arm the point lies in (with a tolerance on the width), or nil.
    func armIndex(_ p: V2, tolerance: Double = 1.25) -> Int? {
        guard p.isFinite else { return nil }
        if p.distance(to: center) <= centerRadius { return nil }
        var best: (Int, Double)?
        for i in ends.indices {
            let (d, t) = pointSegment(p, center, ends[i])
            let len = ends[i].distance(to: center)
            guard t * len >= centerRadius * 0.85, t <= 1.08, d <= armWidth / 2 * tolerance else { continue }
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    func inCenter(_ p: V2, tolerance: Double = 1.0) -> Bool {
        p.isFinite && p.distance(to: center) <= centerRadius * tolerance
    }

    /// Distance from p to the nearest arm axis.
    func distanceToArms(_ p: V2, arms: [Int]) -> Double {
        arms.map { pointSegment(p, center, ends[$0]).distance }.min() ?? .infinity
    }

    static func from(_ cal: ArenaCalibration, mapping: ArenaMapping) -> MazeGeometry? {
        let need = cal.kind == .plusMaze ? 5 : 4
        guard [.plusMaze, .yMaze, .tMaze].contains(cal.kind), cal.mazePoints.count == need else { return nil }
        let pts = cal.mazePoints.map { mapping.toArena($0) }
        let w = max(cal.armWidthCM, 1)
        let cr: Double
        switch cal.kind {
        case .yMaze: cr = w * 0.65
        default: cr = w / 2
        }
        return MazeGeometry(center: pts[0], ends: Array(pts.dropFirst()), labels: Array(cal.kind.mazeLabels.dropFirst()), armWidth: w, centerRadius: cr)
    }
}

// MARK: - Elevated zero maze (ring track, four equal segments)

/// The ring of an elevated zero maze in arena units (cm): center, outer and inner radius, and the angle of the
/// middle of the first open segment (the O handle). Segments 0 and 2 are open, 1 and 3 closed, each 90°.
struct ZeroMazeGeometry {
    let center: V2
    let outer: Double
    let inner: Double
    /// Angle (radians, atan2 in arena coordinates) of the middle of open segment 0.
    let openAngle: Double

    static let quarter = Double.pi / 2

    var width: Double { outer - inner }

    static func from(_ cal: ArenaCalibration, mapping: ArenaMapping) -> ZeroMazeGeometry? {
        guard cal.kind == .circle, mapping.isMetric else { return nil }
        let r = mapping.extent.x / 2
        guard r > 0 else { return nil }
        let c = V2(r, r)
        let w = min(cal.ringWidthCM > 0 ? cal.ringWidthCM : 5, r * 0.9)
        var angle = -Double.pi / 2
        if let o = cal.markers["open"] {
            let q = mapping.toArena(o)
            if q.isFinite && q.distance(to: c) > 1e-6 { angle = atan2(q.y - c.y, q.x - c.x) }
        }
        return ZeroMazeGeometry(center: c, outer: r, inner: r - w, openAngle: angle)
    }

    /// Angle of q relative to the start of segment 0, in [0, 2π).
    func relativeAngle(_ q: V2) -> Double {
        var d = (atan2(q.y - center.y, q.x - center.x) - openAngle + Self.quarter / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if d < 0 { d += 2 * .pi }
        return d
    }

    /// Segment 0…3 of a point (by its angle only).
    func segment(_ q: V2) -> Int { min(3, Int(relativeAngle(q) / Self.quarter)) }

    static func isOpen(_ segment: Int) -> Bool { segment % 2 == 0 }

    /// Angular distance (radians) from q to the nearest boundary of its own segment.
    func boundaryDistance(_ q: V2) -> Double {
        let within = relativeAngle(q).truncatingRemainder(dividingBy: Self.quarter)
        return min(within, Self.quarter - within)
    }

    func radius(_ q: V2) -> Double { q.distance(to: center) }

    /// On the track within `tolerance` cm of its edges.
    func onTrack(_ q: V2, tolerance: Double = 2) -> Bool {
        let r = radius(q)
        return r >= inner - tolerance && r <= outer + tolerance
    }

    private func point(_ a: Double, _ r: Double) -> V2 { V2(center.x + r * cos(a), center.y + r * sin(a)) }

    /// Start angle (radians, arena) of segment k.
    func startAngle(_ k: Int) -> Double { openAngle - Self.quarter / 2 + Double(k) * Self.quarter }

    /// Annular sector of segment k (outer arc forward, inner arc back).
    func sector(_ k: Int, steps: Int = 24) -> [V2] {
        let a0 = startAngle(k)
        let outerArc = (0...steps).map { point(a0 + Self.quarter * Double($0) / Double(steps), outer) }
        let innerArc = (0...steps).reversed().map { point(a0 + Self.quarter * Double($0) / Double(steps), inner) }
        return outerArc + innerArc
    }

    /// The whole ring as one polygon (outer circle, then the inner circle in the opposite direction; the seam
    /// lies on a segment boundary). Even-odd and non-zero filling both leave the center empty.
    func annulus(steps: Int = 96) -> [V2] {
        let a0 = startAngle(0)
        let outerRing = (0...steps).map { point(a0 + 2 * .pi * Double($0) / Double(steps), outer) }
        let innerRing = (0...steps).reversed().map { point(a0 + 2 * .pi * Double($0) / Double(steps), inner) }
        return outerRing + innerRing
    }
}

// MARK: - Barnes holes

struct BarnesGeometry {
    let center: V2
    let radius: Double
    let holes: [V2]        // index 0 = target
    let holeRadius: Double
    let targetAngle: Double  // screen angle (deg) of the target from the center

    /// Signed hole offset from the target (−N/2 … N/2) for plots.
    func offset(_ i: Int) -> Int {
        let n = holes.count
        var o = i
        if o > n / 2 { o -= n }
        return o
    }

    static func from(_ cal: ArenaCalibration, params: AnalysisParams, mapping: ArenaMapping) -> BarnesGeometry? {
        guard cal.kind == .circle, let t = cal.markers["target"] else { return nil }
        let r = cal.diameterCM / 2
        let c = V2(r, r)
        let tp = mapping.toArena(t)
        let ring = max(tp.distance(to: c), 1)
        let base = atan2(tp.y - c.y, tp.x - c.x)
        let n = max(4, params.holeCount)
        let holes = (0..<n).map { k -> V2 in
            let a = base + 2 * Double.pi * Double(k) / Double(n)
            return V2(c.x + ring * cos(a), c.y + ring * sin(a))
        }
        return BarnesGeometry(center: c, radius: r, holes: holes, holeRadius: params.holeRadius, targetAngle: (tp - c).screenAngleDeg)
    }
}

// MARK: - Zone builder

enum ZoneBuilder {
    /// Outline of the arena itself.
    static func arenaZone(_ cal: ArenaCalibration, mapping: ArenaMapping) -> Zone? {
        let e = mapping.extent
        switch cal.kind {
        case .none: return nil
        case .rectangle: return Zone.rect("arena", L10n.tr("场地"), .arena, x: 0, y: 0, w: e.x, h: e.y)
        case .circle:
            if cal.ringWidthCM > 0, let g = ZeroMazeGeometry.from(cal, mapping: mapping) {
                return Zone(id: "arena", title: L10n.tr("场地"), role: .arena, shape: .polygon(g.annulus()))
            }
            return Zone.circle("arena", L10n.tr("场地"), .arena, V2(e.x / 2, e.y / 2), e.x / 2)
        case .plusMaze, .yMaze, .tMaze:
            guard let m = MazeGeometry.from(cal, mapping: mapping) else { return nil }
            // Not a single polygon; arms are added as separate zones.
            return Zone.circle("arena", "", .arena, m.center, 0.01)
        }
    }

    /// Boundaries in normalized arena X. Older sessions retain centered thirds.
    /// Keep a narrow but nonzero outer chamber on both sides.
    static func threeChamberBounds(_ p: AnalysisParams) -> (left: Double, right: Double) {
        let rawW = p.centerChamberFraction.isFinite ? p.centerChamberFraction : 1.0 / 3.0
        let w = clamp(rawW, 0.1, 0.8)
        let rawOffset = p.centerChamberOffset.isFinite ? p.centerChamberOffset : 0
        let mid = clamp(0.5 + rawOffset, 0.05 + w / 2, 0.95 - w / 2)
        return (mid - w / 2, mid + w / 2)
    }

    static func zones(_ s: Session, mapping: ArenaMapping) -> [Zone] {
        let cal = s.calibration
        let p = s.params
        let e = mapping.extent
        var z: [Zone] = []

        func marker(_ key: String) -> V2? { cal.marker(key, mapping: mapping).map { mapping.toArena($0) } }

        switch s.paradigm {
        case .openField, .spatialExploration, .headDirection, .dyadicSocial, .residentIntruder, .groupBehavior, .fearConditioning, .rotation, .poseOnly:
            if s.paradigm == .openField {
                let f = clamp(p.centerFraction, 0.05, 0.95)
                if cal.kind == .circle {
                    z.append(Zone.circle("center", L10n.tr("中央区"), .center, V2(e.x / 2, e.y / 2), e.x / 2 * f))
                } else if cal.kind == .rectangle {
                    z.append(Zone.rect("center", L10n.tr("中央区"), .center, x: e.x * (1 - f) / 2, y: e.y * (1 - f) / 2, w: e.x * f, h: e.y * f))
                    z.append(contentsOf: openFieldCornerZones(p, extent: e))
                }
            }
            if s.paradigm == .headDirection, p.hdReference == "cue", let q = marker("cue") {
                z.append(Zone.circle("cue", L10n.tr("提示卡"), .cue, q, 2))
            }

        case .threeChamber:
            let bounds = threeChamberBounds(p)
            let left = bounds.left * e.x, right = bounds.right * e.x
            z.append(Zone.rect("chL", L10n.tr("左箱"), .chamber, x: 0, y: 0, w: left, h: e.y))
            z.append(Zone.rect("chC", L10n.tr("中箱"), .chamber, x: left, y: 0, w: right - left, h: e.y))
            z.append(Zone.rect("chR", L10n.tr("右箱"), .chamber, x: right, y: 0, w: e.x - right, h: e.y))
            let novelty = s.phase == "Social novelty"
            for (key, side) in [("cupL", "L"), ("cupR", "R")] {
                guard let c = marker(key) else { continue }
                let isStim = p.stimSide == side
                let title: String
                let role: ZoneRole
                if novelty {
                    title = isStim ? L10n.tr("新陌生鼠") : L10n.tr("熟悉鼠")
                    role = isStim ? .novel : .familiar
                } else {
                    title = isStim ? L10n.tr("陌生鼠") : L10n.tr("空杯")
                    role = isStim ? .social : .object
                }
                z.append(Zone.circle(key, title, role, c, p.cupRadius))
                var sniff = Zone.circle(key + "_sniff", "", role, c, p.cupRadius + p.exploreMargin)
                sniff.showsLabel = false
                sniff.outlineOnly = true
                z.append(sniff)
            }

        case .socialInteraction:
            let (enc, iz) = enclosureRects(p, extent: e)
            z.append(iz)
            z.append(enc)
            z.append(contentsOf: cornerZones(p, extent: e))

        case .novelObject:
            for key in ["objA", "objB"] {
                guard let c = marker(key) else { continue }
                let label = key == "objA" ? "A" : "B"
                let isNovel = s.phase != "Training" && p.novelObject == label
                let title = s.phase == "Training" ? L10n.tr("物体 \(label)") : (isNovel ? L10n.tr("新 \(label)") : L10n.tr("旧 \(label)"))
                let role: ZoneRole = s.phase == "Training" ? .object : (isNovel ? .novel : .familiar)
                z.append(Zone.circle(key, title, role, c, p.objectRadius))
                var ex = Zone.circle(key + "_explore", "", role, c, p.objectRadius + p.exploreMargin)
                ex.showsLabel = false
                ex.outlineOnly = true
                z.append(ex)
            }

        case .lightDark, .passiveAvoidance:
            let f = clamp(p.lightFraction, 0.1, 0.9)
            let lw = e.x * f
            if p.lightOnLeft {
                z.append(Zone.rect("light", L10n.tr("明箱"), .light, x: 0, y: 0, w: lw, h: e.y))
                z.append(Zone.rect("dark", L10n.tr("暗箱"), .dark, x: lw, y: 0, w: e.x - lw, h: e.y))
            } else {
                z.append(Zone.rect("dark", L10n.tr("暗箱"), .dark, x: 0, y: 0, w: e.x - lw, h: e.y))
                z.append(Zone.rect("light", L10n.tr("明箱"), .light, x: e.x - lw, y: 0, w: lw, h: e.y))
            }

        case .looming:
            if let c = marker("shelter") {
                z.append(Zone.circle("shelter", L10n.tr("巢穴"), .shelter, c, p.shelterRadius))
            }
            if p.loomThreat, let t = marker("threat") {
                z.append(Zone.circle("threat", L10n.tr("威胁区"), .dark, t, max(0.5, p.loomThreatRadius)))
            }

        case .platformAvoidance:
            if let c = marker("platform") {
                z.append(platformZone(c, width: p.pmaPlatformWidth, height: p.pmaPlatformHeight))
            }
            if p.pmaReward, let r = marker("reward") {
                z.append(Zone.circle("reward", L10n.tr("奖励口区"), .novel, r, max(0.5, p.pmaRewardRadius)))
            }

        case .stepDown:
            if let c = marker("platform") {
                z.append(platformZone(c, width: p.sdPlatformWidth, height: p.sdPlatformHeight))
            }

        case .visualCliff:
            z.append(contentsOf: cliffZones(p, extent: e))

        case .marbleBurying:
            let r = max(0.2, p.mbDiameter / 2)
            for (i, m) in MarbleGrid.centers(cal, params: p, mapping: mapping).enumerated() {
                var mz = Zone.circle("marble_\(i + 1)", "\(i + 1)", .object, m, r)
                mz.showsLabel = false
                z.append(mz)
            }

        case .barnesMaze:
            if let b = BarnesGeometry.from(cal, params: p, mapping: mapping) {
                // Target quadrant (±45° around the target).
                let a0 = atan2(b.holes[0].y - b.center.y, b.holes[0].x - b.center.x)
                var quad: [V2] = [b.center]
                for k in 0...16 {
                    let a = a0 - Double.pi / 4 + Double.pi / 2 * Double(k) / 16
                    quad.append(V2(b.center.x + b.radius * cos(a), b.center.y + b.radius * sin(a)))
                }
                var q = Zone(id: "quadrant", title: L10n.tr("目标象限"), role: .quadrant, shape: .polygon(quad))
                q.showsLabel = false
                z.append(q)
                for (i, h) in b.holes.enumerated() {
                    var hz = Zone.circle(i == 0 ? "hole_target" : "hole_\(i)", i == 0 ? L10n.tr("目标") : "", i == 0 ? .target : .hole, h, b.holeRadius)
                    hz.showsLabel = i == 0
                    z.append(hz)
                }
            }

        case .placePreference:
            let split = clamp(p.ppSplit, 0.2, 0.8)
            let half = p.ppMiddle ? clamp(p.ppMiddleFraction, 0.02, 0.6) / 2 : 0
            let x0 = e.x * max(0.05, split - half), x1 = e.x * min(0.95, split + half)
            let pairedRight = p.ppPairedSide == "R"
            z.append(Zone.rect(pairedRight ? "unpaired" : "paired", pairedRight ? L10n.tr("非配对侧") : L10n.tr("配对侧"),
                               pairedRight ? .chamber : .target, x: 0, y: 0, w: x0, h: e.y))
            z.append(Zone.rect(pairedRight ? "paired" : "unpaired", pairedRight ? L10n.tr("配对侧") : L10n.tr("非配对侧"),
                               pairedRight ? .target : .chamber, x: x1, y: 0, w: e.x - x1, h: e.y))
            if p.ppMiddle {
                z.append(Zone.rect("middle", L10n.tr("中间区"), .mazeCenter, x: x0, y: 0, w: x1 - x0, h: e.y))
            }

        case .waterMaze:
            if let g = WaterMazeGeometry.from(cal, params: p, mapping: mapping) {
                var quad = Zone(id: "quadrant", title: L10n.tr("目标象限"), role: .quadrant, shape: .polygon(g.quadrantPolygon(0)))
                quad.showsLabel = false
                z.append(quad)
                if g.wallZone > 0 && g.wallZone < g.radius {
                    var wall = Zone.circle("wall", L10n.tr("贴壁区"), .periphery, g.center, g.radius - g.wallZone)
                    wall.showsLabel = false
                    wall.outlineOnly = true
                    z.append(wall)
                }
                var zone = Zone.circle("platform_zone", L10n.tr("平台区"), .target, g.platform, g.zoneRadius)
                zone.showsLabel = false
                zone.outlineOnly = true
                z.append(zone)
                z.append(Zone.circle("platform", s.phase == "Probe" ? L10n.tr("原平台") : L10n.tr("平台"), .target, g.platform, g.platformRadius))
            }

        case .elevatedZeroMaze:
            if let g = ZeroMazeGeometry.from(cal, mapping: mapping) {
                let titles = [L10n.tr("开放段 1"), L10n.tr("闭合段 1"), L10n.tr("开放段 2"), L10n.tr("闭合段 2")]
                let ids = ["segO1", "segC1", "segO2", "segC2"]
                for k in 0..<4 {
                    let open = ZeroMazeGeometry.isOpen(k)
                    z.append(Zone(id: ids[k], title: titles[k], role: open ? .open : .closed, shape: .polygon(g.sector(k))))
                }
            }

        case .noveltySuppressedFeeding:
            let f = clamp(p.centerFraction, 0.05, 0.95)
            if cal.kind == .circle {
                z.append(Zone.circle("center", L10n.tr("中央区"), .center, V2(e.x / 2, e.y / 2), e.x / 2 * f))
            } else if cal.kind == .rectangle {
                z.append(Zone.rect("center", L10n.tr("中央区"), .center, x: e.x * (1 - f) / 2, y: e.y * (1 - f) / 2, w: e.x * f, h: e.y * f))
            }
            if let c = marker("food") {
                z.append(Zone.circle("food", L10n.tr("食物区"), .target, c, max(0.5, p.nsfFoodRadius)))
            }

        case .elevatedPlusMaze:
            if let m = MazeGeometry.from(cal, mapping: mapping) {
                let openIdx = openArmIndices(p)
                let names = ["N", "E", "S", "W"]
                for i in 0..<min(4, m.ends.count) {
                    let open = openIdx.contains(i)
                    z.append(Zone(id: "arm\(names[i])", title: open ? L10n.tr("开放臂 \(names[i])") : L10n.tr("闭合臂 \(names[i])"), role: open ? .open : .closed, shape: .polygon(m.armPolygon(i))))
                }
                z.append(Zone(id: "center", title: L10n.tr("中央"), role: .mazeCenter, shape: .polygon(plusCenter(m))))
            }

        case .yMaze:
            if let m = MazeGeometry.from(cal, mapping: mapping) {
                for i in m.ends.indices {
                    z.append(Zone(id: "arm\(m.labels[i])", title: L10n.tr("臂 \(m.labels[i])"), role: .arm, shape: .polygon(m.armPolygon(i))))
                }
                z.append(Zone.circle("center", L10n.tr("中央"), .mazeCenter, m.center, m.centerRadius))
            }

        case .tMaze:
            if let m = MazeGeometry.from(cal, mapping: mapping) {
                let titles = [L10n.tr("起始臂"), L10n.tr("左臂"), L10n.tr("右臂")]
                for i in m.ends.indices {
                    z.append(Zone(id: "arm\(m.labels[i])", title: titles[min(i, 2)], role: .arm, shape: .polygon(m.armPolygon(i))))
                }
                z.append(Zone.circle("choice", L10n.tr("选择点"), .choice, m.center, m.armWidth * max(0.5, p.choiceRadiusFactor)))
            }
        }
        return z
    }

    /// A rectangular platform (cm, arena axes) centered on its handle (platform-mediated avoidance, step-down).
    static func platformZone(_ c: V2, width: Double, height: Double) -> Zone {
        let w = max(1, width), h = max(1, height)
        return Zone.rect("platform", L10n.tr("平台"), .target, x: c.x - w / 2, y: c.y - h / 2, w: w, h: h)
    }

    /// Visual cliff: the shallow side, the center board (neutral zone) and the deep side across the arena's length.
    static func cliffZones(_ p: AnalysisParams, extent e: V2) -> [Zone] {
        let half = clamp(p.vcCenterFraction, 0.02, 0.6) / 2
        let mid = clamp(p.vcSplit, 0.2, 0.8)
        let x0 = e.x * max(0.05, mid - half), x1 = e.x * min(0.95, mid + half)
        let deepRight = p.vcDeepSide != "L"
        let left = Zone.rect(deepRight ? "shallow" : "deep", deepRight ? L10n.tr("浅侧") : L10n.tr("深侧"), deepRight ? .light : .dark,
                             x: 0, y: 0, w: x0, h: e.y)
        let right = Zone.rect(deepRight ? "deep" : "shallow", deepRight ? L10n.tr("深侧") : L10n.tr("浅侧"), deepRight ? .dark : .light,
                              x: x1, y: 0, w: e.x - x1, h: e.y)
        let center = Zone.rect("center", L10n.tr("中性区"), .mazeCenter, x: x0, y: 0, w: x1 - x0, h: e.y)
        return [left, center, right]
    }

    /// Arm indices (0 = N, 1 = E, 2 = S, 3 = W) that are open in the plus maze.
    static func openArmIndices(_ p: AnalysisParams) -> Set<Int> {
        p.openAxis == "EW" ? [1, 3] : [0, 2]
    }

    /// Center square of the plus maze, oriented by the N–S and E–W axes.
    static func plusCenter(_ m: MazeGeometry) -> [V2] {
        guard m.ends.count == 4 else { return [] }
        let u = (m.ends[0] - m.ends[2]).normalized   // S → N
        let v = (m.ends[1] - m.ends[3]).normalized   // W → E
        let h = m.armWidth / 2
        return [m.center + u * h + v * h, m.center + u * h - v * h, m.center - u * h - v * h, m.center - u * h + v * h]
    }

    /// Enclosure and interaction zone for the social interaction test.
    static func enclosureRects(_ p: AnalysisParams, extent e: V2) -> (Zone, Zone) {
        let ew = p.enclosureWidth, ed = p.enclosureDepth
        let iw = p.izWidth, id = p.izDepth
        switch p.enclosureWall {
        case "bottom":
            return (Zone.rect("enclosure", L10n.tr("网罩"), .enclosure, x: (e.x - ew) / 2, y: e.y - ed, w: ew, h: ed),
                    Zone.rect("iz", L10n.tr("互动区"), .interaction, x: (e.x - iw) / 2, y: e.y - id, w: iw, h: id))
        case "left":
            return (Zone.rect("enclosure", L10n.tr("网罩"), .enclosure, x: 0, y: (e.y - ew) / 2, w: ed, h: ew),
                    Zone.rect("iz", L10n.tr("互动区"), .interaction, x: 0, y: (e.y - iw) / 2, w: id, h: iw))
        case "right":
            return (Zone.rect("enclosure", L10n.tr("网罩"), .enclosure, x: e.x - ed, y: (e.y - ew) / 2, w: ed, h: ew),
                    Zone.rect("iz", L10n.tr("互动区"), .interaction, x: e.x - id, y: (e.y - iw) / 2, w: id, h: iw))
        default:
            return (Zone.rect("enclosure", L10n.tr("网罩"), .enclosure, x: (e.x - ew) / 2, y: 0, w: ew, h: ed),
                    Zone.rect("iz", L10n.tr("互动区"), .interaction, x: (e.x - iw) / 2, y: 0, w: iw, h: id))
        }
    }

    // MARK: Open-field corner zones

    /// Default side of an open-field corner zone: 25 % of the shorter side, the four corner squares of a 4 × 4 grid
    /// (10 × 10 cm in a 40 × 40 cm box).
    static let defaultCornerFraction = 0.25

    /// Side of the open-field corner squares as a fraction of the arena's shorter side: the setting (default 25 %),
    /// limited so that a corner never overlaps the center zone (at most (1 − center fraction) / 2; with the default
    /// 50 % center the corners touch it only at a point). `limited`: the setting was reduced.
    static func openFieldCornerFraction(_ p: AnalysisParams) -> (fraction: Double, limited: Bool) {
        let requested = clamp(p.cornerFraction ?? defaultCornerFraction, 0.05, 0.45)
        let f = clamp(p.centerFraction, 0.05, 0.95)
        let maximum = (1 - f) / 2
        return requested > maximum + 1e-9 ? (maximum, true) : (requested, false)
    }

    /// The four open-field corner squares (top-left, top-right, bottom-right, bottom-left), side = fraction × shorter side.
    static func openFieldCornerZones(_ p: AnalysisParams, extent e: V2) -> [Zone] {
        let c = openFieldCornerFraction(p).fraction * min(e.x, e.y)
        guard c > 0 else { return [] }
        return [Zone.rect("corner1", L10n.tr("角落"), .corner, x: 0, y: 0, w: c, h: c),
                Zone.rect("corner2", L10n.tr("角落"), .corner, x: e.x - c, y: 0, w: c, h: c),
                Zone.rect("corner3", L10n.tr("角落"), .corner, x: e.x - c, y: e.y - c, w: c, h: c),
                Zone.rect("corner4", L10n.tr("角落"), .corner, x: 0, y: e.y - c, w: c, h: c)]
    }

    /// The two corner zones on the wall opposite the enclosure.
    static func cornerZones(_ p: AnalysisParams, extent e: V2) -> [Zone] {
        let c = p.cornerSize
        switch p.enclosureWall {
        case "bottom":
            return [Zone.rect("corner1", L10n.tr("角落"), .corner, x: 0, y: 0, w: c, h: c), Zone.rect("corner2", L10n.tr("角落"), .corner, x: e.x - c, y: 0, w: c, h: c)]
        case "left":
            return [Zone.rect("corner1", L10n.tr("角落"), .corner, x: e.x - c, y: 0, w: c, h: c), Zone.rect("corner2", L10n.tr("角落"), .corner, x: e.x - c, y: e.y - c, w: c, h: c)]
        case "right":
            return [Zone.rect("corner1", L10n.tr("角落"), .corner, x: 0, y: 0, w: c, h: c), Zone.rect("corner2", L10n.tr("角落"), .corner, x: 0, y: e.y - c, w: c, h: c)]
        default:
            return [Zone.rect("corner1", L10n.tr("角落"), .corner, x: 0, y: e.y - c, w: c, h: c), Zone.rect("corner2", L10n.tr("角落"), .corner, x: e.x - c, y: e.y - c, w: c, h: c)]
        }
    }
}

extension ZoneBuilder {
    /// Zones of a calibration and its parameters without a whole session (the Mac calibration editor).
    static func zones(paradigm: Paradigm, phase: String, calibration: ArenaCalibration,
                      params: AnalysisParams, mapping: ArenaMapping) -> [Zone] {
        var s = Session(paradigm: paradigm)
        s.phase = phase
        s.calibration = calibration
        s.params = params
        return zones(s, mapping: mapping)
    }
}

// MARK: - Marble grid (marble burying)

enum MarbleGrid {
    /// Marble centers (arena cm), row by row from the top-left marble, interpolated between the four corner handles
    /// (1 top-left, 2 top-right, 3 bottom-right, 4 bottom-left). Empty when a handle is missing.
    static func centers(_ cal: ArenaCalibration, params p: AnalysisParams, mapping: ArenaMapping) -> [V2] {
        let keys = ["g1", "g2", "g3", "g4"]
        let corners = keys.compactMap { k in cal.markers[k].map { mapping.toArena($0) } }
        guard corners.count == 4 else { return [] }
        let rows = max(1, min(12, p.mbRows)), cols = max(1, min(12, p.mbCols))
        var out: [V2] = []
        for r in 0..<rows {
            let v = rows > 1 ? Double(r) / Double(rows - 1) : 0.5
            for c in 0..<cols {
                let u = cols > 1 ? Double(c) / Double(cols - 1) : 0.5
                let top = corners[0] * (1 - u) + corners[1] * u
                let bottom = corners[3] * (1 - u) + corners[2] * u
                out.append(top * (1 - v) + bottom * v)
            }
        }
        return out
    }

    /// The same centers in upright image pixels, with the marble radius in pixels (for reading the video).
    static func pixelCenters(_ cal: ArenaCalibration, params p: AnalysisParams, frameSize: V2) -> (centers: [V2], radius: Double) {
        let mapping = ArenaMapper.mapping(cal, frameSize: frameSize)
        let centers = self.centers(cal, params: p, mapping: mapping).map { mapping.toImage($0) }
        return (centers, max(1, p.mbDiameter / 2 * mapping.pxPerUnit))
    }

    /// Everything the marble samples depend on: positions, size, interval and time range (a new value = sample again).
    static func sampleKey(_ cal: ArenaCalibration, params p: AnalysisParams, frameSize: V2, videoName: String, range: (Double, Double)) -> String {
        let g = pixelCenters(cal, params: p, frameSize: frameSize)
        // "mb1": version of how the samples are read (radii, luminance); a new version reads the video again.
        var parts = ["mb1", videoName, String(format: "%.0fx%.0f", frameSize.x, frameSize.y), String(format: "r%.1f", g.radius),
                     String(format: "i%.3f", max(0.1, p.mbSampleInterval)), String(format: "t%.2f-%.2f", range.0, range.1)]
        parts += g.centers.map { String(format: "%.1f,%.1f", $0.x, $0.y) }
        return parts.joined(separator: "|")
    }
}
