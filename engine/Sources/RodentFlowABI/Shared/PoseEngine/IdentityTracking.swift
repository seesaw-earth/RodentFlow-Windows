// IdentityTracking.swift — keeping the identities of two animals apart (two-animal mode).
//
// Two stages work together:
//
// 1. OnlineIdentityTracker — during inference, frame by frame. It decides which detections are
//    the two animals and keeps their order consistent wherever that is clear:
//      · candidates down to a low score (touching / partly hidden animals often score low)
//      · duplicate suppression (two boxes on one animal)
//      · matching against a velocity-predicted position, the keypoints of the previous frame
//        and the body axis (an animal cannot turn around between two frames)
//      · two rounds: confident detections first, low-score ones only for animals still unmatched
//
// 2. IdentityResolver — after inference, over the whole video. The video is split into
//    segments in which the order is unambiguous; contacts, merges and gaps separate them. With
//    two animals the identity problem is then one binary choice per segment (straight or
//    swapped), decided from
//      · motion on both sides of each break (forward and backward extrapolation meet in the
//        middle) and the body axis before / after it,
//      · when the animals differ (fur colour, marks, size), a per-video appearance model learned
//        from the clear segments — within a segment the two tracks are known to be different
//        animals, so no labels are needed,
//    and the chain of choices is solved exactly by dynamic programming. Decisions with a small
//    cost margin are flagged for review; a manual correction locks a segment and re-solves the
//    rest ("swap from here"), or reverses the segments of a chosen time range, widened to the
//    contacts around it, and keeps everything outside as shown ("swap in a time range").
//
// Foundation only, so it can be tested anywhere.

import Foundation

// MARK: - Flags and summary

/// Per-frame identity flags stored with a two-animal track (`PoseTrack.flags`).
enum IdentityFlag {
    /// A / B of this frame are stored in the opposite order to the online tracker's output.
    static let swapped: UInt8 = 1 << 0
    /// One detection stands for both touching / overlapping animals.
    static let merged: UInt8 = 1 << 1
    /// Inside or right after an identity decision made with low confidence.
    static let uncertain: UInt8 = 1 << 2
    /// Order confirmed by the user; kept when the video is re-solved.
    static let locked: UInt8 = 1 << 3
    /// Around a decision where body size while walking and activity on the two sides disagree
    /// with the labels: likely swapped, worth checking first.
    static let suspect: UInt8 = 1 << 4
    /// Before the user's latest correction: order and review marks kept exactly as shown when
    /// the video is re-solved (the part after a correction is free to follow it).
    static let held: UInt8 = 1 << 5
    /// Review marks (recomputed on every solve, except where held).
    static let marks: UInt8 = uncertain | suspect
}

/// Summary of the whole-video identity pass, stored with the track.
struct IdentityInfo: Codable, Equatable {
    /// Identity decisions (breaks between unambiguous segments).
    var events = 0
    /// Decisions with a small cost margin (flagged for review).
    var uncertainEvents = 0
    var segments = 0
    /// The per-video appearance / size model was informative and used.
    var appearanceUsed = false
    /// Separation of the two animals along the appearance axis (in noise units).
    var appearanceSeparation: Double = 0
    /// Segments whose order was set by the user.
    var lockedSegments = 0
    var mergedFrames = 0
    /// Decisions where size / activity suggest the labels are swapped (hints).
    var suspectEvents = 0
    /// Weak per-video cues (size while walking, activity) were consistent and joined the
    /// decisions.
    var cuesUsed = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case events, uncertainEvents, segments, appearanceUsed, appearanceSeparation, lockedSegments, mergedFrames, suspectEvents, cuesUsed
    }

    // Tolerant: files written by other versions may lack or add fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IdentityInfo()
        events = c.v(.events, d.events)
        uncertainEvents = c.v(.uncertainEvents, d.uncertainEvents)
        segments = c.v(.segments, d.segments)
        appearanceUsed = c.v(.appearanceUsed, d.appearanceUsed)
        appearanceSeparation = c.v(.appearanceSeparation, d.appearanceSeparation)
        lockedSegments = c.v(.lockedSegments, d.lockedSegments)
        mergedFrames = c.v(.mergedFrames, d.mergedFrames)
        suspectEvents = c.v(.suspectEvents, d.suspectEvents)
        cuesUsed = c.v(.cuesUsed, d.cuesUsed)
    }
}

// MARK: - Body geometry

enum BodyGeometry {
    static let minConf: Float = 0.3

    @inline(__always)
    static func point(_ p: AnimalPose, _ k: KP, minConf: Float = minConf) -> V2? {
        let i = k.rawValue
        guard p.detected, p.kconf[i] >= minConf, p.x[i].isFinite, p.y[i].isFinite else { return nil }
        return V2(Double(p.x[i]), Double(p.y[i]))
    }

    /// Body center, else the neck–tail midpoint, else the mean of the confident keypoints.
    static func anchor(_ p: AnimalPose, minConf: Float = minConf) -> V2? {
        if let b = point(p, .bodyCenter, minConf: minConf) { return b }
        if let n = point(p, .neck, minConf: minConf), let t = point(p, .tailBase, minConf: minConf) { return V2.mid(n, t) }
        return p.centroid(minConf: minConf)
    }

    /// Unit vector from the tail end toward the head.
    static func axis(_ p: AnimalPose, minConf: Float = minConf) -> V2? {
        let head = point(p, .neck, minConf: minConf) ?? point(p, .nose, minConf: minConf)
        let tail = point(p, .tailBase, minConf: minConf) ?? point(p, .bodyCenter, minConf: minConf)
        guard let head, let tail else { return nil }
        let v = head - tail
        let l = v.length
        return l > 1e-6 ? v / l : nil
    }

    /// Nose → tail-base distance.
    static func length(_ p: AnimalPose, minConf: Float = minConf) -> Double? {
        guard let n = point(p, .nose, minConf: minConf), let t = point(p, .tailBase, minConf: minConf) else { return nil }
        return n.distance(to: t)
    }

    /// Angle between two unit vectors scaled to 0…1 (1 = opposite directions).
    static func turn(_ a: V2?, _ b: V2?) -> Double? {
        guard let a, let b else { return nil }
        return acos(max(-1, min(1, a.dot(b)))) / .pi
    }

    /// Mean distance between corresponding keypoints confident in both poses (`b` shifted by
    /// `shift`); nil when fewer than `minCommon` keypoints are shared.
    static func keypointDistance(_ a: AnimalPose, _ b: AnimalPose, shift: V2 = .zero, minCommon: Int = 3,
                                 minConf: Float = minConf) -> Double? {
        guard a.detected, b.detected else { return nil }
        var sum = 0.0
        var m = 0
        for k in 0..<kKeypointCount where a.kconf[k] >= minConf && b.kconf[k] >= minConf {
            let dx = Double(a.x[k]) - (Double(b.x[k]) + shift.x)
            let dy = Double(a.y[k]) - (Double(b.y[k]) + shift.y)
            sum += (dx * dx + dy * dy).squareRoot()
            m += 1
        }
        return m >= minCommon ? sum / Double(m) : nil
    }

    /// Typical nose → tail-base distance of all detected animals (px), nil if too few samples.
    static func typicalLength(_ track: PoseTrack, minConf: Float = minConf) -> Double? {
        var d: [Double] = []
        let n = track.count
        let step = max(1, n / 4000)
        var i = 0
        while i < n {
            for a in 0..<track.animalCount where track.conf(i, a) > 0 {
                let nose = track.point(i, a, KP.nose.rawValue)
                let tail = track.point(i, a, KP.tailBase.rawValue)
                if nose.c >= minConf && tail.c >= minConf {
                    d.append(Double(hypot(nose.x - tail.x, nose.y - tail.y)))
                }
            }
            i += step
        }
        guard d.count >= 10 else { return nil }
        d.sort()
        return d[d.count / 2]
    }
}

// MARK: - Online tracker (during inference)

struct OnlineIdentityTracker {
    struct Settings {
        /// Detections at or above this score are trusted on their own (UltralyticsYOLO default).
        var highScore: Float = 0.25
        /// Lowest score considered at all; used only to continue an animal that is already tracked.
        var lowScore: Float = 0.1
        /// Return low-score matches as poses. They are stored for the identity pass (no false
        /// "merged" contacts or broken tracks when a score dips for a frame); the analysis ignores
        /// detections ≤ kAnalysisMinScore, so every metric uses the same detections as before.
        var keepLowScore = true
    }

    private struct Slot {
        var pose: AnimalPose
        var anchor: V2
        var axis: V2?
        var velocity = V2.zero   // px/s
        var time: Double
    }

    let settings: Settings
    private let fallbackLength: Double
    private var slots: [Slot?] = [nil, nil]
    private var lengthSamples: [Double] = []
    private var lengthCursor = 0
    private var samplesSinceEstimate = 0
    /// Running estimate of the nose → tail-base distance (px).
    private(set) var bodyLength: Double

    init(frameSize: V2, settings: Settings = Settings()) {
        self.settings = settings
        let diag = (frameSize.x * frameSize.x + frameSize.y * frameSize.y).squareRoot()
        fallbackLength = max(0.06 * diag, 8)
        bodyLength = fallbackLength
    }

    /// Continues from the last frame of a resumed run (poses in the tracker's own order).
    mutating func seed(_ poses: [AnimalPose], time: Double) {
        for s in 0..<min(2, poses.count) {
            let p = poses[s]
            guard p.detected, let a = BodyGeometry.anchor(p) else { continue }
            slots[s] = Slot(pose: p, anchor: a, axis: BodyGeometry.axis(p), time: time)
            if let l = BodyGeometry.length(p) { addLength(l) }
        }
    }

    /// The two animals of this frame, in a consistent order (`.missing` where not found).
    mutating func update(_ detections: [AnimalPose], time: Double) -> [AnimalPose] {
        var cands = detections.filter { $0.detected && $0.conf >= settings.lowScore && BodyGeometry.anchor($0) != nil }
        cands.sort { $0.conf > $1.conf }
        cands = Self.dedupe(cands, bodyLength: bodyLength)
        if cands.count > 8 { cands = Array(cands.prefix(8)) }
        for c in cands where c.conf >= settings.highScore {
            if let l = BodyGeometry.length(c) { addLength(l) }
        }
        let anchors = cands.map { BodyGeometry.anchor($0) ?? .zero }
        let axes = cands.map { BodyGeometry.axis($0) }
        let high = cands.indices.filter { cands[$0].conf >= settings.highScore }
        let low = cands.indices.filter { cands[$0].conf < settings.highScore }
        let L = bodyLength

        // Round 1: confident detections.
        var chosen = assign(high, cands, anchors, axes, time: time, open: [true, true], tight: false)
        // Round 2: low-score detections, only for tracked animals still unmatched and only if
        // they are not part of an animal matched in round 1.
        let open = (0..<2).map { chosen[$0] == nil && slots[$0] != nil }
        if open.contains(true) {
            let taken = chosen.compactMap { $0 }
            let free = low.filter { j in taken.allSatisfy { anchors[$0].distance(to: anchors[j]) > 0.3 * L } }
            let second = assign(free, cands, anchors, axes, time: time, open: open, tight: true)
            for s in 0..<2 where open[s] { chosen[s] = second[s] }
        }
        // Start tracking an animal that has not been seen yet.
        for s in 0..<2 where slots[s] == nil && chosen[s] == nil {
            let taken = chosen.compactMap { $0 }
            let other = slots[1 - s]?.anchor
            if let j = high.first(where: { j in
                !taken.contains(j)
                    && taken.allSatisfy { anchors[$0].distance(to: anchors[j]) > 0.5 * L }
                    && (other.map { $0.distance(to: anchors[j]) > 0.5 * L } ?? true)
            }) {
                chosen[s] = j
            }
        }

        var out = [AnimalPose.missing, AnimalPose.missing]
        for s in 0..<2 {
            guard let j = chosen[s] else { continue }
            if settings.keepLowScore || cands[j].conf >= settings.highScore { out[s] = cands[j] }
            let a = anchors[j]
            if var sl = slots[s] {
                let dt = time - sl.time
                if dt > 1e-6 && dt <= 0.4 {
                    sl.velocity = sl.velocity * 0.5 + ((a - sl.anchor) / dt) * 0.5
                    let vmax = 8 * L
                    let v = sl.velocity.length
                    if v > vmax { sl.velocity = sl.velocity * (vmax / v) }
                } else {
                    sl.velocity = .zero
                }
                sl.pose = cands[j]
                sl.anchor = a
                sl.axis = axes[j] ?? sl.axis
                sl.time = time
                slots[s] = sl
            } else {
                slots[s] = Slot(pose: cands[j], anchor: a, axis: axes[j], time: time)
            }
        }
        return out
    }

    /// Best joint choice of at most one candidate per animal (or none), by total cost.
    private func assign(_ idx: [Int], _ cands: [AnimalPose], _ anchors: [V2], _ axes: [V2?],
                        time: Double, open: [Bool], tight: Bool) -> [Int?] {
        var options: [[(Int?, Double)]] = []
        for s in 0..<2 {
            var o: [(Int?, Double)] = [(nil, 0)]
            if open[s], let sl = slots[s] {
                for j in idx {
                    guard let c = cost(sl, cands[j], anchors[j], axes[j], time: time, tight: tight) else { continue }
                    // Matching must pay for itself: far-fetched matches are worse than none.
                    let gain = 2.0 + Double(cands[j].conf)
                    if c < gain { o.append((j, c - gain)) }
                }
            }
            options.append(o)
        }
        var best = 0.0
        var choice: [Int?] = [nil, nil]
        for (a, ca) in options[0] {
            for (b, cb) in options[1] {
                if let a, let b, a == b { continue }
                if ca + cb < best {
                    best = ca + cb
                    choice = [a, b]
                }
            }
        }
        return choice
    }

    /// Matching cost of a detection for a tracked animal, in units of plausible displacement;
    /// nil when the detection is out of reach.
    private func cost(_ sl: Slot, _ p: AnimalPose, _ a: V2, _ ax: V2?, time: Double, tight: Bool) -> Double? {
        let L = bodyLength
        let dt = min(max(time - sl.time, 1e-3), 2)
        let predicted = sl.anchor + sl.velocity * min(dt, 0.3)
        let d = a.distance(to: predicted) / L
        let gate = tight ? 0.6 + 3 * dt : 1.0 + 5 * dt
        guard d <= gate else { return nil }
        let scale = 0.4 + 3 * dt
        var c = d / scale
        if dt <= 0.25, let kd = BodyGeometry.keypointDistance(p, sl.pose, shift: sl.velocity * dt) {
            c = 0.5 * c + 0.5 * (kd / L) / scale
        }
        if let t = BodyGeometry.turn(ax, sl.axis) {
            c += 1.5 * t * t * exp(-dt)
        }
        if let l = BodyGeometry.length(p) {
            c += 0.8 * max(0, abs(l / L - 1) - 0.35)
        }
        return c
    }

    /// Drops detections that repeat a higher-scoring one (`cands` sorted by score, descending).
    static func dedupe(_ cands: [AnimalPose], bodyLength L: Double) -> [AnimalPose] {
        var kept: [AnimalPose] = []
        for c in cands {
            let duplicate = kept.contains { k in
                if let kd = BodyGeometry.keypointDistance(c, k) { return kd < 0.2 * L }
                guard let a = BodyGeometry.anchor(c), let b = BodyGeometry.anchor(k) else { return false }
                return a.distance(to: b) < 0.15 * L
            }
            if !duplicate { kept.append(c) }
        }
        return kept
    }

    private mutating func addLength(_ l: Double) {
        guard l.isFinite, l > 0 else { return }
        let capacity = 301
        if lengthSamples.count < capacity {
            lengthSamples.append(l)
        } else {
            lengthSamples[lengthCursor] = l
            lengthCursor = (lengthCursor + 1) % capacity
        }
        samplesSinceEstimate += 1
        guard lengthSamples.count >= 15, samplesSinceEstimate >= 30 || lengthSamples.count < 60 else { return }
        var s = lengthSamples
        s.sort()
        bodyLength = min(max(s[s.count / 2], 0.25 * fallbackLength), 4 * fallbackLength)
        samplesSinceEstimate = 0
    }
}

// MARK: - Whole-video resolver (after inference)

enum IdentityResolver {
    struct Settings {
        /// Frame-to-frame: how much cheaper "same order" must be than "swapped" to stay in one segment.
        var continueMargin = 1.0
        /// Decisions whose cost margin is below this are flagged for review.
        var uncertainMargin = 1.5
        /// The same when the animals look alike (motion is the only cue, and one wrong decision
        /// carries over to everything after it, so more decisions are worth a look).
        var uncertainMarginMotionOnly = 2.0
        var useAppearance = true
        /// Scale the expected wandering during a gap by the animals' speed around it.
        var adaptiveMotion = true
        /// Segments shorter than this (s) are folded into the contact around them: a single
        /// "clean" frame in the middle of a contact gives confident but unreliable links.
        var minSegmentSeconds = 0.3
        /// Frames after an uncertain decision that are flagged too (seconds), so the moment the
        /// animals separate is easy to check.
        var flagAfter = 0.6
        /// Swap hints: score above which a doubtful decision is marked "likely swapped", and the
        /// (higher) score for a decision that motion alone found clear.
        var hintScore = 2.0
        var hintScoreConfident = 6.0
        /// Data pooled on each side of a decision for the hints (seconds of segments).
        var hintWindowSeconds = 30.0
        /// Let consistent weak cues join the decisions. They count only when, in this video, the
        /// decisions mostly agree with them (median swap score ≤ cueMedianScore over at least
        /// cueMinDecisions decisions); otherwise they stay hints.
        var useWeakCues = true
        var cueMedianScore = -1.0
        var cueMinDecisions = 10
    }

    /// Re-decides the A / B order of a two-animal track over the whole video. Earlier results and
    /// user locks stored in the flags are respected.
    static func resolve(_ track: PoseTrack, settings: Settings = Settings()) -> PoseTrack {
        guard track.animalCount == 2, track.count > 0 else { return track }
        let (raw, locks) = unswapped(track)
        return run(raw, locks: locks, frozen: held(track), previous: track.flags, settings: settings)
    }

    /// Held orders relative to the online tracker (-1 = not held).
    static func held(_ track: PoseTrack) -> [Int8] {
        (0..<track.count).map { i in
            track.flag(i, IdentityFlag.held) ? (track.flag(i, IdentityFlag.swapped) ? 1 : 0) : -1
        }
    }

    /// "Swap A / B from here": reverses the order of the segment at frame `index` (the next
    /// segment if `index` lies in a contact), confirms the segment before it as shown, locks both
    /// and re-solves the rest of the video, which follows along. nil if there is nothing to swap.
    static func correct(_ track: PoseTrack, at index: Int, settings: Settings = Settings()) -> PoseTrack? {
        guard track.animalCount == 2, index >= 0, index < track.count else { return nil }
        let (raw, locks) = unswapped(track)
        var obs = observe(raw)
        let L = BodyGeometry.typicalLength(raw) ?? fallbackLength(raw)
        let seg = segment(&obs, t: raw.time, L: L, settings: settings)
        guard !seg.segments.isEmpty else { return nil }
        var k = seg.segOf[index]
        if k < 0 {
            k = seg.segments.firstIndex { $0.start > index } ?? (seg.segments.count - 1)
        }
        // Current order of a segment as shown to the user.
        func shown(_ k: Int) -> Int {
            let sg = seg.segments[k]
            return (sg.start...sg.end).contains { seg.segOf[$0] == k && track.flag($0, IdentityFlag.swapped) } ? 1 : 0
        }
        var newLocks = locks
        // "Swap from here": the segment before stays as shown (confirmed), so the change starts
        // at the contact right before this point. Without this the solver could satisfy the
        // correction by renaming everything before it, or by reversing an earlier decision the
        // user has already checked. Later segments are re-solved and follow along.
        if k > 0 {
            let prev = seg.segments[k - 1]
            if !(prev.start...prev.end).contains(where: { locks[$0] >= 0 }) {
                let o = Int8(shown(k - 1))
                for i in prev.start...prev.end where seg.segOf[i] == k - 1 { newLocks[i] = o }
            }
        }
        let range = seg.segments[k].start...seg.segments[k].end
        let flipped = Int8(1 - shown(k))
        for i in range { newLocks[i] = flipped }
        // Everything earlier stays exactly as shown, including its review marks, so a correction
        // never undoes what the user has already checked; later segments are released to follow.
        var frozen = [Int8](repeating: -1, count: track.count)
        for j in 0..<k {
            let o = Int8(shown(j))
            for i in seg.segments[j].start...seg.segments[j].end where seg.segOf[i] == j { frozen[i] = o }
        }
        return run(raw, locks: newLocks, frozen: frozen, previous: track.flags, settings: settings)
    }

    // MARK: Swap A / B over a time range

    /// Identity segments of a two-animal track as frame ranges: stretches in which the order is unambiguous;
    /// contacts, merges and gaps lie between them. They depend only on the detections, not on the A / B order shown,
    /// so a review can compute them once and snap a chosen time range to them (`snappedSegments`).
    static func segmentRanges(_ track: PoseTrack, settings: Settings = Settings()) -> [ClosedRange<Int>] {
        guard track.animalCount == 2, track.count > 0 else { return [] }
        let (raw, _) = unswapped(track)
        var obs = observe(raw)
        let L = BodyGeometry.typicalLength(raw) ?? fallbackLength(raw)
        return segment(&obs, t: raw.time, L: L, settings: settings).segments.map { $0.start...$0.end }
    }

    /// Segments (indices into `segments`) that a chosen range `from`…`to` (frame indices, either order) covers,
    /// widened to the contacts around it: from the segment containing `from` (or the first one after it) to the
    /// segment containing `to` (or the last one before it). nil when the range lies inside one contact.
    static func snappedSegments(_ segments: [ClosedRange<Int>], from: Int, to: Int) -> ClosedRange<Int>? {
        let a = min(from, to), b = max(from, to)
        guard let first = segments.firstIndex(where: { $0.upperBound >= a }),
              let last = segments.lastIndex(where: { $0.lowerBound <= b }), first <= last else { return nil }
        return first...last
    }

    /// "Swap A / B in a time range": every segment the range `from`…`to` covers (widened to the contacts around
    /// it, `snappedSegments`) is reversed and locked. Everything outside — order, locks and review marks — stays
    /// exactly as shown and is held, so later solves keep it. At each end the one switch is placed inside the
    /// contact there, where it costs least (as for any decision). Review marks in the swapped part are cleared:
    /// the user has checked it. nil if there is nothing to swap.
    static func correct(_ track: PoseTrack, from: Int, to: Int, settings: Settings = Settings()) -> PoseTrack? {
        guard track.animalCount == 2, track.count > 0 else { return nil }
        let n = track.count
        let a = max(0, min(from, to)), b = min(n - 1, max(from, to))
        guard a <= b else { return nil }
        let (raw, locks) = unswapped(track)
        var obs = observe(raw)
        let L = BodyGeometry.typicalLength(raw) ?? fallbackLength(raw)
        let seg = segment(&obs, t: raw.time, L: L, settings: settings)
        let K = seg.segments.count
        guard let covered = snappedSegments(seg.segments.map { $0.start...$0.end }, from: a, to: b) else { return nil }
        // Current order of a segment as shown to the user.
        func shown(_ k: Int) -> Int {
            let sg = seg.segments[k]
            return (sg.start...sg.end).contains { seg.segOf[$0] == k && track.flag($0, IdentityFlag.swapped) } ? 1 : 0
        }
        var newLocks = locks
        var frozen = [Int8](repeating: -1, count: n)
        for k in 0..<K {
            let sg = seg.segments[k]
            if covered.contains(k) {
                let flipped = Int8(1 - shown(k))
                for i in sg.start...sg.end { newLocks[i] = flipped }
            } else {
                let o = Int8(shown(k))
                for i in sg.start...sg.end where seg.segOf[i] == k { frozen[i] = o }
            }
        }
        var out = run(raw, locks: newLocks, frozen: frozen, previous: track.flags, settings: settings)
        // The part that may change: from the frame after the segment before the range to the frame before the
        // segment after it (the two contacts at its ends included). Outside it the stored frames are kept bit for bit.
        let lo = covered.lowerBound > 0 ? seg.segments[covered.lowerBound - 1].end + 1 : 0
        let hi = covered.upperBound + 1 < K ? seg.segments[covered.upperBound + 1].start - 1 : n - 1
        for i in 0..<n {
            if i < lo || i > hi {
                if out.flag(i, IdentityFlag.swapped) != track.flag(i, IdentityFlag.swapped) { out.swapAnimals(at: i) }
                out.flags[i] = (i < track.flags.count ? track.flags[i] : 0) | IdentityFlag.held
            } else {
                out.flags[i] &= ~IdentityFlag.marks
            }
        }
        out.identity?.uncertainEvents = countBouts(out.flags, IdentityFlag.uncertain)
        out.identity?.suspectEvents = countBouts(out.flags, IdentityFlag.suspect)
        return out
    }

    /// First and last frame whose A / B order differs between two versions of the same track (nil: none), e.g. to
    /// tell the user which part a range swap changed.
    static func changedOrder(_ before: PoseTrack, _ after: PoseTrack) -> ClosedRange<Int>? {
        let n = min(before.count, after.count)
        guard let first = (0..<n).first(where: { before.flag($0, IdentityFlag.swapped) != after.flag($0, IdentityFlag.swapped) }),
              let last = (0..<n).last(where: { before.flag($0, IdentityFlag.swapped) != after.flag($0, IdentityFlag.swapped) })
        else { return nil }
        return first...last
    }

    /// Number of separate stretches with `bit` set.
    static func countBouts(_ flags: [UInt8], _ bit: UInt8) -> Int {
        var count = 0
        var previous = false
        for f in flags {
            let on = f & bit != 0
            if on && !previous { count += 1 }
            previous = on
        }
        return count
    }

    // MARK: Steps

    struct SlotObs {
        var valid = false
        var anchor = V2.zero
        var axis: V2?
        var length: Double = .nan
    }

    struct Observations {
        var slot: [[SlotObs]]
        /// One detection standing for both animals (computed, not from the online tracker).
        var merged: [Bool]
    }

    struct Segment {
        var start: Int
        var end: Int
    }

    struct Segmentation {
        var segOf: [Int]
        var segments: [Segment]
    }

    /// Track with the stored A / B swaps undone (= online tracker order) and the user locks
    /// (-1 = none, 0 / 1 = required order relative to that).
    static func unswapped(_ track: PoseTrack) -> (PoseTrack, [Int8]) {
        var raw = track
        var locks = [Int8](repeating: -1, count: track.count)
        if raw.flags.count != raw.count { raw.flags = [UInt8](repeating: 0, count: raw.count) }
        for i in 0..<raw.count {
            let f = raw.flags[i]
            let swapped = f & IdentityFlag.swapped != 0
            if swapped { raw.swapAnimals(at: i) }
            if f & IdentityFlag.locked != 0 { locks[i] = swapped ? 1 : 0 }
            raw.flags[i] = 0
        }
        return (raw, locks)
    }

    static func fallbackLength(_ track: PoseTrack) -> Double {
        max(0.06 * (track.frameWidth * track.frameWidth + track.frameHeight * track.frameHeight).squareRoot(), 8)
    }

    static func observe(_ track: PoseTrack) -> Observations {
        let n = track.count
        var slot = [[SlotObs]](repeating: [SlotObs](repeating: SlotObs(), count: n), count: 2)
        for s in 0..<2 {
            for i in 0..<n where track.conf(i, s) > 0 {
                let p = track.pose(i, s)
                guard let a = BodyGeometry.anchor(p) else { continue }
                slot[s][i] = SlotObs(valid: true, anchor: a, axis: BodyGeometry.axis(p), length: BodyGeometry.length(p) ?? .nan)
            }
        }
        return Observations(slot: slot, merged: [Bool](repeating: false, count: n))
    }

    private struct State {
        var anchor: V2
        var axis: V2?
        var velocity = V2.zero
        var time: Double
    }

    /// Cost of observation `o` at time `t` for an animal last in `st`, in units of plausible
    /// displacement (nil = out of reach).
    private static func cost(_ o: SlotObs, _ t: Double, _ st: State, L: Double) -> Double? {
        let dt = min(max(t - st.time, 1e-3), 3)
        let predicted = st.anchor + st.velocity * min(dt, 0.3)
        let d = o.anchor.distance(to: predicted) / L
        guard d <= 1.0 + 5 * dt else { return nil }
        var c = d / (0.4 + 3 * dt)
        if let turn = BodyGeometry.turn(o.axis, st.axis) { c += 1.5 * turn * turn * exp(-dt) }
        return c
    }

    /// Longest stretch (s) over which one detection is taken to hold both animals.
    static let maxMerge = 6.0

    /// Splits the video into segments in which the A / B order is unambiguous. Also fills
    /// `obs.merged`.
    static func segment(_ obs: inout Observations, t: [Double], L: Double, settings: Settings) -> Segmentation {
        let n = t.count
        var segOf = [Int](repeating: -1, count: n)
        var segments: [Segment] = []
        var open = false
        var st: [State?] = [nil, nil]
        var lastSeen: [State?] = [nil, nil]
        /// Where a hidden animal is taken to be while it is inside a merged detection.
        var mergedAt: [V2?] = [nil, nil]
        let newcomer = 3.0
        let big = 50.0

        func state(_ s: Int, _ i: Int, previous: State?) -> State {
            let o = obs.slot[s][i]
            var v = V2.zero
            if let p = previous {
                let dt = t[i] - p.time
                if dt > 1e-6 && dt <= 0.4 {
                    v = p.velocity * 0.5 + ((o.anchor - p.anchor) / dt) * 0.5
                    let vmax = 8 * L
                    if v.length > vmax { v = v * (vmax / v.length) }
                }
            }
            return State(anchor: o.anchor, axis: o.axis ?? previous?.axis, velocity: v, time: t[i])
        }

        for i in 0..<n {
            let valid = [obs.slot[0][i].valid, obs.slot[1][i].valid]
            if !valid[0] && !valid[1] { continue }

            // One detection right where the other animal was a moment ago: both are in it. The
            // hidden animal moves with the merged detection until it is seen again.
            for s in 0..<2 where valid[s] { mergedAt[s] = nil }
            if valid[0] != valid[1] {
                let s = valid[0] ? 0 : 1
                let a = obs.slot[s][i].anchor
                if let other = lastSeen[1 - s], t[i] - other.time <= maxMerge,
                   (mergedAt[1 - s] ?? other.anchor).distance(to: a) < 0.9 * L {
                    obs.merged[i] = true
                    mergedAt[1 - s] = a
                } else {
                    mergedAt[1 - s] = nil
                }
            }

            var continues = false
            if open && !obs.merged[i] {
                // Cost of each hypothesis: keep (slot s is animal s) or swap.
                func hypothesis(_ swap: Bool) -> Double {
                    var total = 0.0
                    for s in 0..<2 where valid[s] {
                        let u = swap ? 1 - s : s
                        if let state = st[u] {
                            total += cost(obs.slot[s][i], t[i], state, L: L) ?? big
                        } else {
                            total += newcomer
                        }
                    }
                    return total
                }
                let keep = hypothesis(false), swap = hypothesis(true)
                continues = keep < big && swap - keep >= settings.continueMargin
            }

            if continues {
                segOf[i] = segments.count - 1
                segments[segments.count - 1].end = i
                for s in 0..<2 where valid[s] { st[s] = state(s, i, previous: st[s]) }
            } else {
                open = false
                var clean = false
                if !obs.merged[i] {
                    if valid[0] && valid[1] {
                        clean = obs.slot[0][i].anchor.distance(to: obs.slot[1][i].anchor) >= 0.6 * L
                    } else {
                        let s = valid[0] ? 0 : 1
                        if let other = lastSeen[1 - s] {
                            clean = other.anchor.distance(to: obs.slot[s][i].anchor) >= 1.2 * L || t[i] - other.time > 2
                        } else {
                            clean = true
                        }
                    }
                }
                if clean {
                    segments.append(Segment(start: i, end: i))
                    segOf[i] = segments.count - 1
                    open = true
                    st = [nil, nil]
                    for s in 0..<2 where valid[s] { st[s] = state(s, i, previous: nil) }
                }
            }
            for s in 0..<2 where valid[s] { lastSeen[s] = state(s, i, previous: lastSeen[s]) }
        }

        // Fold short segments into the surrounding contact.
        var dts: [Double] = []
        for i in stride(from: 1, to: n, by: max(1, n / 2000)) where t[i] > t[i - 1] { dts.append(t[i] - t[i - 1]) }
        let dt = dts.isEmpty ? 1.0 / 30 : median(&dts)
        let minFrames = max(3, Int((settings.minSegmentSeconds / max(dt, 1e-3)).rounded()))
        var kept: [Segment] = []
        var remap = [Int](repeating: -1, count: segments.count)
        for (k, sg) in segments.enumerated() {
            let frames = (sg.start...sg.end).filter { segOf[$0] == k }.count
            if frames >= minFrames {
                remap[k] = kept.count
                kept.append(sg)
            }
        }
        for i in 0..<n where segOf[i] >= 0 { segOf[i] = remap[segOf[i]] }
        return Segmentation(segOf: segOf, segments: kept)
    }

    /// Start / end of one animal's track within a segment, plus its look.
    struct SegmentSlot {
        var count = 0
        var firstTime = 0.0, lastTime = 0.0
        var firstAnchor = V2.zero, lastAnchor = V2.zero
        var firstVelocity = V2.zero, lastVelocity = V2.zero
        var firstAxis: V2?, lastAxis: V2?
        /// Standardized appearance / size features (nil entries = not measured).
        var features: [Double?] = []
        var featureCount = 0
        /// Median nose → tail-base length while walking (body lengths), the size cue least
        /// affected by posture (grooming and rearing shorten the body).
        var lengthWalking: Double?
        /// Median speed (body lengths / s), a behavioural cue (hints only).
        var activity: Double?
        /// Median fur colour [Y, R − Y, B − Y] (empty if not recorded).
        var colour: [Double] = []
    }

    /// Scales that standardize the features: relative body length, then luminance and two
    /// chroma channels (roughly their frame-to-frame measurement noise).
    static let featureScales: [Double] = [0.06, 0.03, 0.015, 0.015]

    static func summarize(_ track: PoseTrack, _ obs: Observations, _ seg: Segmentation, L: Double) -> [[SegmentSlot]] {
        let t = track.time
        let dims = track.appearanceDims
        let nFeatures = 1 + min(dims, 3)
        var out: [[SegmentSlot]] = []
        for sg in seg.segments {
            var pair: [SegmentSlot] = []
            for s in 0..<2 {
                var ss = SegmentSlot()
                var idx: [Int] = []
                for i in sg.start...sg.end where seg.segOf[i] >= 0 && obs.slot[s][i].valid { idx.append(i) }
                ss.count = idx.count
                ss.features = [Double?](repeating: nil, count: nFeatures)
                if let f = idx.first, let l = idx.last {
                    ss.firstTime = t[f]; ss.lastTime = t[l]
                    ss.firstAnchor = obs.slot[s][f].anchor; ss.lastAnchor = obs.slot[s][l].anchor
                    ss.firstAxis = idx.prefix(5).lazy.compactMap { obs.slot[s][$0].axis }.first
                    ss.lastAxis = idx.suffix(5).reversed().lazy.compactMap { obs.slot[s][$0].axis }.first
                    // Velocity over the first / last ~0.25 s.
                    if let j = idx.last(where: { t[$0] <= t[f] + 0.25 }), j != f, t[j] > t[f] {
                        ss.firstVelocity = (obs.slot[s][j].anchor - ss.firstAnchor) / (t[j] - t[f])
                    }
                    if let j = idx.first(where: { t[$0] >= t[l] - 0.25 }), j != l, t[l] > t[j] {
                        ss.lastVelocity = (ss.lastAnchor - obs.slot[s][j].anchor) / (t[l] - t[j])
                    }
                    let vmax = 8 * L
                    if ss.firstVelocity.length > vmax { ss.firstVelocity = ss.firstVelocity * (vmax / ss.firstVelocity.length) }
                    if ss.lastVelocity.length > vmax { ss.lastVelocity = ss.lastVelocity * (vmax / ss.lastVelocity.length) }
                }
                // Look, size and activity: only frames where the other animal is well away (no
                // mixing). Speed over ~0.2 s, so keypoint jitter does not count as movement.
                var lengths: [Double] = []
                var speeds: [Double] = []
                var app = [[Double]](repeating: [], count: min(dims, 3))
                var back = 0
                for (j, i) in idx.enumerated() {
                    while back < j && t[i] - t[idx[back]] > 0.2 { back += 1 }
                    var speed: Double?
                    if back < j, t[i] - t[idx[back]] >= 0.08 {
                        speed = obs.slot[s][i].anchor.distance(to: obs.slot[s][idx[back]].anchor) / L / (t[i] - t[idx[back]])
                    }
                    let o = obs.slot[s][i]
                    let other = obs.slot[1 - s][i]
                    if other.valid && other.anchor.distance(to: o.anchor) < 1.2 * L { continue }
                    if obs.merged[i] { continue }
                    if let speed {
                        speeds.append(speed)
                        // Walking: the body is stretched, so length reflects size, not posture.
                        if speed >= 0.6 && o.length.isFinite { lengths.append(o.length / L) }
                    }
                    if dims > 0 {
                        let base = (i * 2 + s) * dims
                        for d in 0..<min(dims, 3) {
                            let v = track.appearance[base + d]
                            if v.isFinite { app[d].append(Double(v)) }
                        }
                    }
                }
                let minSamples = 8
                if lengths.count >= minSamples {
                    let m = median(&lengths)
                    ss.lengthWalking = m
                    ss.features[0] = m / featureScales[0]
                }
                if speeds.count >= 15 { ss.activity = median(&speeds) }
                for d in 0..<app.count where app[d].count >= minSamples {
                    let m = median(&app[d])
                    ss.colour.append(m)
                    ss.features[1 + d] = m / featureScales[1 + d]
                }
                if ss.colour.count != app.count { ss.colour = [] }
                ss.featureCount = max(lengths.count, app.first?.count ?? 0)
                pair.append(ss)
            }
            out.append(pair)
        }
        return out
    }

    /// Cost of joining the end of one animal's track to the start of another (0 when either is
    /// missing, so it does not influence the decision).
    private static func joinCost(_ a: SegmentSlot, _ b: SegmentSlot, L: Double, settings: Settings) -> Double {
        guard a.count > 0, b.count > 0 else { return 0 }
        let gap = max(b.firstTime - a.lastTime, 1e-3)
        let h = min(gap / 2, 0.4)
        let pa = a.lastAnchor + a.lastVelocity * h
        let pb = b.firstAnchor - b.firstVelocity * h
        // How far an animal may have wandered during the gap grows with the gap and with how fast
        // the animals were moving around it (animals in contact move slowly).
        let rate: Double
        if settings.adaptiveMotion {
            let speed = (a.lastVelocity.length + b.firstVelocity.length) / 2 / L
            rate = min(max(0.25 + 0.6 * speed, 0.25), 2.0)
        } else {
            rate = 1.0
        }
        let sigma = L * (0.2 + rate * gap)
        let d = pa.distance(to: pb) / sigma
        var c = min(d * d, 9) / 2
        if let turn = BodyGeometry.turn(a.lastAxis, b.firstAxis) {
            c += 2 * turn * turn * exp(-gap / 1.5)
        }
        return c
    }

    struct Link {
        var same: Double
        var cross: Double
    }

    static func links(_ slots: [[SegmentSlot]], L: Double, settings: Settings) -> [Link] {
        guard slots.count > 1 else { return [] }
        return (0..<(slots.count - 1)).map { k in
            let a = slots[k], b = slots[k + 1]
            return Link(same: joinCost(a[0], b[0], L: L, settings: settings) + joinCost(a[1], b[1], L: L, settings: settings),
                        cross: joinCost(a[0], b[1], L: L, settings: settings) + joinCost(a[1], b[0], L: L, settings: settings))
        }
    }

    struct AppearanceModel {
        var axis: [Double]
        var high: Double
        var low: Double
        var sigma: Double
        var separation: Double
        var active: [Int]
    }

    /// Learns which look / size tells the two animals apart, from segments in which both are
    /// visible: there the two tracks are different animals, so their feature difference points
    /// along the axis that separates them (up to sign). nil when nothing separates them reliably.
    static func appearanceModel(_ slots: [[SegmentSlot]]) -> AppearanceModel? {
        guard let nFeatures = slots.first?.first?.features.count, nFeatures > 0 else { return nil }
        // Features measured in most usable tracks.
        let usable = slots.flatMap { $0 }.filter { $0.featureCount >= 8 }
        guard usable.count >= 6 else { return nil }
        let active = (0..<nFeatures).filter { f in
            Double(usable.filter { $0.features[f] != nil }.count) >= 0.6 * Double(usable.count)
        }
        guard !active.isEmpty else { return nil }
        func vector(_ s: SegmentSlot) -> [Double]? {
            guard s.featureCount >= 8 else { return nil }
            var v: [Double] = []
            for f in active {
                guard let x = s.features[f] else { return nil }
                v.append(x)
            }
            return v
        }
        var diffs: [([Double], Double)] = []
        for pair in slots {
            guard let a = vector(pair[0]), let b = vector(pair[1]) else { continue }
            let w = Double(min(pair[0].featureCount, pair[1].featureCount)).squareRoot()
            diffs.append((zip(a, b).map { $0 - $1 }, w))
        }
        guard diffs.count >= 3 else { return nil }
        let D = active.count
        // Principal direction of the (sign-free) differences: power iteration on Σ w d dᵀ.
        var m = [Double](repeating: 0, count: D * D)
        for (d, w) in diffs {
            for r in 0..<D { for c in 0..<D { m[r * D + c] += w * d[r] * d[c] } }
        }
        var u = diffs.max { $0.1 < $1.1 }!.0
        if u.allSatisfy({ abs($0) < 1e-12 }) { u = [Double](repeating: 1, count: D) }
        for _ in 0..<60 {
            var nu = [Double](repeating: 0, count: D)
            for r in 0..<D { for c in 0..<D { nu[r] += m[r * D + c] * u[c] } }
            let norm = nu.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12 else { return nil }
            u = nu.map { $0 / norm }
        }
        // The projected differences must cluster away from zero (a real, consistent difference);
        // for identical animals they scatter around zero.
        var proj = diffs.map { (abs(zip($0.0, u).reduce(0) { $0 + $1.0 * $1.1 }), $0.1) }
        let center = weightedMedian(&proj)
        var dev = proj.map { (abs($0.0 - center), $0.1) }
        let spread = max(1.4826 * weightedMedian(&dev), 0.5)
        let separation = center / spread
        guard center >= 2.0, separation >= 2.5 else { return nil }

        // Class centers along the axis, from the two-animal segments.
        var highs: [(Double, Double)] = [], lows: [(Double, Double)] = []
        for pair in slots {
            guard let a = vector(pair[0]), let b = vector(pair[1]) else { continue }
            let qa = zip(a, u).reduce(0) { $0 + $1.0 * $1.1 }
            let qb = zip(b, u).reduce(0) { $0 + $1.0 * $1.1 }
            let w = Double(min(pair[0].featureCount, pair[1].featureCount)).squareRoot()
            highs.append((max(qa, qb), w))
            lows.append((min(qa, qb), w))
        }
        let hi = weightedMedian(&highs), lo = weightedMedian(&lows)
        var resid = highs.map { (abs($0.0 - hi), $0.1) } + lows.map { (abs($0.0 - lo), $0.1) }
        let sigma = max(1.4826 * weightedMedian(&resid), 0.5)
        return AppearanceModel(axis: u, high: hi, low: lo, sigma: sigma, separation: separation, active: active)
    }

    /// Cost of each order of a segment under the appearance model ([straight, swapped];
    /// straight = slot 0 is the "high" animal, which is called A).
    static func unary(_ pair: [SegmentSlot], _ model: AppearanceModel) -> [Double] {
        func cost(_ s: SegmentSlot, high: Bool) -> Double {
            guard s.featureCount >= 8 else { return 0 }
            var q = 0.0
            for (j, f) in model.active.enumerated() {
                guard let x = s.features[f] else { return 0 }
                q += x * model.axis[j]
            }
            let z = (q - (high ? model.high : model.low)) / model.sigma
            let r = min(1, Double(s.featureCount) / 15)
            return r * min(z * z / 2, 12)
        }
        return [cost(pair[0], high: true) + cost(pair[1], high: false),
                cost(pair[0], high: false) + cost(pair[1], high: true)]
    }

    // MARK: Swap hints

    /// Weak cues per animal and segment: length while walking (body lengths) and activity (body
    /// lengths / s). Fur colour is left to the appearance model, which rejects differences that
    /// come from uneven lighting; read as a weak cue it would mistake light for identity.
    static func cues(_ s: SegmentSlot) -> [Double?] {
        [s.lengthWalking, s.activity]
    }

    /// Smallest plausible segment-to-segment variation of each cue (one animal), and the weight
    /// of the cue (activity is behaviour, so it counts half).
    static let cueFloors: [Double] = [0.03, 0.15]
    static let cueWeights: [Double] = [1, 0.5]

    /// Swap score of each decision (between segment k and k + 1) under the current labels.
    /// On each side the cues are pooled over the segments reachable without crossing another
    /// doubtful decision. With A − B differences d_L before and d_R after, a cue scores
    /// −d_L · d_R / σ² (the log-likelihood ratio of "swapped here" for two Gaussian animals):
    /// positive when the difference flips sign, i.e. when the labels look swapped. σ is the
    /// same animal's variation between segments, measured across clear decisions.
    static func swapScores(_ slots: [[SegmentSlot]], orient: [Int], margin: [Double], doubtful: Double, window: Double) -> [Double] {
        let K = slots.count
        guard K > 1 else { return [] }
        let F = cueWeights.count
        var A = [[Double?]](), B = [[Double?]](), w = [Double](), span = [Double]()
        for k in 0..<K {
            let a = slots[k][orient[k]], b = slots[k][1 - orient[k]]
            A.append(cues(a))
            B.append(cues(b))
            w.append(Double(min(a.count, b.count)).squareRoot())
            span.append(max(a.lastTime, b.lastTime) - min(a.count > 0 ? a.firstTime : .infinity, b.count > 0 ? b.firstTime : .infinity))
        }
        // Same-animal variation between neighbouring segments joined by a clear decision.
        var sigma = [Double](repeating: 0, count: F)
        for f in 0..<F {
            var diffs: [Double] = []
            for k in 0..<(K - 1) where margin[k] >= doubtful {
                if let x = A[k][f], let y = A[k + 1][f] { diffs.append(x - y) }
                if let x = B[k][f], let y = B[k + 1][f] { diffs.append(x - y) }
            }
            if diffs.count >= 4 {
                let m = median(&diffs)
                var dev = diffs.map { abs($0 - m) }
                sigma[f] = max(1.4826 * median(&dev) / 2.0.squareRoot(), cueFloors[f])
            } else {
                sigma[f] = 2 * cueFloors[f]
            }
        }
        // A − B difference of each cue pooled over a run of segments (weighted median).
        func pooled(_ ks: [Int], _ f: Int) -> Double? {
            var v: [(Double, Double)] = []
            for k in ks { if let a = A[k][f], let b = B[k][f] { v.append((a - b, w[k])) } }
            return v.isEmpty ? nil : weightedMedian(&v)
        }
        var scores: [Double] = []
        for k in 0..<(K - 1) {
            var left = [k], right = [k + 1]
            var tl = span[k], tr = span[k + 1]
            var j = k
            while j > 0 && margin[j - 1] >= doubtful && tl < window { j -= 1; left.append(j); tl += span[j] }
            j = k + 1
            while j < K - 1 && margin[j] >= doubtful && tr < window { j += 1; right.append(j); tr += span[j] }
            var score = 0.0
            for f in 0..<F {
                guard let dl = pooled(left, f), let dr = pooled(right, f) else { continue }
                let llr = -dl * dr / (sigma[f] * sigma[f])
                score += cueWeights[f] * min(max(llr, -4), 4)
            }
            scores.append(score)
        }
        return scores
    }

    /// Weak cues of one animal in one segment, standardized (length while walking, activity
    /// at reduced weight); nil unless both are measured.
    static func cueVector(_ s: SegmentSlot) -> [Double]? {
        guard let l = s.lengthWalking, let a = s.activity else { return nil }
        return [l / cueFloors[0], a / cueFloors[1] * cueWeights[1]]
    }

    /// Label-free model of the weak cues, as for fur colour: in every segment the two tracks are
    /// different animals, so their cue difference points along the axis that separates them (up
    /// to sign). The two animals' typical positions on that axis and the spread around them.
    /// nil when the cues do not separate the animals (validated separately against motion).
    static func weakCueModel(_ slots: [[SegmentSlot]]) -> AppearanceModel? {
        var pairs: [([Double], [Double], Double)] = []
        for pair in slots {
            guard let a = cueVector(pair[0]), let b = cueVector(pair[1]) else { continue }
            pairs.append((a, b, Double(min(pair[0].count, pair[1].count)).squareRoot()))
        }
        guard pairs.count >= 5 else { return nil }
        let D = 2
        var m = [Double](repeating: 0, count: D * D)
        for (a, b, w) in pairs {
            let d = zip(a, b).map { $0 - $1 }
            for r in 0..<D { for c in 0..<D { m[r * D + c] += w * d[r] * d[c] } }
        }
        var u = [1.0, -1.0]
        for _ in 0..<60 {
            var nu = [Double](repeating: 0, count: D)
            for r in 0..<D { for c in 0..<D { nu[r] += m[r * D + c] * u[c] } }
            let norm = nu.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 1e-12 else { return nil }
            u = nu.map { $0 / norm }
        }
        func q(_ v: [Double]) -> Double { zip(v, u).reduce(0) { $0 + $1.0 * $1.1 } }
        var highs: [(Double, Double)] = [], lows: [(Double, Double)] = []
        for (a, b, w) in pairs {
            highs.append((max(q(a), q(b)), w))
            lows.append((min(q(a), q(b)), w))
        }
        let hi = weightedMedian(&highs), lo = weightedMedian(&lows)
        var resid = highs.map { (abs($0.0 - hi), $0.1) } + lows.map { (abs($0.0 - lo), $0.1) }
        let sigma = max(1.4826 * weightedMedian(&resid), 0.5)
        let separation = (hi - lo) / sigma
        guard hi - lo >= 0.75, separation >= 1.0 else { return nil }
        return AppearanceModel(axis: u, high: hi, low: lo, sigma: sigma, separation: separation, active: [0, 1])
    }

    /// Cost of each order of a segment under the weak cue model ([slot 0 = high, slot 0 = low]);
    /// capped low, so weak cues settle doubtful decisions but never outweigh clear motion.
    static func weakUnary(_ pair: [SegmentSlot], _ model: AppearanceModel, cap: Double = 3) -> [Double] {
        func cost(_ s: SegmentSlot, high: Bool) -> Double {
            guard let v = cueVector(s) else { return 0 }
            let q = zip(v, model.axis).reduce(0) { $0 + $1.0 * $1.1 }
            let z = (q - (high ? model.high : model.low)) / model.sigma
            return min(z * z / 2, cap)
        }
        return [cost(pair[0], high: true) + cost(pair[1], high: false),
                cost(pair[0], high: false) + cost(pair[1], high: true)]
    }

    /// Typical weak cues of animal A and B as currently labelled (nil = cue does not tell them
    /// apart) and the same animal's spread between segments. Used to sharpen a solution that
    /// the label-free model has already put right: segments still labelled wrongly sit at the
    /// other animal's values, which widens the spread and weakens the model (never sharpens it).
    struct CueModel {
        var a: [Double?]
        var b: [Double?]
        var sigma: [Double]
    }

    static func fitCueModel(_ slots: [[SegmentSlot]], orient: [Int]) -> CueModel? {
        let F = cueWeights.count
        var model = CueModel(a: [Double?](repeating: nil, count: F), b: [Double?](repeating: nil, count: F),
                             sigma: [Double](repeating: 1, count: F))
        var any = false
        for f in 0..<F {
            var xa: [(Double, Double)] = [], xb: [(Double, Double)] = []
            for (k, pair) in slots.enumerated() {
                let a = pair[orient[k]], b = pair[1 - orient[k]]
                if let v = cues(a)[f] { xa.append((v, Double(a.count).squareRoot())) }
                if let v = cues(b)[f] { xb.append((v, Double(b.count).squareRoot())) }
            }
            guard xa.count >= 5, xb.count >= 5 else { continue }
            var ta = xa, tb = xb
            let ma = weightedMedian(&ta), mb = weightedMedian(&tb)
            var resid = xa.map { (abs($0.0 - ma), $0.1) } + xb.map { (abs($0.0 - mb), $0.1) }
            let sigma = max(1.4826 * weightedMedian(&resid), cueFloors[f])
            guard abs(ma - mb) >= 0.5 * sigma else { continue }
            model.a[f] = ma
            model.b[f] = mb
            model.sigma[f] = sigma
            any = true
        }
        return any ? model : nil
    }

    /// Cost of each order of a segment under the fitted cue model ([slot 0 = A, slot 0 = B]).
    static func cueUnary(_ pair: [SegmentSlot], _ model: CueModel) -> [Double] {
        var cost = [0.0, 0.0]
        let c0 = cues(pair[0]), c1 = cues(pair[1])
        for f in 0..<cueWeights.count {
            guard let ma = model.a[f], let mb = model.b[f] else { continue }
            let s2 = 2 * model.sigma[f] * model.sigma[f]
            for o in 0..<2 {
                let xa = o == 0 ? c0[f] : c1[f], xb = o == 0 ? c1[f] : c0[f]
                var e = 0.0
                if let xa { e += (xa - ma) * (xa - ma) / s2 }
                if let xb { e += (xb - mb) * (xb - mb) / s2 }
                cost[o] += cueWeights[f] * min(e, 6)
            }
        }
        return cost
    }

    struct Solution {
        var orient: [Int]
        /// Extra cost of reversing each decision between segment k and k + 1.
        var margin: [Double]
    }

    /// Exact minimum over all orders of the segment chain (min-sum dynamic programming), with
    /// min-marginals for the decision margins.
    static func solve(links: [Link], unary: [[Double]], locks: [Int?]) -> Solution {
        let K = unary.count
        guard K > 0 else { return Solution(orient: [], margin: []) }
        let inf = 1e12
        func node(_ k: Int, _ o: Int) -> Double {
            if let l = locks[k], l != o { return inf }
            return unary[k][o]
        }
        func link(_ k: Int, _ a: Int, _ b: Int) -> Double { a == b ? links[k].same : links[k].cross }
        var F = [[Double]](repeating: [0, 0], count: K)
        var back = [[Int]](repeating: [0, 0], count: K)
        F[0] = [node(0, 0), node(0, 1)]
        for k in stride(from: 1, to: K, by: 1) {
            for b in 0..<2 {
                let c0 = F[k - 1][0] + link(k - 1, 0, b)
                let c1 = F[k - 1][1] + link(k - 1, 1, b)
                back[k][b] = c0 <= c1 ? 0 : 1
                F[k][b] = min(c0, c1) + node(k, b)
            }
        }
        var B = [[Double]](repeating: [0, 0], count: K)
        B[K - 1] = [node(K - 1, 0), node(K - 1, 1)]
        if K >= 2 {
            for k in stride(from: K - 2, through: 0, by: -1) {
                for a in 0..<2 {
                    B[k][a] = node(k, a) + min(link(k, a, 0) + B[k + 1][0], link(k, a, 1) + B[k + 1][1])
                }
            }
        }
        var orient = [Int](repeating: 0, count: K)
        // Ties: keep the online tracker's order.
        orient[K - 1] = F[K - 1][0] <= F[K - 1][1] ? 0 : 1
        if K >= 2 {
            for k in stride(from: K - 1, through: 1, by: -1) { orient[k - 1] = back[k][orient[k]] }
        }
        let best = min(F[K - 1][0], F[K - 1][1])
        var margin: [Double] = []
        if K >= 2 {
            for k in 0..<(K - 1) {
                let switched = orient[k] != orient[k + 1]
                var alt = inf
                for a in 0..<2 {
                    for b in 0..<2 where (a != b) != switched {
                        alt = min(alt, F[k][a] + link(k, a, b) + B[k + 1][b])
                    }
                }
                margin.append(alt - best)
            }
        }
        return Solution(orient: orient, margin: margin)
    }

    // MARK: Whole pass

    /// `locks`: the user's confirmations (shown as confirmed). `frozen`: held orders (the part
    /// before the latest correction, a prefix of the video); their review marks are taken from
    /// `previous` unchanged.
    static func run(_ raw: PoseTrack, locks: [Int8], frozen: [Int8]? = nil, previous: [UInt8] = [],
                    settings: Settings) -> PoseTrack {
        let n = raw.count
        let L = BodyGeometry.typicalLength(raw) ?? fallbackLength(raw)
        var obs = observe(raw)
        let seg = segment(&obs, t: raw.time, L: L, settings: settings)
        let K = seg.segments.count
        var out = raw
        out.flags = [UInt8](repeating: 0, count: n)
        for i in 0..<n where obs.merged[i] { out.flags[i] |= IdentityFlag.merged }
        var info = IdentityInfo()
        info.segments = K
        info.mergedFrames = obs.merged.filter { $0 }.count
        guard K > 0 else {
            out.identity = info
            return out
        }

        let slots = summarize(raw, obs, seg, L: L)
        let joins = links(slots, L: L, settings: settings)
        var segLocks = [Int?](repeating: nil, count: K)
        var constraints = [Int?](repeating: nil, count: K)
        var frozenSegment = [Bool](repeating: false, count: K)
        for (k, sg) in seg.segments.enumerated() {
            if let i = (sg.start...sg.end).first(where: { locks[$0] >= 0 && seg.segOf[$0] == k }) {
                segLocks[k] = Int(locks[i])
            }
            if let frozen, let i = (sg.start...sg.end).first(where: { $0 < frozen.count && frozen[$0] >= 0 && seg.segOf[$0] == k }) {
                frozenSegment[k] = true
                constraints[k] = Int(frozen[i])
            }
            if let l = segLocks[k] { constraints[k] = l }
        }
        var unaries = [[Double]](repeating: [0, 0], count: K)
        var frameModel: AppearanceModel?
        if settings.useAppearance, var model = appearanceModel(slots) {
            // Which look is called "A" is arbitrary (a solve without corrections renames the
            // animals so that the first segment keeps the tracker's labels). With corrections or
            // a held part, take the naming that agrees with them, so re-solving never renames.
            if constraints.contains(where: { $0 != nil }) {
                var keep = 0.0, renamed = 0.0
                for k in 0..<K {
                    guard let c = constraints[k] else { continue }
                    let u = unary(slots[k], model)
                    keep += u[c]
                    renamed += u[1 - c]
                }
                if renamed < keep { swap(&model.high, &model.low) }
            }
            unaries = slots.map { unary($0, model) }
            frameModel = model
            info.appearanceUsed = true
            info.appearanceSeparation = model.separation
        }
        var sol = solve(links: joins, unary: unaries, locks: constraints)
        let threshold = info.appearanceUsed ? settings.uncertainMargin : settings.uncertainMarginMotionOnly
        var scores = swapScores(slots, orient: sol.orient, margin: sol.margin, doubtful: threshold, window: settings.hintWindowSeconds)
        // Weak cues (size while walking, activity) join the decisions when they separate the
        // animals (label-free model) and agree with motion in this video (most decisions'
        // swap scores clearly negative). Per segment, so long stretches add up their evidence.
        if settings.useWeakCues && !info.appearanceUsed, var model = weakCueModel(slots) {
            var informative = scores.filter { abs($0) > 1e-9 }
            if informative.count >= settings.cueMinDecisions && median(&informative) <= settings.cueMedianScore {
                if constraints.contains(where: { $0 != nil }) {
                    // Same naming as the user's corrections / held part (see the colour model).
                    var keep = 0.0, renamed = 0.0
                    for k in 0..<K {
                        guard let c = constraints[k] else { continue }
                        let u = weakUnary(slots[k], model)
                        keep += u[c]
                        renamed += u[1 - c]
                    }
                    if renamed < keep { swap(&model.high, &model.low) }
                }
                info.cuesUsed = true
                let weak = slots.map { weakUnary($0, model) }
                sol = solve(links: joins, unary: zip(unaries, weak).map { [$0[0] + $1[0], $0[1] + $1[1]] }, locks: constraints)
                // Sharpen: fit each animal's cues to these labels and solve again (a few rounds).
                for _ in 0..<3 {
                    guard let fitted = fitCueModel(slots, orient: sol.orient) else { break }
                    let sharp = slots.map { cueUnary($0, fitted) }
                    let next = solve(links: joins, unary: zip(unaries, sharp).map { [$0[0] + $1[0], $0[1] + $1[1]] }, locks: constraints)
                    let changed = next.orient != sol.orient
                    sol = next
                    if !changed { break }
                }
                scores = swapScores(slots, orient: sol.orient, margin: sol.margin, doubtful: threshold, window: settings.hintWindowSeconds)
            }
        }
        // Without locks the overall naming is free: keep the first segment as tracked.
        if !constraints.contains(where: { $0 != nil }), sol.orient.first == 1 {
            sol.orient = sol.orient.map { 1 - $0 }
        }

        // Order of every frame: segment frames follow their segment; frames of a contact between
        // two segments are labelled frame by frame (continuity and look), pinned to both sides.
        var orientOf = [Int](repeating: sol.orient[0], count: n)
        for k in 0..<K {
            let sg = seg.segments[k]
            for i in sg.start...sg.end where seg.segOf[i] == k { orientOf[i] = sol.orient[k] }
        }
        var i0 = 0
        while i0 < n {
            guard seg.segOf[i0] < 0 else { i0 += 1; continue }
            var i1 = i0
            while i1 + 1 < n && seg.segOf[i1 + 1] < 0 { i1 += 1 }
            let left: (Int, Int)? = i0 > 0 ? (i0 - 1, sol.orient[seg.segOf[i0 - 1]]) : nil
            let right: (Int, Int)? = i1 + 1 < n ? (i1 + 1, sol.orient[seg.segOf[i1 + 1]]) : nil
            let labels = labelContact(i0, i1, left: left, right: right, raw: raw, obs: obs, L: L, model: frameModel)
            for i in i0...i1 { orientOf[i] = labels[i - i0] }
            i0 = i1 + 1
        }
        for i in 0..<n where orientOf[i] == 1 {
            out.swapAnimals(at: i)
            out.flags[i] |= IdentityFlag.swapped
        }
        for k in 0..<K where segLocks[k] != nil {
            info.lockedSegments += 1
            let sg = seg.segments[k]
            for i in sg.start...sg.end { out.flags[i] |= IdentityFlag.locked }
        }
        // Flag uncertain decisions: the break itself and the first moments after it.
        info.events = max(0, K - 1)
        func mark(_ k: Int, _ bit: UInt8) {
            let from = seg.segments[k].end + 1
            let next = seg.segments[k + 1]
            let until = raw.time[next.start] + settings.flagAfter
            var i = min(from, next.start)
            while i < n && (i <= next.start || raw.time[i] <= until) {
                out.flags[i] |= bit
                i += 1
            }
        }
        for k in 0..<max(0, K - 1) where sol.margin[k] < threshold && segLocks[k + 1] == nil {
            mark(k, IdentityFlag.uncertain)
        }
        // Swap hints: decisions the size / activity evidence still argues against.
        for k in 0..<scores.count where segLocks[k + 1] == nil {
            let doubtful = sol.margin[k] < threshold
            if scores[k] >= (doubtful ? settings.hintScore : settings.hintScoreConfident) {
                mark(k, IdentityFlag.suspect)
            }
        }
        // The held part keeps its order (already applied through the constraints) and the review
        // marks the user saw.
        if let lastHeld = (0..<K).last(where: { frozenSegment[$0] }) {
            for i in 0...seg.segments[lastHeld].end {
                out.flags[i] |= IdentityFlag.held
                if i < previous.count {
                    out.flags[i] = (out.flags[i] & ~IdentityFlag.marks) | (previous[i] & IdentityFlag.marks)
                }
            }
        }
        info.uncertainEvents = countBouts(out.flags, IdentityFlag.uncertain)
        info.suspectEvents = countBouts(out.flags, IdentityFlag.suspect)
        out.identity = info
        return out
    }

    /// Standardized features of one detection (same layout as `SegmentSlot.features`).
    static func frameFeatures(_ track: PoseTrack, _ obs: Observations, _ i: Int, _ s: Int, L: Double) -> [Double?] {
        let dims = min(track.appearanceDims, 3)
        var f = [Double?](repeating: nil, count: 1 + dims)
        let o = obs.slot[s][i]
        guard o.valid else { return f }
        if o.length.isFinite { f[0] = o.length / L / featureScales[0] }
        if dims > 0 {
            let base = (i * 2 + s) * track.appearanceDims
            for d in 0..<dims where track.appearance[base + d].isFinite {
                f[1 + d] = Double(track.appearance[base + d]) / featureScales[1 + d]
            }
        }
        return f
    }

    /// Order of each frame from `a` to `b` (a contact between two segments). The online tracker's
    /// frame-to-frame order is kept; when the segments on both sides were decided differently,
    /// the one switch is placed where it costs least (continuity and, when available, look).
    /// At most one switch, so the labels cannot flicker while the animals touch.
    static func labelContact(_ a: Int, _ b: Int, left: (index: Int, orient: Int)?, right: (index: Int, orient: Int)?,
                             raw: PoseTrack, obs: Observations, L: Double, model: AppearanceModel?) -> [Int] {
        let t = raw.time
        let frames = (a...b).filter { obs.slot[0][$0].valid || obs.slot[1][$0].valid }
        let fallback = left?.orient ?? right?.orient ?? 0
        guard let left, let right, left.orient != right.orient, !frames.isEmpty else {
            return [Int](repeating: fallback, count: b - a + 1)
        }

        func step(_ p: Int, _ i: Int) -> (keep: Double, swap: Double) {
            let dt = max(t[i] - t[p], 1e-3)
            var keep = 0.0, swap = 0.0
            func c(_ o: SlotObs, _ q: SlotObs) -> Double {
                guard q.valid else { return 1.5 }
                var x = o.anchor.distance(to: q.anchor) / L / (0.4 + 3 * min(dt, 2))
                if let turn = BodyGeometry.turn(o.axis, q.axis) { x += 1.5 * turn * turn * exp(-dt) }
                return min(x, 10)
            }
            for s in 0..<2 where obs.slot[s][i].valid {
                keep += c(obs.slot[s][i], obs.slot[s][p])
                swap += c(obs.slot[s][i], obs.slot[1 - s][p])
            }
            return (keep, swap)
        }
        func look(_ i: Int, _ o: Int) -> Double {
            guard let model else { return 0 }
            var total = 0.0
            for s in 0..<2 where obs.slot[s][i].valid && !obs.merged[i] {
                let f = frameFeatures(raw, obs, i, s, L: L)
                var q = 0.0
                var complete = true
                for (j, idx) in model.active.enumerated() {
                    guard let x = f[idx] else { complete = false; break }
                    q += x * model.axis[j]
                }
                guard complete else { continue }
                let high = (s == 0) == (o == 0)
                let z = (q - (high ? model.high : model.low)) / max(model.sigma, 1.0)
                total += min(z * z / 2, 4)
            }
            return total
        }

        // Chain: left boundary, contact frames, right boundary. Switching between chain[j - 1]
        // and chain[j] costs (swap − keep) there; frames before the switch take the left order.
        let chain = [left.index] + frames + [right.index]
        var extra = [Double](repeating: 0, count: chain.count)   // switch cost before chain[j]
        for j in 1..<chain.count {
            let s = step(chain[j - 1], chain[j])
            extra[j] = s.swap - s.keep
        }
        // Look of the contact frames under the left / right order (prefix sums).
        var lookLeft = [Double](repeating: 0, count: frames.count + 1)
        var lookRight = [Double](repeating: 0, count: frames.count + 1)
        for (j, f) in frames.enumerated() {
            lookLeft[j + 1] = lookLeft[j] + look(f, left.orient)
            lookRight[j + 1] = lookRight[j] + look(f, right.orient)
        }
        // Switch before contact frame j (0…frames.count; frames.count = just before the right segment).
        var bestJ = frames.count
        var best = Double.infinity
        for j in 0...frames.count {
            let c = extra[j + 1] + lookLeft[j] + (lookRight[frames.count] - lookRight[j])
            if c < best {
                best = c
                bestJ = j
            }
        }
        let switchFrame = bestJ < frames.count ? frames[bestJ] : b + 1
        return (a...b).map { $0 < switchFrame ? left.orient : right.orient }
    }

    // MARK: Helpers

    static func median(_ v: inout [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        v.sort()
        let m = v.count / 2
        return v.count % 2 == 1 ? v[m] : (v[m - 1] + v[m]) / 2
    }

    /// Weighted median of (value, weight) pairs (sorted in place).
    static func weightedMedian(_ v: inout [(Double, Double)]) -> Double {
        guard !v.isEmpty else { return .nan }
        v.sort { $0.0 < $1.0 }
        let total = v.reduce(0) { $0 + $1.1 }
        var acc = 0.0
        for (x, w) in v {
            acc += w
            if acc >= total / 2 { return x }
        }
        return v[v.count - 1].0
    }
}

// MARK: - Appearance sampling (identity cue only)

/// How the stored video pixels relate to the upright frame (EXIF-style, like
/// CGImagePropertyOrientation .up / .right / .left / .down).
enum RawOrientation: Int {
    case up, right, left, down
}

/// Maps upright-frame pixel positions to positions in the stored (raw) video buffer.
struct RawImageGeometry {
    let width: Int
    let height: Int
    let orientation: RawOrientation

    /// Size of the upright image built from this buffer.
    var uprightSize: (width: Int, height: Int) {
        switch orientation {
        case .up, .down: return (width, height)
        case .left, .right: return (height, width)
        }
    }

    /// Raw buffer pixel for upright pixel (u, v), nil outside the image.
    func rawPixel(_ u: Int, _ v: Int) -> (x: Int, y: Int)? {
        let up = uprightSize
        guard u >= 0, v >= 0, u < up.width, v < up.height else { return nil }
        switch orientation {
        case .up: return (u, v)
        case .down: return (width - 1 - u, height - 1 - v)
        // Displayed after a 90° clockwise turn: upright (u, v) = (H − 1 − y, x).
        case .right: return (v, height - 1 - u)
        // Displayed after a 90° counter-clockwise turn: upright (u, v) = (y, W − 1 − x).
        case .left: return (width - 1 - v, u)
        }
    }
}

enum AppearanceSampler {
    /// Luminance and two chroma channels.
    static let dims = 3

    /// Points on the animal's back (upright pixels) where its fur colour is read.
    static func samplePoints(_ p: AnimalPose, bodyLength L: Double) -> [V2] {
        var pts: [V2] = []
        let body = BodyGeometry.point(p, .bodyCenter)
        let neck = BodyGeometry.point(p, .neck)
        let tail = BodyGeometry.point(p, .tailBase)
        if let body { pts.append(body) }
        if let body, let neck { pts.append(V2.mid(body, neck)) }
        if let body, let tail { pts.append(V2.mid(body, tail)) }
        if let body, let axis = BodyGeometry.axis(p) {
            let side = axis.perp * (0.08 * L)
            pts.append(body + side)
            pts.append(body - side)
        }
        return pts
    }

    /// Mean [luminance, R − Y, B − Y] (0…1 scale) around the sample points; NaNs when nothing
    /// could be read. `pixel(x, y)` returns raw-buffer RGB (0…255).
    static func descriptor(_ p: AnimalPose, raw: RawImageGeometry, frameSize: V2, bodyLength L: Double,
                           pixel: (Int, Int) -> (r: Float, g: Float, b: Float)) -> [Float] {
        let missing = [Float](repeating: .nan, count: dims)
        guard p.detected, frameSize.x > 0, frameSize.y > 0 else { return missing }
        let up = raw.uprightSize
        let sx = Double(up.width) / frameSize.x, sy = Double(up.height) / frameSize.y
        let step = max(1, Int((0.025 * L * sx).rounded()))
        var r: Float = 0, g: Float = 0, b: Float = 0, m: Float = 0
        for q in samplePoints(p, bodyLength: L) {
            let cu = Int((q.x * sx).rounded()), cv = Int((q.y * sy).rounded())
            for dv in -1...1 {
                for du in -1...1 {
                    guard let px = raw.rawPixel(cu + du * step, cv + dv * step) else { continue }
                    let c = pixel(px.x, px.y)
                    r += c.r; g += c.g; b += c.b; m += 1
                }
            }
        }
        guard m > 0 else { return missing }
        r /= m * 255; g /= m * 255; b /= m * 255
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        return [y, r - y, b - y]
    }
}
