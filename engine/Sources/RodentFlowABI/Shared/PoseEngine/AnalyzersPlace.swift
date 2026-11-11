// AnalyzersPlace.swift — passive avoidance (step-through) and place preference (real-time RTPP and
// conditioned CPP) from pose (RodentFlow 2.0: iOS build 14, Mac build 13).

import Foundation

enum PlaceAnalyzers {

    // MARK: Passive avoidance (step-through)

    static func passiveAvoidance(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        guard let light = c.zone("light"), let dark = c.zone("dark") else {
            r.warnings.append(L10n.tr("需要矩形场地标定。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let bodyDark = c.mask(.bodyCenter, in: dark)
        let tailDark = c.mask(.tailBase, in: dark)
        let noseDark = c.mask(.nose, in: dark)
        let rule = ["body", "full", "nose"].contains(p.entryRule) ? p.entryRule : "full"
        let inDark: [Bool]
        switch rule {
        case "body": inDark = bodyDark
        case "nose": inDark = noseDark
        default: inDark = AnalysisContext.and(bodyDark, tailDark)
        }
        let firstEntry = tb.firstTime(inDark)
        let entered = firstEntry != nil
        let cutoff = tb.windowDuration
        let latency = firstEntry ?? cutoff
        let entryTime = firstEntry.map { $0 + tb.windowStartTime } ?? .infinity

        // Risk assessment: the nose in the dark compartment while the body center and tail base stay in the light.
        var pokeRaw = [Bool](repeating: false, count: c.n)
        for i in 0..<c.n {
            guard let nose = a.pos(.nose, i), dark.contains(nose), let body = a.pos(.bodyCenter, i), light.contains(body) else { continue }
            if let tail = a.pos(.tailBase, i), dark.contains(tail) { continue }
            pokeRaw[i] = true
        }
        let pokes = Bouts.find(pokeRaw, tb, minDuration: p.pokeMin, mergeGap: 0.15)
        let pokesBefore = pokes.filter { $0.start < entryTime }
        let pokeMask = Bouts.mask(pokes, count: c.n)

        r.metrics = [
            c.m("entry_latency", L10n.tr("进入暗室潜伏期"), latency, "s", 1,
                info: L10n.tr("截止时间内没有进入时记为截止时间（右删失）"))
                .censoring(L10n.tr("未进入"), if: !entered),
            c.m("entered_pct", L10n.tr("进入暗室"), entered ? 100 : 0, "%", 0, info: L10n.tr("100 = 截止前进入；组平均即进入的比例")),
            c.m("dark_pct", L10n.tr("暗室时间"), c.percent(tb.total(inDark), tb.windowDuration), "%", 1),
            c.m("dark_entries", L10n.tr("进入暗室次数"), Double(Bouts.entries(inDark, tb)), "", 0),
            c.m("risk_pokes", L10n.tr("反向探头次数"), Double(pokes.count), "", 0, info: L10n.tr("鼻尖伸进暗室、身体中心和尾根仍在明室")),
            c.m("risk_pokes_before_entry", L10n.tr("进入前探头次数"), Double(pokesBefore.count), "", 0),
            c.m("first_poke_latency", L10n.tr("首次探头潜伏期"), pokes.first.map { $0.start - tb.windowStartTime }, "s", 1),
            c.m("poke_time", L10n.tr("探头时间"), pokes.reduce(0) { $0 + $1.duration }, "s", 1)
        ] + c.locomotionMetrics()
        r.primaryKey = "entry_latency"

        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("红点 = 反向探头时的鼻尖位置"), dots: c.dots(.nose, where: pokeMask, color: .headDip, radius: 1.8)))
        r.blocks.append(ReportBlock(title: L10n.tr("明暗室时间"), caption: nil, kind: .bars(BarData(items: [
            BarItem(label: L10n.tr("明室"), value: tb.total(AnalysisContext.not(inDark)), color: .light),
            BarItem(label: L10n.tr("暗室"), value: tb.total(inDark), color: .dark)], unit: "s"))))
        let tracks = [TimelineTrack(name: L10n.tr("在暗室"), color: .dark, bouts: Bouts.find(inDark, tb)),
                      TimelineTrack(name: L10n.tr("反向探头"), color: .headDip, bouts: pokes)]
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [("in_dark", AnalysisContext.flag(inDark)), ("risk_poke", AnalysisContext.flag(pokeMask))]

        if !entered {
            r.warnings.append(String(format: L10n.tr("截止时间（%@ s）内没有进入暗室：潜伏期记为截止时间。比较组间潜伏期时请看组间页的生存分析。"),
                                     num((cutoff * 10).rounded() / 10)))
        }
        if p.windowLength <= 0 {
            r.warnings.append(L10n.tr("“分析时长”为 0（到视频结尾）：被动回避应设为截止时间（常用 300 s）。"))
        }
        if let first = firstEntry, first < 1 {
            r.warnings.append(L10n.tr("分析一开始动物就在暗室：请检查“分析起点”是否设为放入明室（或开门）的时刻。"))
        }
        let ruleText: String
        switch rule {
        case "body": ruleText = L10n.tr("身体中心的位置")
        case "nose": ruleText = L10n.tr("鼻尖的位置")
        default: ruleText = L10n.tr("身体中心和尾根的位置（两者都在暗室内，近似四爪进入）")
        }
        r.methods.append(String(format: L10n.tr("进入暗室按%@判断；截止时间为分析时长 %@ s，截止前没有进入时潜伏期记为截止时间并标为未进入（右删失）。反向探头为鼻尖伸进暗室而身体中心和尾根仍在明室，持续 ≥ %@ s。"),
                                ruleText, num((cutoff * 10).rounded() / 10), num(p.pokeMin)))
        return r
    }

    // MARK: Place preference (RTPP / CPP)

    static func placePreference(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        guard let paired = c.zone("paired"), let unpaired = c.zone("unpaired") else {
            r.warnings.append(L10n.tr("需要矩形场地标定。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let middle = c.zone("middle")
        func side(_ q: V2?) -> Int? {
            guard let q else { return nil }
            if paired.contains(q) { return 1 }
            if unpaired.contains(q) { return -1 }
            if let middle, middle.contains(q) { return 0 }
            return nil
        }
        // A side changes only when the body center (and, with the "full" rule, also the tail base) is in it:
        // an animal sitting in the doorway does not flicker between sides.
        let full = p.ppRule == "full"
        var sides = [Int?](repeating: nil, count: c.n)
        var current: Int?
        for i in 0..<c.n {
            let b = side(a.pos(.bodyCenter, i))
            if full {
                if let b, let t = side(a.pos(.tailBase, i)), b == t { current = b } else if b == 0 { current = 0 }
            } else if let b {
                current = b
            }
            sides[i] = current
        }
        let inPaired = sides.map { $0 == 1 }
        let inUnpaired = sides.map { $0 == -1 }
        let inMiddle = sides.map { $0 == 0 }
        let tP = tb.total(inPaired), tU = tb.total(inUnpaired), tM = tb.total(inMiddle)
        let win = tb.windowDuration
        var crossings = 0
        var lastSide: Int?
        for i in 0..<c.n where tb.inWindow[i] {
            guard let s = sides[i], s != 0 else { continue }
            if let l = lastSide, l != s { crossings += 1 }
            lastSide = s
        }
        let pairedPct = c.percent(tP, win)
        // 50 % is "no preference" only when the two sides are the whole apparatus (no middle zone).
        let pairedMetric = c.m("paired_pct", L10n.tr("配对侧时间"), pairedPct, "%", 1, info: L10n.tr("身体中心在配对 / 刺激侧的时间占分析时间段的比例"))
        var metrics = [
            middle == nil ? pairedMetric.withReference(50, L10n.tr("50% = 无偏好")) : pairedMetric,
            c.m("paired_time", L10n.tr("配对侧时间"), tP, "s", 1),
            c.m("unpaired_time", L10n.tr("非配对侧时间"), tU, "s", 1),
            c.m("middle_time", L10n.tr("中间区时间"), middle == nil ? nil : tM, "s", 1),
            c.m("preference_score", L10n.tr("偏好分数"), tP - tU, "s", 1, info: L10n.tr("配对侧 − 非配对侧（s）")),
            c.m("preference_index", L10n.tr("偏好指数"), c.index(tP, tU), "", 2, info: L10n.tr("(配对 − 非配对) ÷ (配对 + 非配对)"))
                .withReference(0, L10n.tr("0 = 无偏好")),
            c.m("crossings", L10n.tr("两侧穿越次数"), Double(crossings), "", 0),
            c.m("paired_entries", L10n.tr("进入配对侧次数"), Double(Bouts.entries(inPaired, tb)), "", 0),
            c.m("paired_latency", L10n.tr("首次进入配对侧"), tb.firstTime(inPaired), "s", 1)
        ]
        r.primaryKey = "paired_pct"
        if c.session.phase == "Post-test" {
            if let pre = c.companion["paired_time"] {
                metrics.insert(c.m("cpp_score", L10n.tr("CPP 分数"), tP - pre, "s", 1, info: L10n.tr("后测配对侧时间 − 前测配对侧时间（同一编号）")), at: 0)
                if let prePct = c.companion["paired_pct"], let pairedPct {
                    metrics.insert(c.m("cpp_pct_change", L10n.tr("配对侧时间变化"), pairedPct - prePct, "%", 1, info: L10n.tr("后测 − 前测（百分点）")), at: 1)
                }
                r.primaryKey = "cpp_score"
            } else {
                r.warnings.append(L10n.tr("没有找到同一编号的前测：CPP 分数需要先分析前测（动物编号相同）。"))
            }
        }
        r.metrics = metrics + c.locomotionMetrics()

        r.blocks.append(c.trajectoryBlock())
        r.blocks.append(c.heatBlock(L10n.tr("停留热图"), caption: L10n.tr("分析时间段内身体中心的停留时间")))
        var items = [BarItem(label: L10n.tr("配对侧"), value: tP, color: .target)]
        if middle != nil { items.append(BarItem(label: L10n.tr("中间区"), value: tM, color: .neutral)) }
        items.append(BarItem(label: L10n.tr("非配对侧"), value: tU, color: .series1))
        r.blocks.append(ReportBlock(title: L10n.tr("各区时间"), caption: nil, kind: .bars(BarData(items: items, unit: "s"))))
        let pts = c.percentSeries(inPaired, key: "paired_pct_bin", name: "Time on the paired side", bin: p.timeBin).points
        if pts.count > 1 {
            r.blocks.append(ReportBlock(title: L10n.tr("分段配对侧时间"), caption: middle == nil ? L10n.tr("虚线为 50%") : nil,
                                        kind: .line(LineData(series: [LineSeries(name: L10n.tr("配对侧"), color: .target, points: pts)],
                                                             xLabel: c.courseAxis(p.timeBin), yLabel: "%", yRange: 0...100,
                                                             referenceY: middle == nil ? 50 : nil, referenceYLabel: L10n.tr("50% = 无偏好")))))
        }
        var tracks = [TimelineTrack(name: L10n.tr("配对侧"), color: .target, bouts: Bouts.find(inPaired, tb)),
                      TimelineTrack(name: L10n.tr("非配对侧"), color: .series1, bouts: Bouts.find(inUnpaired, tb))]
        if middle != nil { tracks.append(TimelineTrack(name: L10n.tr("中间区"), color: .neutral, bouts: Bouts.find(inMiddle, tb))) }
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [("pp_side", sides.map { s -> Double in s.map { Double($0) } ?? .nan })]

        let sideName = p.ppPairedSide == "R" ? L10n.tr("右侧") : L10n.tr("左侧")
        r.methods.append(String(format: L10n.tr("配对 / 刺激侧为画面%@。所在侧按%@判断，只有进入另一侧后才计为换边（卡在门口不计穿越）。"),
                                sideName, full ? L10n.tr("身体中心和尾根都在同一侧") : L10n.tr("身体中心")))
        if c.session.phase == "Post-test" {
            r.methods.append(L10n.tr("CPP 分数 = 后测配对侧时间 − 同一编号动物前测配对侧时间。"))
        }
        if win > 0, tP + tU + tM < win * 0.8 {
            r.warnings.append(String(format: L10n.tr("只有 %@%% 的时间能确定所在侧：请检查标定和分界位置。"), num(((tP + tU + tM) / win * 100).rounded())))
        }
        return r
    }
}
