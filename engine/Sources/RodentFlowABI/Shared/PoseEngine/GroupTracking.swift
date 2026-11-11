// GroupTracking.swift — many animals in one frame (group behaviour task).
//
// The group model (GroupPose6) finds every mouse per frame. Two steps turn that into N identities:
//
// 1. Pose NMS. The end-to-end head sometimes returns two boxes on one mouse, both with a high score. A detection is
//    dropped when its nose and tail base are, on average, within 0.25 body lengths of a higher-scoring one. Head-to-tail
//    neighbours are kept: their noses and tail bases are far apart.
// 2. Known-count tracker. The number of animals is known and fixed, so the identities are always these N. Each frame the
//    detections are matched to the tracks by the mean distance of the five keypoints the model predicts directly
//    (Hungarian algorithm, constant-velocity prediction). A track without a match keeps going and its gate widens with
//    the frames missed; extra detections never start a new identity. Empty identities at the start are given to
//    detections far from every existing track.
//
// Validated in Python against UDMT (7 and 10 mice) and MouseSIS (5–7 mice): group_4_tracking.ipynb. The same arithmetic
// is tested against that Python code in tools/tests/GroupTrackingTest.swift. Identities can still swap when mice touch;
// the reports say so.
//
// Foundation only, so it can be tested anywhere.

import Foundation

/// Fewest / most animals a group session can have, and the default. The group model was tested with 2–10 mice per frame;
/// two animals use the two-animal tasks.
let kGroupMinAnimals = 3
let kGroupMaxAnimals = 10
let kGroupDefaultAnimals = 4

/// Minimum-cost assignment of a rectangular cost matrix (Hungarian algorithm): every row or every column is matched.
enum Assignment {
    static func solve(_ cost: [[Double]]) -> [(row: Int, column: Int)] {
        let rows = cost.count
        guard rows > 0, let columns = cost.first?.count, columns > 0 else { return [] }
        let flip = rows > columns
        let n = flip ? columns : rows, m = flip ? rows : columns
        func a(_ i: Int, _ j: Int) -> Double { flip ? cost[j][i] : cost[i][j] }
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: m + 1)
        var match = [Int](repeating: 0, count: m + 1), way = [Int](repeating: 0, count: m + 1)
        for i in stride(from: 1, through: n, by: 1) {
            match[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1)
            var used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true
                let i0 = match[j0]
                var delta = Double.infinity
                var j1 = 0
                for j in stride(from: 1, through: m, by: 1) where !used[j] {
                    let cur = a(i0 - 1, j - 1) - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m {
                    if used[j] { u[match[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while match[j0] != 0
            repeat {
                let j1 = way[j0]
                match[j0] = match[j1]
                j0 = j1
            } while j0 != 0
        }
        var out: [(row: Int, column: Int)] = []
        for j in stride(from: 1, through: m, by: 1) where match[j] != 0 {
            out.append(flip ? (row: j - 1, column: match[j] - 1) : (row: match[j] - 1, column: j - 1))
        }
        return out.sorted { $0.row < $1.row }
    }
}

enum GroupPoseNMS {
    static let tolerance = 0.25

    /// Detections without the ones that repeat a higher-scoring detection, highest score first.
    static func filter(_ detections: [AnimalPose], tolerance tol: Double = tolerance) -> [AnimalPose] {
        let nose = KP.nose.rawValue, tail = KP.tailBase.rawValue
        var kept: [AnimalPose] = []
        for c in detections.filter(\.detected).sorted(by: { $0.conf > $1.conf }) {
            let length = max(Double(hypot(c.x[nose] - c.x[tail], c.y[nose] - c.y[tail])), 1e-6)
            let duplicate = kept.contains { k in
                let dn = Double(hypot(c.x[nose] - k.x[nose], c.y[nose] - k.y[nose]))
                let dt = Double(hypot(c.x[tail] - k.x[tail], c.y[tail] - k.y[tail]))
                return (dn + dt) / 2 / length < tol
            }
            if !duplicate { kept.append(c) }
        }
        return kept
    }
}

/// Keeps N identities over a video (see the top of the file). Positions are per processed frame.
struct GroupIdentityTracker {
    /// The five keypoints the model predicts directly (the body center is derived).
    private static let direct = [KP.nose.rawValue, KP.leftEar.rawValue, KP.rightEar.rawValue, KP.neck.rawValue, KP.tailBase.rawValue]
    /// Body length is estimated from the detections of the first frames.
    private static let lengthFrames = 200

    let animals: Int
    let minScore: Float
    private let fixedLength: Double?
    private let fallbackLength: Double
    private var started = false
    private var x: [[Double]]
    private var y: [[Double]]
    private var vx: [[Double]]
    private var vy: [[Double]]
    private var missed: [Int]
    private var alive: [Bool]
    private var lengths: [Double] = []
    private var framesSeen = 0
    /// Nose → tail-base distance used for the gates (px).
    private(set) var bodyLength: Double

    /// `bodyLength`: fixed length (px) instead of the estimate from the first frames.
    init(animals: Int, frameSize: V2, minScore: Float = 0.25, bodyLength: Double? = nil) {
        self.animals = max(1, animals)
        self.minScore = minScore
        fixedLength = bodyLength
        let diag = (frameSize.x * frameSize.x + frameSize.y * frameSize.y).squareRoot()
        fallbackLength = max(0.06 * diag, 8)
        self.bodyLength = bodyLength ?? max(0.06 * diag, 8)
        let empty = [[Double]](repeating: [Double](repeating: .nan, count: kKeypointCount), count: max(1, animals))
        x = empty
        y = empty
        let zero = [[Double]](repeating: [Double](repeating: 0, count: kKeypointCount), count: max(1, animals))
        vx = zero
        vy = zero
        missed = [Int](repeating: 0, count: max(1, animals))
        alive = [Bool](repeating: false, count: max(1, animals))
    }

    /// Continues from the last frame of a resumed run. Animals not detected in that frame are found again like new ones.
    mutating func seed(_ poses: [AnimalPose], bodyLength typical: Double? = nil) {
        for a in 0..<min(animals, poses.count) where poses[a].detected {
            x[a] = poses[a].x.map(Double.init)
            y[a] = poses[a].y.map(Double.init)
            alive[a] = true
        }
        started = alive.contains(true)
        if fixedLength == nil, let typical, typical > 0 {
            bodyLength = typical
            framesSeen = Self.lengthFrames   // no further estimate
        }
    }

    /// Current position of every track (nil = identity not started); includes predicted positions of lost animals.
    func positions() -> [(x: [Double], y: [Double])?] {
        (0..<animals).map { alive[$0] ? (x[$0], y[$0]) : nil }
    }

    /// The animals of this frame in identity order; `.missing` where an animal has no detection (its track keeps going).
    mutating func update(_ detections: [AnimalPose]) -> [AnimalPose] {
        let candidates = GroupPoseNMS.filter(detections.filter { $0.detected && $0.conf > minScore })
        observeLengths(candidates)
        var out = [AnimalPose](repeating: .missing, count: animals)
        if !started {
            for (a, c) in candidates.prefix(animals).enumerated() {
                x[a] = c.x.map(Double.init)
                y[a] = c.y.map(Double.init)
                alive[a] = true
                out[a] = c
            }
            started = alive.contains(true)
            return out
        }
        let live = (0..<animals).filter { alive[$0] }
        var used = [Bool](repeating: false, count: candidates.count)
        var hit = [Bool](repeating: false, count: animals)
        // Constant-velocity prediction.
        var px = x, py = y
        for a in live {
            for k in 0..<kKeypointCount {
                px[a][k] = x[a][k] + vx[a][k]
                py[a][k] = y[a][k] + vy[a][k]
            }
        }
        if !candidates.isEmpty && !live.isEmpty {
            let huge = 1e6
            var cost = [[Double]](repeating: [Double](repeating: huge, count: candidates.count), count: live.count)
            for (r, a) in live.enumerated() {
                let gate = min(1.0 + 0.25 * Double(missed[a]), 6.0)
                for (s, c) in candidates.enumerated() {
                    var sum = 0.0
                    for k in Self.direct {
                        let dx = px[a][k] - Double(c.x[k]), dy = py[a][k] - Double(c.y[k])
                        sum += (dx * dx + dy * dy).squareRoot()
                    }
                    let d = sum / Double(Self.direct.count) / bodyLength
                    if d < gate { cost[r][s] = d }
                }
            }
            for pair in Assignment.solve(cost) where cost[pair.row][pair.column] < huge {
                let a = live[pair.row], c = candidates[pair.column]
                for k in 0..<kKeypointCount {
                    let nx = Double(c.x[k]), ny = Double(c.y[k])
                    // Right after a gap the position jumps: that jump is not a velocity.
                    vx[a][k] = missed[a] > 0 ? 0 : 0.7 * vx[a][k] + 0.3 * (nx - x[a][k])
                    vy[a][k] = missed[a] > 0 ? 0 : 0.7 * vy[a][k] + 0.3 * (ny - y[a][k])
                    x[a][k] = nx
                    y[a][k] = ny
                }
                missed[a] = 0
                hit[a] = true
                used[pair.column] = true
                out[a] = c
            }
        }
        for a in live where !hit[a] {
            missed[a] += 1
            x[a] = px[a]
            y[a] = py[a]
            for k in 0..<kKeypointCount {
                vx[a][k] *= 0.8
                vy[a][k] *= 0.8
            }
        }
        // Identities still empty (not all animals were visible at the start).
        for (s, c) in candidates.enumerated() where !used[s] {
            guard let a = alive.firstIndex(of: false) else { break }
            if !isNearTrack(c) {
                x[a] = c.x.map(Double.init)
                y[a] = c.y.map(Double.init)
                alive[a] = true
                out[a] = c
            }
        }
        return out
    }

    private func isNearTrack(_ c: AnimalPose) -> Bool {
        var best = Double.infinity
        for a in 0..<animals where alive[a] {
            var sum = 0.0
            for k in Self.direct {
                let dx = x[a][k] - Double(c.x[k]), dy = y[a][k] - Double(c.y[k])
                sum += (dx * dx + dy * dy).squareRoot()
            }
            best = min(best, sum / Double(Self.direct.count))
        }
        return best < bodyLength
    }

    private mutating func observeLengths(_ candidates: [AnimalPose]) {
        guard fixedLength == nil, framesSeen < Self.lengthFrames else { return }
        framesSeen += 1
        let nose = KP.nose.rawValue, tail = KP.tailBase.rawValue
        for c in candidates {
            let l = Double(hypot(c.x[nose] - c.x[tail], c.y[nose] - c.y[tail]))
            if l.isFinite && l > 0 { lengths.append(l) }
        }
        guard !lengths.isEmpty else { return }
        let s = lengths.sorted()
        bodyLength = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
