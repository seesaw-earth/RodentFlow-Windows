// AnalyzersZeroMaze.swift — elevated zero maze from pose (RodentFlow 2.0: iOS build 15, Mac build 14).
//
// Geometry: the circle calibration (C = center, R = outer edge, outer diameter) plus the track width; the O handle
// marks the middle of one open segment; the four 90° segments alternate open / closed (standard layout,
// Shepherd et al. 1994). Location is the segment of the body center's angle; with the "full" rule an entry also
// needs the tail base in the new segment (≈ four-paw entry, as in the EPM analysis).
// Measures (Shepherd et al. 1994; Braun et al. 2011; Tucker & McCabe 2017):
//   • open-segment time %, entries, entry ratio, latency to the first open entry, transitions, distance;
//   • head dips: body center in an open segment, nose beyond the inner or outer edge (counted separately);
//   • closed-segment peeks: body center and tail base in a closed segment, nose across the boundary in the
//     open segment, then withdrawn (an entry that follows within 0.5 s is the start of the entry, not a peek);
//   • stretched-attend postures (EPM criteria), and those made from a closed segment toward an open one.

import Foundation

enum ZeroMazeAnalyzer {
    static func analyze(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        let cal = c.session.calibration
        guard let g = ZeroMazeGeometry.from(cal, mapping: c.fs.mapping) else {
            r.warnings.append(L10n.tr("需要圆形标定（C 放中心、R 拖到外缘、输入外径），并填写跑道宽度。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        if cal.ringWidthCM <= 0 {
            r.warnings.append(L10n.tr("标定里没有跑道宽度：暂按 5 cm 计算。请在“场地尺寸”里填写装置的跑道宽度。"))
        }
        if cal.markers["open"] == nil {
            r.warnings.append(L10n.tr("没有放置 O 手柄：开放段按画面上方计算。请把 O 拖到一个开放段的中点。"))
        }

        // Segment of a point on the track (nil off the track: a tracking error or a missing keypoint).
        func seg(_ q: V2?) -> Int? {
            guard let q, g.onTrack(q, tolerance: 2) else { return nil }
            return g.segment(q)
        }

        // Location with entry hysteresis: a new segment needs the body center (and, with the full rule, the tail
        // base when it is tracked) in it; off-track frames keep the previous segment.
        let full = p.entryRule != "body"
        var state = [Int](repeating: -1, count: c.n)
        var bodySeg = [Int?](repeating: nil, count: c.n)
        var cur = -1
        for i in 0..<c.n {
            let b = seg(a.pos(.bodyCenter, i))
            bodySeg[i] = b
            if let b {
                if cur < 0 || !full {
                    cur = b
                } else if b != cur {
                    if let t = seg(a.pos(.tailBase, i)) {
                        if t == b { cur = b }
                    } else {
                        cur = b
                    }
                }
            }
            state[i] = cur
        }
        let inOpen = state.map { $0 >= 0 && ZeroMazeGeometry.isOpen($0) }
        let inClosed = state.map { $0 >= 0 && !ZeroMazeGeometry.isOpen($0) }
        let tOpen = tb.total(inOpen), tClosed = tb.total(inClosed)

        var openEntries = 0, closedEntries = 0
        var prev: Int?
        for i in 0..<c.n where tb.inWindow[i] {
            let s = state[i]
            guard s >= 0 else { continue }
            if let pv = prev, pv != s {
                if ZeroMazeGeometry.isOpen(s) { openEntries += 1 } else { closedEntries += 1 }
            }
            prev = s
        }
        let transitions = openEntries + closedEntries

        // Head dips over the inner or outer edge while the body center is in an open segment.
        let beyond = max(0, p.ezmDipBeyond)
        let far = beyond + 8
        var dipRaw = [Bool](repeating: false, count: c.n)
        var dipEdge = [Double](repeating: 0, count: c.n)
        for i in 0..<c.n {
            guard let b = bodySeg[i], ZeroMazeGeometry.isOpen(b), let nose = a.pos(.nose, i) else { continue }
            let rn = g.radius(nose)
            if rn <= g.inner - beyond && rn >= g.inner - far {
                dipRaw[i] = true
                dipEdge[i] = 1
            } else if rn >= g.outer + beyond && rn <= g.outer + far {
                dipRaw[i] = true
                dipEdge[i] = 2
            }
        }
        let dips = Bouts.find(dipRaw, tb, minDuration: p.headDipMin, mergeGap: 0.15)
        var innerDips: [Bout] = [], outerDips: [Bout] = []
        for d in dips {
            var nIn = 0, nOut = 0
            for i in d.i0...min(d.i1, c.n - 1) {
                if dipEdge[i] == 1 { nIn += 1 } else if dipEdge[i] == 2 { nOut += 1 }
            }
            if nIn >= nOut { innerDips.append(d) } else { outerDips.append(d) }
        }
        let dipMask = Bouts.mask(dips, count: c.n)
        var edgeColumn = [Double](repeating: 0, count: c.n)
        for d in innerDips { for i in d.i0...min(d.i1, c.n - 1) { edgeColumn[i] = 1 } }
        for d in outerDips { for i in d.i0...min(d.i1, c.n - 1) { edgeColumn[i] = 2 } }

        // Closed-segment peeks: nose across the boundary while the body center and tail base stay closed.
        var peekRaw = [Bool](repeating: false, count: c.n)
        for i in 0..<c.n {
            guard let b = bodySeg[i], !ZeroMazeGeometry.isOpen(b), let nose = a.pos(.nose, i), g.onTrack(nose, tolerance: 3) else { continue }
            if let t = seg(a.pos(.tailBase, i)), t != b { continue }
            if ZeroMazeGeometry.isOpen(g.segment(nose)) { peekRaw[i] = true }
        }
        let peekBouts = Bouts.find(peekRaw, tb, minDuration: p.pokeMin, mergeGap: 0.15)
        let peeks = peekBouts.filter { bout in
            let lo = min(bout.i1, c.n - 1)
            let hi = min(c.n, tb.index(atOrAfter: bout.end + 0.5) + 1)
            for j in stride(from: lo, to: hi, by: 1) where state[j] >= 0 && ZeroMazeGeometry.isOpen(state[j]) { return false }
            return true
        }
        let peekMask = Bouts.mask(peeks, count: c.n)

        // Stretched-attend posture (EPM criteria); from a closed segment toward an open one.
        let l0 = c.values(a.bodyLength).finiteMedian ?? .nan
        let elong = a.bodyLength.map { l0 > 0 ? $0 / l0 : .nan }
        var sapRaw = [Bool](repeating: false, count: c.n)
        for i in 0..<c.n where elong[i].isFinite && a.speed[i].isFinite {
            sapRaw[i] = elong[i] >= p.sapElongation && a.speed[i] < p.sapSpeed
        }
        let saps = Bouts.find(sapRaw, tb, minDuration: p.sapMin, mergeGap: 0.15)
        let towardOpen = saps.filter { bout in
            let mid = min(c.n - 1, (bout.i0 + bout.i1) / 2)
            guard let b = bodySeg[mid], !ZeroMazeGeometry.isOpen(b),
                  let body = a.pos(.bodyCenter, mid), let nose = a.pos(.nose, mid) else { return false }
            if g.segment(nose) != b { return true }
            return g.boundaryDistance(nose) < g.boundaryDistance(body) - 0.5 * Double.pi / 180
        }
        let sapMask = Bouts.mask(saps, count: c.n)

        r.metrics = [
            c.m("open_time_pct", L10n.tr("开放段时间"), c.percent(tOpen, tOpen + tClosed), "%", 1, info: L10n.tr("开放段 ÷（开放段 + 闭合段）")),
            c.m("open_time", L10n.tr("开放段时间"), tOpen, "s", 1),
            c.m("closed_time", L10n.tr("闭合段时间"), tClosed, "s", 1),
            c.m("open_entries", L10n.tr("开放段进入次数"), Double(openEntries), "", 0),
            c.m("closed_entries", L10n.tr("闭合段进入次数"), Double(closedEntries), "", 0),
            c.m("open_entries_pct", L10n.tr("开放段进入比例"), c.percent(Double(openEntries), Double(transitions)), "%", 1,
                info: L10n.tr("开放段进入 ÷ 全部进入")),
            c.m("open_latency", L10n.tr("首次进入开放段"), tb.firstTime(inOpen), "s", 1),
            c.m("transitions", L10n.tr("开闭段转换次数"), Double(transitions), "", 0),
            c.m("head_dips", L10n.tr("头探次数"), Double(dips.count), "", 0, info: L10n.tr("内缘 + 外缘")),
            c.m("head_dips_inner", L10n.tr("内缘头探"), Double(innerDips.count), "", 0),
            c.m("head_dips_outer", L10n.tr("外缘头探"), Double(outerDips.count), "", 0),
            c.m("head_dip_time", L10n.tr("头探时间"), dips.reduce(0) { $0 + $1.duration }, "s", 1),
            c.m("closed_peeks", L10n.tr("闭合段探出次数"), Double(peeks.count), "", 0, info: L10n.tr("身体和尾根在闭合段，鼻尖伸进开放段后退回")),
            c.m("closed_peek_time", L10n.tr("闭合段探出时间"), peeks.reduce(0) { $0 + $1.duration }, "s", 1),
            c.m("sap_count", L10n.tr("伸展评估姿势"), Double(saps.count), L10n.tr("次"), 0),
            c.m("sap_toward_open", L10n.tr("闭合段朝向开放段的 SAP"), Double(towardOpen.count), L10n.tr("次"), 0),
            c.m("sap_time", L10n.tr("SAP 时间"), saps.reduce(0) { $0 + $1.duration }, "s", 1)
        ] + c.locomotionMetrics()
        r.primaryKey = "open_time_pct"

        let dipDots = c.dots(.nose, where: dipMask, color: .headDip, radius: 1.6)
        let peekDots = c.dots(.nose, where: peekMask, color: .poke, radius: 1.6)
        let sapDots = c.dots(.bodyCenter, where: sapMask, color: .sap, radius: 1.4)
        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("红点 = 头探时鼻尖；橙点 = 闭合段探出；紫点 = 伸展评估姿势"), dots: dipDots + peekDots + sapDots))
        r.blocks.append(c.heatBlock(caption: L10n.tr("身体中心的停留时间；中间的空洞不属于场地")))
        let names = [L10n.tr("开放段 1"), L10n.tr("闭合段 1"), L10n.tr("开放段 2"), L10n.tr("闭合段 2")]
        var segItems: [BarItem] = []
        for k in 0..<4 {
            let open = ZeroMazeGeometry.isOpen(k)
            segItems.append(BarItem(label: names[k], value: tb.total(state.map { $0 == k }), color: open ? .open : .closed))
        }
        r.blocks.append(ReportBlock(title: L10n.tr("各段时间"), caption: L10n.tr("开放段 1 以 O 手柄为中点，顺序沿画面逆时针方向"), kind: .bars(BarData(items: segItems, unit: "s"))))
        // Full bins only; a bin where the segment is never known has no bar (before build 23: drawn as 0 %).
        let bins = c.courseBins(p.timeBin)
        if bins.count > 1 {
            var items: [BarItem] = []
            for (k, b) in bins.enumerated() {
                let o = c.total(inOpen, from: b.start, to: b.end), cl = c.total(inClosed, from: b.start, to: b.end)
                guard o + cl > 0 else { continue }
                items.append(BarItem(label: c.binLabel(k, b.start, b.start + max(p.timeBin, 1)), value: o / (o + cl) * 100, color: .open))
            }
            if !items.isEmpty {
                r.blocks.append(ReportBlock(title: L10n.tr("分段开放段时间"),
                                            caption: L10n.tr("每 \(AnalysisContext.durationText(p.timeBin)) 内开放段时间所占的比例；最后不满 90% 的一段不画"),
                                            kind: .bars(BarData(items: items, unit: "%", decimals: 0))))
            }
        }
        let tracks = [
            TimelineTrack(name: L10n.tr("开放段"), color: .open, bouts: Bouts.find(inOpen, tb)),
            TimelineTrack(name: L10n.tr("闭合段"), color: .closed, bouts: Bouts.find(inClosed, tb)),
            TimelineTrack(name: L10n.tr("内缘头探"), color: .headDip, bouts: innerDips),
            TimelineTrack(name: L10n.tr("外缘头探"), color: .headDip, bouts: outerDips),
            TimelineTrack(name: L10n.tr("闭合段探出"), color: .poke, bouts: peeks),
            TimelineTrack(name: "SAP", color: .sap, bouts: saps)
        ]
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [
            ("in_open_segment", AnalysisContext.flag(inOpen)), ("in_closed_segment", AnalysisContext.flag(inClosed)),
            ("segment", state.map { $0 >= 0 ? Double($0 + 1) : .nan }),
            ("head_dip", AnalysisContext.flag(dipMask)), ("head_dip_edge", edgeColumn),
            ("closed_peek", AnalysisContext.flag(peekMask)), ("stretched_attend", AnalysisContext.flag(sapMask)), ("elongation", elong)
        ]
        r.methods.append(full
            ? L10n.tr("所在段按身体中心的方位角判断（四段等分、开闭交替，O 手柄为一个开放段的中点）；进入新的一段需身体中心和尾根都在该段内（近似四爪进入，尾根缺失时按身体中心）。")
            : L10n.tr("所在段按身体中心的方位角判断（四段等分、开闭交替，O 手柄为一个开放段的中点）。"))
        r.methods.append(String(format: L10n.tr("跑道外径 %@ cm、宽 %@ cm（内径 %@ cm）。"),
                                num((2 * g.outer * 10).rounded() / 10), num((g.width * 10).rounded() / 10), num((2 * g.inner * 10).rounded() / 10)))
        r.methods.append(String(format: L10n.tr("头探：身体中心在开放段，鼻尖越出跑道内缘或外缘 %@–%@ cm，持续 ≥ %@ s（内缘、外缘分别计数）。闭合段探出：身体中心和尾根在闭合段，鼻尖越过边界进入开放段，持续 ≥ %@ s，0.5 s 内接着进入开放段的不计。伸展评估姿势：鼻尖–尾根长度 ≥ 中位数 × %@ 且身体中心速度 < %@ cm/s，持续 ≥ %@ s；朝向开放段指鼻尖比身体中心更靠近所在闭合段的边界。"),
                                num(beyond), num(far), num(p.headDipMin), num(p.pokeMin), num(p.sapElongation), num(p.sapSpeed), num(p.sapMin)))
        if p.windowLength <= 0 {
            r.warnings.append(L10n.tr("“分析时长”为 0（到视频结尾）：高架零迷宫常用 5 min（300 s）。"))
        }
        if dips.isEmpty && (c.quality().keypointRates.first ?? 1) < 0.7 {
            r.warnings.append(L10n.tr("鼻尖有效帧较少，头探可能漏检（头探时鼻尖常伸出画面或被遮挡）。"))
        }
        return r
    }
}
