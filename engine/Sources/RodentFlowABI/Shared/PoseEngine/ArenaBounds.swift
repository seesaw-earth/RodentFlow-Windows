// ArenaBounds.swift — RodentFlow 2.0 (build 10): did the tracking leave the calibrated arena?
//
// Only the tracking RESULT is checked. The video frames given to the model, the model, the tracker and the
// computed measures are exactly as before; a frame whose tracked body point lies outside the calibrated
// arena (by more than a small tolerance) is flagged:
//   • in the review (a "Outside the calibrated arena" row on the timeline, a note on the frame, and a
//     warning with how much of the session it concerns);
//   • in the data (per-frame columns `outside_arena` = 1 and `outside_arena_dist_cm` = how far outside).
// Usually such frames are a tracking error (an object, a hand or a reflection outside the arena taken for
// the animal), sometimes the animal really left the arena. Either way the user decides; nothing is removed.

import Foundation

struct ArenaBounds {
    enum Shape {
        /// Box: the arena is [0, w] × [0, h] in arena units (the calibration homography's target).
        case rectangle(V2)
        case circle(center: V2, radius: Double)
        /// Ring track (elevated zero maze): inside the outer circle and outside the inner one.
        case annulus(center: V2, outer: Double, inner: Double)
        /// Maze: one rectangle per arm, from the center to the arm's end (the arms overlap in the center).
        case arms(center: V2, ends: [V2], halfWidth: Double)
    }

    let shape: Shape
    /// Image pixels (upright frame) ↔ arena units (cm).
    let mapping: ArenaMapping
    /// Distance beyond the arena's edge that still counts as inside (cm): a rearing animal seen in
    /// perspective, a head dip or body over a maze edge, a slightly imprecise calibration.
    let tolerance: Double

    /// The tolerance is the larger of 3 cm and 3 % of the arena's size.
    static let minimumTolerance = 3.0
    static let toleranceFraction = 0.03

    /// The calibrated arena of a frame of `frameSize` pixels; nil without calibration (nothing to compare with).
    static func make(_ cal: ArenaCalibration, frameSize: V2) -> ArenaBounds? {
        make(cal, mapping: ArenaMapper.mapping(cal, frameSize: frameSize))
    }

    static func make(_ cal: ArenaCalibration, mapping: ArenaMapping) -> ArenaBounds? {
        guard mapping.isMetric else { return nil }
        let shape: Shape
        let size: Double
        switch cal.kind {
        case .none:
            return nil
        case .rectangle:
            let e = mapping.extent
            guard e.x > 0, e.y > 0 else { return nil }
            shape = .rectangle(e)
            size = max(e.x, e.y)
        case .circle:
            let r = mapping.extent.x / 2
            guard r > 0 else { return nil }
            if cal.ringWidthCM > 0 {
                shape = .annulus(center: V2(r, r), outer: r, inner: max(0, r - min(cal.ringWidthCM, r * 0.9)))
            } else {
                shape = .circle(center: V2(r, r), radius: r)
            }
            size = 2 * r
        case .plusMaze, .yMaze, .tMaze:
            guard let m = MazeGeometry.from(cal, mapping: mapping), !m.ends.isEmpty else { return nil }
            shape = .arms(center: m.center, ends: m.ends, halfWidth: m.armWidth / 2)
            size = 2 * (m.ends.map { $0.distance(to: m.center) }.max() ?? 0)
        }
        guard size.isFinite, size > 0 else { return nil }
        return ArenaBounds(shape: shape, mapping: mapping,
                           tolerance: max(minimumTolerance, toleranceFraction * size))
    }

    /// How far a point (arena units) lies outside the arena: 0 inside or on the edge.
    func distanceOutside(_ q: V2) -> Double {
        guard q.isFinite else { return .nan }
        switch shape {
        case .rectangle(let e):
            let dx = max(0, -q.x, q.x - e.x), dy = max(0, -q.y, q.y - e.y)
            return (dx * dx + dy * dy).squareRoot()
        case .circle(let c, let r):
            return max(0, q.distance(to: c) - r)
        case .annulus(let c, let outer, let inner):
            let d = q.distance(to: c)
            return max(0, d - outer, inner - d)
        case .arms(let c, let ends, let hw):
            var best = Double.infinity
            for end in ends {
                let axis = end - c
                let len = axis.length
                guard len > 1e-9 else { continue }
                let dir = axis / len
                let d = q - c
                let along = d.dot(dir), across = abs(d.dot(dir.perp))
                let da = max(0, -along, along - len), dw = max(0, across - hw)
                best = min(best, (da * da + dw * dw).squareRoot())
            }
            return best.isFinite ? best : .nan
        }
    }

    /// The same for a point in upright-frame pixels.
    func distanceOutside(pixel p: V2) -> Double {
        distanceOutside(mapping.toArena(p))
    }

    /// Outside by more than the tolerance.
    func isOutside(_ q: V2) -> Bool {
        let d = distanceOutside(q)
        return d.isFinite && d > tolerance
    }

    /// The point a detection is judged by: its body center when that keypoint is confident, otherwise the
    /// mean of its confident keypoints (nil when none is). `point(k)` gives keypoint k in pixels with its
    /// confidence.
    static func bodyPoint(minConf: Float, _ point: (Int) -> (V2, Float)?) -> V2? {
        if let (p, c) = point(KP.bodyCenter.rawValue), c >= minConf, p.isFinite { return p }
        var sum = V2.zero
        var n = 0.0
        for k in 0..<kKeypointCount {
            guard let (p, c) = point(k), c >= minConf, p.isFinite else { continue }
            sum = sum + p
            n += 1
        }
        return n > 0 ? sum / n : nil
    }

    /// Body point of animal `a` in frame `i` of a pose track (pixels); nil when the animal was not detected.
    static func bodyPoint(_ track: PoseTrack, _ i: Int, _ a: Int, minConf: Float) -> V2? {
        guard track.conf(i, a) > kAnalysisMinScore else { return nil }
        return bodyPoint(minConf: minConf) { k in
            let pt = track.point(i, a, k)
            return (V2(Double(pt.x), Double(pt.y)), pt.c)
        }
    }
}

/// Frames of one animal outside the calibrated arena.
struct OutsideArenaFrames {
    /// Per frame: tracked body point outside the arena by more than the tolerance.
    var flags: [Bool]
    /// Per frame: distance outside the arena's edge (arena units; 0 inside, NaN without a tracked body point).
    var distance: [Double]

    var count: Int { flags.lazy.filter { $0 }.count }

    /// From raw body points in arena units (NaN where nothing was tracked).
    static func make(_ body: Series2, bounds: ArenaBounds) -> OutsideArenaFrames {
        let n = body.x.count
        var flags = [Bool](repeating: false, count: n)
        var distance = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            guard let q = body.p(i) else { continue }
            let d = bounds.distanceOutside(q)
            distance[i] = d
            flags[i] = d.isFinite && d > bounds.tolerance
        }
        return OutsideArenaFrames(flags: flags, distance: distance)
    }
}
