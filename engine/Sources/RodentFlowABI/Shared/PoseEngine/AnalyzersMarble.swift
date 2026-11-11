// AnalyzersMarble.swift — marble burying from video (RodentFlow 2.1).
//
// Each marble is a one-dimensional curve over time. At every sample the mean brightness inside the marble (m) and in
// a ring of bedding just around it (b) are read from the video (Shared/Vision/MarbleSampler.swift). With m0 the
// marble's brightness in a reference frame, c = (m − m0) / (b − m0) is the covered fraction of its visible area:
// the mean inside the circle is the area-weighted mean of marble and bedding, m = (1 − f)·m0 + f·b. c = 0 looks as at
// the start, c = 1 looks like bedding. Using the ratio instead of m − m0 makes one threshold (e.g. 2/3) work for every
// marble, bedding and lighting.
//
// The tracking decides which samples can be used: the mouse must be detected, every keypoint (and the tail, extended
// behind the tail base) away from the marble, and the mouse gone from it for ≥ 1 s. Covering changes only during a
// visit, so the median of the usable samples between two visits is one step of the curve. A marble is buried from the
// first step that reaches the threshold and stays there to the end of the window.

import Foundation

/// Brightness of each marble and of a ring of bedding around it, read from the video at a fixed interval.
struct MarbleSamples: Codable, Equatable {
    static let fileName = "marble_samples.json"
    /// MarbleGrid.sampleKey of the geometry and time range the samples were read with.
    var key: String
    /// Video seconds of the samples.
    var times: [Double]
    /// Per marble, per sample: mean luminance (0–255) inside 0.8 × the marble radius.
    var inner: [[Float]]
    /// Per marble, per sample: mean luminance of the ring 1.3–2 × the radius (the bedding around it).
    var ring: [[Float]]

    var marbleCount: Int { inner.count }
}

enum MarbleAnalyzer {
    /// Minimum brightness difference between a marble and its bedding in the reference frame (0–255).
    static let minContrast: Float = 12
    /// A visit that raises the covered fraction by at least this much is a burying event.
    static let eventStep = 0.2

    struct Marble {
        var center: V2
        var reference: Int?
        var contrast: Float = 0
        /// Steps of the curve: start time (video s) and covered fraction.
        var levels: [(time: Double, c: Double)] = []
        var final: Double?
        var buriedAt: Double?
        var visits = 0
        var events: [Double] = []
        var pushed = false
        /// No usable view after the last visit (the mouse stayed at the marble to the end): `final` is from before it.
        var endHidden = false
    }

    static func analyze(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        let centers = MarbleGrid.centers(c.session.calibration, params: p, mapping: c.fs.mapping)
        guard !centers.isEmpty, c.fs.isMetric else {
            r.warnings.append(L10n.tr("需要矩形场地标定，并把 1–4 号手柄放到四个角上的珠子中心。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let radius = max(0.2, p.mbDiameter / 2)
        let win = tb.windowDuration
        let windowStart = tb.windowStartTime
        // End of the last sample in the window (video time; gaps in the track do not shorten it).
        let windowEnd = (0..<c.n).last(where: { tb.inWindow[$0] }).map { tb.t[$0] + tb.dur[$0] } ?? windowStart + win

        // Body length (cm) for the "away from the marble" margin.
        let lengths = a.bodyLength.filter { $0.isFinite && $0 > 2 && $0 < 20 }
        let L = lengths.isEmpty ? 8 : lengths.sorted()[lengths.count / 2]
        let keyMargin = radius + 0.3 * L
        let tailMargin = radius + 0.1 * L
        // Frames where the mouse is at (covers) each marble: any keypoint within the margin, or the tail.
        var near = [[Bool]](repeating: [Bool](repeating: false, count: c.n), count: centers.count)
        var noseAt = [Int?](repeating: nil, count: c.n)
        let approach = radius + max(0, p.mbApproach)
        for i in 0..<c.n where a.detected[i] {
            let pts = KP.allCases.compactMap { a.pos($0, i) }
            var tail: (V2, V2)?
            if let tb0 = a.pos(.tailBase, i), let neck = a.pos(.neck, i) ?? a.pos(.bodyCenter, i) {
                let dir = (tb0 - neck).normalized
                if dir.isFinite { tail = (tb0, tb0 + dir * (0.8 * L)) }
            }
            for (j, m) in centers.enumerated() {
                if pts.contains(where: { $0.distance(to: m) < keyMargin }) { near[j][i] = true; continue }
                if let tail, distanceToSegment(m, tail.0, tail.1) < tailMargin { near[j][i] = true }
            }
            if let nose = a.pos(.nose, i) {
                var best: (Int, Double)?
                for (j, m) in centers.enumerated() {
                    let d = nose.distance(to: m)
                    if d <= approach, d < (best?.1 ?? .infinity) { best = (j, d) }
                }
                noseAt[i] = best?.0
            }
        }

        var marbles = centers.map { Marble(center: $0) }
        var lowContrast = 0
        var haveSamples = false
        if let s = c.marbles, s.marbleCount == centers.count, s.times.count >= 2, s.ring.count == centers.count,
           s.inner.allSatisfy({ $0.count == s.times.count }), s.ring.allSatisfy({ $0.count == s.times.count }) {
            haveSamples = true
            for j in marbles.indices {
                analyzeMarble(&marbles[j], index: j, samples: s, near: near[j], c: c, windowStart: windowStart, windowEnd: windowEnd)
                if marbles[j].reference != nil && marbles[j].contrast < minContrast { lowContrast += 1 }
            }
        }
        let threshold = min(max(p.mbThreshold, 0.1), 1)
        let usable = marbles.filter { $0.final != nil && $0.contrast >= minContrast }
        let buried = usable.filter { ($0.final ?? 0) >= threshold }
        let buriedTimes = marbles.compactMap { m -> Double? in m.contrast >= minContrast ? m.buriedAt : nil }
        let events = marbles.flatMap(\.events).filter { $0 >= windowStart && $0 <= windowEnd }.sorted()

        // Approaches: the nose within the approach distance of a marble.
        let approachMask = noseAt.map { $0 != nil }
        let approachBouts = Bouts.find(approachMask, tb, mergeGap: 0.2)
        var approached = Set<Int>()
        for i in 0..<c.n where tb.inWindow[i] { if let j = noseAt[i] { approached.insert(j) } }

        // c is the covered share of the marble's top-view visible area: c ≥ 0.67 corresponds to ~90 % burial by depth,
        // stricter than the by-eye "2/3 covered" rule. The count is shown out of the scored marbles.
        let thresholdPct = num((threshold * 100).rounded())
        let halfCount = usable.filter { ($0.final ?? 0) >= 0.5 }.count
        let fullCount = usable.filter { ($0.final ?? 0) >= 0.95 }.count
        r.metrics = [
            c.m("buried_count", L10n.tr("埋住的珠子"), haveSamples ? Double(buried.count) : nil, "", 0,
                info: threshold >= 0.6 ? L10n.tr("可见面积被盖住 ≥ \(thresholdPct)% 的珠子数（比肉眼按表面 2/3 判断更严格），分母为可评分的珠子")
                                       : L10n.tr("可见面积被盖住 ≥ \(thresholdPct)% 的珠子数，分母为可评分的珠子"))
                .showing(haveSamples ? "\(buried.count) / \(usable.count)" : nil),
            c.m("buried_pct", L10n.tr("埋住的比例"), haveSamples && !usable.isEmpty ? Double(buried.count) / Double(usable.count) * 100 : nil, "%", 0),
            c.m("buried_half", L10n.tr("盖住一半以上"), haveSamples ? Double(halfCount) : nil, "", 0),
            c.m("buried_full", L10n.tr("几乎全埋（≥ 95%）"), haveSamples ? Double(fullCount) : nil, "", 0),
            c.m("marbles_scored", L10n.tr("可评分的珠子"), haveSamples ? Double(usable.count) : nil, "", 0, info: L10n.tr("参照帧中和垫料有足够反差的珠子")),
            c.m("first_bury_latency", L10n.tr("首次埋珠潜伏期"), buriedTimes.min().map { max(0, $0 - windowStart) }, "s", 0),
            c.m("bury_events", L10n.tr("埋珠事件"), haveSamples ? Double(events.count) : nil, "", 0, info: L10n.tr("一次访问后遮盖程度上升 ≥ 0.2")),
            c.m("approaches", L10n.tr("接近珠子次数"), Double(approachBouts.count), "", 0,
                info: String(format: L10n.tr("鼻尖距珠子边缘 ≤ %@ cm"), num(p.mbApproach))),
            c.m("approach_time", L10n.tr("接近珠子时间"), approachBouts.reduce(0) { $0 + $1.duration }, "s", 1),
            c.m("first_approach_latency", L10n.tr("首次接近潜伏期"), approachBouts.first.map { $0.start - windowStart }, "s", 1),
            c.m("marbles_approached", L10n.tr("接近过的珠子"), Double(approached.count), "", 0)
        ] + c.locomotionMetrics()
        r.primaryKey = "buried_count"
        if haveSamples {
            r.keyNote = L10n.tr("≥ 1/2：\(halfCount) · ≥ 95%：\(fullCount) · 共 \(usable.count) 颗可评分")
        }

        // Plot: green = still visible, red = buried, amber = check (pushed away, low contrast, no usable sample).
        let dots = marbles.map { m -> PlotDot in
            let color: ColorKey
            if m.final == nil || m.contrast < minContrast || m.pushed || m.endHidden { color = .warning }
            else if (m.final ?? 0) >= threshold { color = .error }
            else { color = .target }
            return PlotDot(p: m.center, color: color, radius: radius * 1.6)
        }
        r.blocks.append(ReportBlock(title: L10n.tr("结束时的珠子"), caption: L10n.tr("绿 = 露出，红 = 埋住，黄 = 需要看一下（可能被推走、反差不够或没有可用画面）"),
                                    kind: .arena(c.arenaPlot(dots: dots))))
        let rows = marbles.enumerated().map { (j, m) -> [String] in
            var flag = ""
            if m.reference == nil { flag = L10n.tr("没有参照") }
            else if m.contrast < minContrast { flag = L10n.tr("反差不够") }
            else if m.final == nil { flag = L10n.tr("没有可用画面") }
            else if m.pushed { flag = L10n.tr("可能被推走") }
            else if m.endHidden { flag = L10n.tr("结束时被挡住") }
            return [String(j + 1), m.final.map { String(format: "%.2f", $0) } ?? "—",
                    m.buriedAt.map { String(format: "%.0f", $0 - windowStart) } ?? "—", String(m.visits), flag]
        }
        r.blocks.append(ReportBlock(title: L10n.tr("每颗珠子"), caption: L10n.tr("遮盖程度 0 = 和开始时一样，1 = 和垫料一样；埋住时间为分析起点之后的秒数"),
                                    kind: .table(TableData(columns: ["#", L10n.tr("遮盖程度"), L10n.tr("埋住时间"), L10n.tr("访问"), L10n.tr("备注")], rows: rows,
                                                           rowColors: marbles.map { m -> ColorKey? in (m.final ?? 0) >= threshold && m.contrast >= minContrast ? .error : nil }))))
        // Buried marbles over time (step curve) and the stored series for the group time course.
        func buriedCount(at t: Double) -> Int {
            marbles.filter { m in
                guard m.contrast >= minContrast else { return false }
                let level = m.levels.last(where: { $0.time <= t })?.c ?? 0
                return level >= threshold
            }.count
        }
        if haveSamples {
            // Count at the end of each full bin, placed at the bin centre (series contract; before build 23 at the bin end).
            let bin = max(60, p.timeBin)
            var x: [Double] = [], y: [Double] = []
            for b in c.courseBins(bin).prefix(200) {
                x.append(b.x)
                y.append(Double(buriedCount(at: b.start + bin)))
            }
            if x.count > 1 {
                r.series = [FlowResultSeries(key: "buried_count_bin", name: "Buried marbles at the end of each bin", unit: "",
                                             xLabel: TimeCourseLabel.english(bin: bin), x: x, y: y)]
                r.blocks.append(ReportBlock(title: L10n.tr("埋住的珠子随时间"), caption: L10n.tr("每段结束时埋住的珠子数，画在每段中点"), kind: .line(LineData(series: [
                    LineSeries(name: L10n.tr("埋住的珠子"), color: .error, points: zip(x, y).map { LinePoint(x: $0, y: $1) })],
                    xLabel: c.courseAxis(bin), yLabel: L10n.tr("颗"), yRange: 0...Double(max(1, centers.count))))))
            }
            if let d = c.distanceSeries(bin: bin) { r.series.append(d) }
        }
        let eventEpochs = events.prefix(200).enumerated().map { Epoch(name: "B\($0.offset + 1)", start: $0.element, end: $0.element + 0.5, color: .error) }
        let tracks = [TimelineTrack(name: L10n.tr("接近珠子"), color: .object, bouts: approachBouts)]
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: L10n.tr("竖条为埋珠事件"), kind: .timeline(c.timeline(tracks, epochs: Array(eventEpochs)))))
        r.reviewTracks = tracks
        r.reviewEpochs = Array(eventEpochs)
        r.frameColumns = [("near_marble", noseAt.map { $0.map { Double($0 + 1) } ?? .nan }),
                          ("marbles_buried", haveSamples ? (0..<c.n).map { Double(buriedCount(at: tb.t[$0])) } : [Double](repeating: .nan, count: c.n))]

        if !haveSamples {
            r.warnings.append(L10n.tr("还没有读取珠子的画面：埋珠数需要视频。请确认视频副本还在，App 会在分析时自动读取。"))
        }
        if lowContrast > 0 {
            r.warnings.append(String(format: L10n.tr("%d 颗珠子在参照帧中和垫料反差不够，没有评分：换颜色反差更大的珠子或垫料。"), lowContrast))
        }
        let hidden = marbles.filter { $0.endHidden && $0.contrast >= minContrast }.count
        if hidden > 0 {
            r.warnings.append(String(format: L10n.tr("%d 颗珠子在最后一次被碰之后直到分析结束都没有能看清的画面：结果取自那次之前，请在回看中核对。"), hidden))
        }
        let pushed = marbles.filter(\.pushed).count
        if pushed > 0 {
            r.warnings.append(String(format: L10n.tr("%d 颗珠子在一次访问中从露出直接变成完全看不见：可能是被推走了，请在回看中确认。"), pushed))
        }
        if haveSamples, marbles.contains(where: { $0.reference.map { (c.marbles?.times[$0] ?? 0) >= windowStart } ?? false }) {
            r.warnings.append(L10n.tr("放入小鼠前没有可用的参照画面，参照帧取自分析开始后小鼠不在珠子旁的时刻。最好让录像从放入小鼠之前开始。"))
        }
        r.methods.append(String(format: L10n.tr("每 %@ s 读取一次每颗珠子圆内（0.8 倍半径）和外圈垫料（1.3–2 倍半径）的平均亮度，遮盖程度 c = (m − m0) ÷ (b − m0)，m0 为参照帧中珠子的亮度。只用小鼠已离开该珠子 ≥ %@ s、且所有关键点距珠子中心 > 半径 + 0.3 倍体长（尾巴按尾根之后 0.8 倍体长推算）时的画面；两次访问之间取中位数。分析结束时 c ≥ %@ 的珠子记为埋住（按可见面积计；俯视时表面盖住 2/3 对应约 11%% 的可见面积被盖住，所以计数可能低于肉眼按表面计的结果）。"),
                                num(max(0.1, p.mbSampleInterval)), num(p.mbLeaveWait), num(threshold)))
        r.methods.append(String(format: L10n.tr("接近珠子为鼻尖距珠子边缘 ≤ %@ cm；埋珠事件为一次访问后 c 上升 ≥ 0.2。"), num(p.mbApproach)))
        return r
    }

    /// Steps of one marble's covered fraction from its samples.
    static func analyzeMarble(_ m: inout Marble, index j: Int, samples s: MarbleSamples, near: [Bool], c: AnalysisContext,
                              windowStart: Double, windowEnd: Double) {
        let tb = c.tb
        let p = c.p
        // Last frame time at the marble, for every frame (−∞ before the first visit).
        var lastNear = [Double](repeating: -.infinity, count: c.n)
        var last = -Double.infinity
        for i in 0..<c.n {
            if near[i] { last = tb.t[i] }
            lastNear[i] = last
        }
        func frame(at t: Double) -> Int? {
            guard c.n > 0 else { return nil }
            var i = min(tb.index(atOrAfter: t), c.n - 1)
            if i > 0, abs(tb.t[i - 1] - t) < abs(tb.t[i] - t) { i -= 1 }
            return abs(tb.t[i] - t) <= 0.5 ? i : nil
        }
        // A sample is usable when the mouse is seen away from the marble and left it ≥ the wait; before the window starts
        // (the mouse not yet in the cage) or after it ends (taken out) an undetected frame is also usable.
        func usable(_ k: Int) -> Bool {
            let t = s.times[k]
            guard let i = frame(at: t) else { return t < windowStart }
            if !c.a0.detected[i] { return t < windowStart || t >= windowEnd }
            if near[i] { return false }
            return t - lastNear[i] >= max(0, p.mbLeaveWait)
        }
        let usableIdx = s.times.indices.filter { usable($0) && s.inner[j][$0].isFinite && s.ring[j][$0].isFinite }
        guard let ref = usableIdx.first else { return }
        m.reference = ref
        let m0 = Double(s.inner[j][ref])
        m.contrast = abs(s.ring[j][ref] - Float(m0))
        guard m.contrast >= minContrast else { return }
        func covered(_ k: Int) -> Double? {
            let b = Double(s.ring[j][k]), mk = Double(s.inner[j][k])
            guard abs(b - m0) >= Double(minContrast) * 0.5 else { return nil }
            return min(1.2, max(-0.2, (mk - m0) / (b - m0)))
        }
        // Visits to the marble inside the window (merged across short gaps).
        let visits = Bouts.find(near, tb, mergeGap: 0.5)
        m.visits = visits.count
        // Intervals between visits: from the reference to the first visit, then after each visit to the next one.
        var bounds: [(start: Double, end: Double, visit: Bout?)] = []
        var t0 = s.times[ref]
        var prev: Bout?
        for v in visits {
            bounds.append((t0, v.start, prev))
            t0 = v.end
            prev = v
        }
        // The last stretch runs past the window end until the mouse comes back to the marble (at most 2 min): what the
        // test left behind is often seen best once the mouse is out of the way.
        var tailEnd = windowEnd + 120
        if let back = (0..<c.n).first(where: { tb.t[$0] >= windowEnd && near[$0] }) { tailEnd = min(tailEnd, tb.t[back]) }
        bounds.append((t0, max(t0, tailEnd), prev))
        var lastLevel: Double?
        for (bi, b) in bounds.enumerated() {
            let values = usableIdx.filter { s.times[$0] >= b.start && s.times[$0] < b.end }.compactMap(covered)
            guard !values.isEmpty else {
                if bi == bounds.count - 1 && b.visit != nil { m.endHidden = true }
                continue
            }
            let level = values.sorted()[values.count / 2]
            let at = b.visit?.end ?? s.times[ref]
            if let l = lastLevel, level - l >= eventStep { m.events.append(at) }
            if let l = lastLevel, l < 0.2, level > 0.9 { m.pushed = true }
            m.levels.append((at, level))
            lastLevel = level
        }
        m.final = m.levels.last?.c
        let threshold = min(max(p.mbThreshold, 0.1), 1)
        // Buried from the first step at or above the threshold that stays there to the end.
        if let final = m.final, final >= threshold {
            var k = m.levels.count - 1
            while k > 0 && m.levels[k - 1].c >= threshold { k -= 1 }
            m.buriedAt = max(m.levels[k].time, windowStart)
        }
    }

    static func distanceToSegment(_ p: V2, _ a: V2, _ b: V2) -> Double {
        let ab = b - a
        let len2 = ab.x * ab.x + ab.y * ab.y
        guard len2 > 1e-9 else { return p.distance(to: a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2))
        return p.distance(to: a + ab * t)
    }
}
