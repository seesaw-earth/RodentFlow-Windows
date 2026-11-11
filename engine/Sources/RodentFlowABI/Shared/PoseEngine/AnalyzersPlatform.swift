// AnalyzersPlatform.swift — tasks built on a platform or an edge (RodentFlow 2.1): platform-mediated avoidance,
// step-down inhibitory avoidance and the visual cliff. Only what the tracking gives: zones, latencies, freezing and
// head dips over an edge. Tones, shocks and rewards are run and logged by their own devices; the frame-by-frame
// flags (`on_platform`, `freezing`, …) and the behaviour segments are in video time, so each trial can be cut from
// the exports with the device's own event times.

import Foundation

extension AnalysisContext {
    /// Percentage of each time bin where `mask` is true: line points and the series stored with the session for the
    /// group comparison's time course (English name). Series contract (RodentFlow 2.1 build 23): x = bin centre in
    /// minutes since the window start, the label names the bin width, bins with < 90 % of their width analysed are
    /// left out (before: x = bin start, label "Minute", bins with > 25 % kept).
    func percentSeries(_ mask: [Bool], key: String, name: String, bin: Double) -> (points: [LinePoint], series: FlowResultSeries?) {
        var pts: [LinePoint] = []
        for b in courseBins(bin) {
            let w = windowTime(from: b.start, to: b.end)
            guard w > 0 else { continue }
            pts.append(LinePoint(x: b.x, y: total(mask, from: b.start, to: b.end) / w * 100))
        }
        guard pts.count > 1 else { return (pts, nil) }
        let s = FlowResultSeries(key: key, name: name, unit: "%", xLabel: TimeCourseLabel.english(bin: max(bin, 1)), x: pts.map(\.x), y: pts.map(\.y))
        return (pts, s)
    }

    /// Distance per time bin (cm, or px without a calibration) as a stored series (same bins as `percentSeries`).
    func distanceSeries(bin: Double) -> FlowResultSeries? {
        var x: [Double] = [], y: [Double] = []
        for b in courseBins(bin) {
            var inBin = [Bool](repeating: false, count: n)
            for i in tb.index(atOrAfter: b.start)..<min(n, tb.index(atOrAfter: b.end)) { inBin[i] = true }
            x.append(b.x)
            y.append(distance(onlyWhere: inBin))
        }
        guard x.count > 1 else { return nil }
        return FlowResultSeries(key: "distance_bin", name: "Distance per bin", unit: fs.isMetric ? "cm" : "px", xLabel: TimeCourseLabel.english(bin: max(bin, 1)), x: x, y: y)
    }
}

enum PlatformAnalyzers {

    // MARK: Shared rule: the nose over an edge

    /// Head dips over an edge: the nose outside `inside` while the body center — and the tail base when it is
    /// seen — are inside, lasting at least `minDuration` (EZM, light–dark and passive-avoidance pokes use the same idea).
    static func edgeDips(_ c: AnalysisContext, inside: (V2) -> Bool, minDuration: Double) -> [Bout] {
        let a = c.a0
        var raw = [Bool](repeating: false, count: c.n)
        for i in 0..<c.n {
            guard let nose = a.pos(.nose, i), !inside(nose), let body = a.pos(.bodyCenter, i), inside(body) else { continue }
            if let tail = a.pos(.tailBase, i), !inside(tail) { continue }
            raw[i] = true
        }
        return Bouts.find(raw, c.tb, minDuration: minDuration, mergeGap: 0.15)
    }

    static func meanDuration(_ bouts: [Bout]) -> Double? {
        bouts.isEmpty ? nil : bouts.reduce(0) { $0 + $1.duration } / Double(bouts.count)
    }

    // MARK: Platform-mediated avoidance

    static func platformAvoidance(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let num = AnalysisContext.num
        guard let platform = c.zone("platform") else {
            r.warnings.append(L10n.tr("请在标定页把 P 手柄放到平台中心。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let rule = ["body", "front", "full"].contains(p.pmaRule) ? p.pmaRule : "body"
        let body = c.mask(.bodyCenter, in: platform)
        let on: [Bool]
        switch rule {
        case "front": on = AnalysisContext.and(c.mask(.nose, in: platform), c.mask(.neck, in: platform))
        case "full": on = AnalysisContext.and(body, c.mask(.tailBase, in: platform))
        default: on = body
        }
        let off = AnalysisContext.not(on)
        let freeze = c.freezingMask()
        let freezeOn = AnalysisContext.and(freeze, on)
        let freezeOff = AnalysisContext.and(freeze, off)
        let win = tb.windowDuration
        let tOn = tb.total(on)
        let bouts = Bouts.find(on, tb)
        let reward = p.pmaReward ? c.zone("reward").map { c.mask(.nose, in: $0) } : nil

        var metrics = [
            c.m("platform_pct", L10n.tr("平台时间（全程）"), c.percent(tOn, win), "%", 1, info: L10n.tr("整个分析时间段（不分声音试次）在平台上的时间比例；按试次请用逐帧数据切分")),
            c.m("platform_time", L10n.tr("平台时间"), tOn, "s", 1),
            c.m("platform_entries", L10n.tr("上平台次数"), Double(Bouts.entries(on, tb)), "", 0),
            c.m("platform_latency", L10n.tr("首次上平台潜伏期"), tb.firstTime(on), "s", 1),
            c.m("platform_bout_mean", L10n.tr("平均每次平台停留"), meanDuration(bouts), "s", 1),
            c.m("freeze_pct", L10n.tr("僵直"), c.percent(tb.total(freeze), win), "%", 1),
            c.m("freeze_on_platform_pct", L10n.tr("平台上僵直"), c.percent(tb.total(freezeOn), tOn), "%", 1, info: L10n.tr("占平台上时间的比例")),
            c.m("freeze_off_platform_pct", L10n.tr("平台外僵直"), c.percent(tb.total(freezeOff), win - tOn), "%", 1, info: L10n.tr("占平台外时间的比例"))
        ]
        if let reward {
            metrics.append(c.m("reward_time", L10n.tr("奖励口区时间"), tb.total(reward), "s", 1, info: L10n.tr("鼻尖在奖励口半径内")))
            metrics.append(c.m("reward_entries", L10n.tr("进入奖励口区次数"), Double(Bouts.entries(reward, tb)), "", 0))
        }
        r.metrics = metrics + c.locomotionMetrics()
        r.primaryKey = "platform_pct"

        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("绿框为平台")))
        r.blocks.append(c.heatBlock(L10n.tr("停留热图"), caption: L10n.tr("分析时间段内身体中心的停留时间")))
        r.blocks.append(ReportBlock(title: L10n.tr("平台上与平台外"), caption: nil, kind: .bars(BarData(items: [
            BarItem(label: L10n.tr("平台上"), value: tOn, color: .target),
            BarItem(label: L10n.tr("平台外"), value: max(0, win - tOn), color: .neutral),
            BarItem(label: L10n.tr("平台上僵直"), value: tb.total(freezeOn), color: .freezing),
            BarItem(label: L10n.tr("平台外僵直"), value: tb.total(freezeOff), color: .freezing)], unit: "s"))))
        let platformCurve = c.percentSeries(on, key: "platform_pct_bin", name: "Time on the platform", bin: p.timeBin)
        let freezeCurve = c.percentSeries(freeze, key: "freeze_pct_bin", name: "Freezing", bin: p.timeBin)
        if platformCurve.points.count > 1 {
            r.blocks.append(ReportBlock(title: L10n.tr("分段平台时间与僵直"), caption: nil, kind: .line(LineData(series: [
                LineSeries(name: L10n.tr("平台上"), color: .target, points: platformCurve.points),
                LineSeries(name: L10n.tr("僵直"), color: .freezing, points: freezeCurve.points)], xLabel: c.courseAxis(p.timeBin), yLabel: "%", yRange: 0...100))))
        }
        r.series = [platformCurve.series, freezeCurve.series, c.distanceSeries(bin: p.timeBin)].compactMap { $0 }
        var tracks = [TimelineTrack(name: L10n.tr("平台上"), color: .target, bouts: bouts),
                      TimelineTrack(name: L10n.tr("僵直"), color: .freezing, bouts: Bouts.find(freeze, tb))]
        if let reward { tracks.append(TimelineTrack(name: L10n.tr("奖励口区"), color: .novel, bouts: Bouts.find(reward, tb))) }
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [("on_platform", AnalysisContext.flag(on)), ("freezing", AnalysisContext.flag(freeze)),
                          ("freezing_on_platform", AnalysisContext.flag(freezeOn))]
        if let reward { r.frameColumns.append(("in_reward_zone", AnalysisContext.flag(reward))) }

        let ruleText: String
        switch rule {
        case "front": ruleText = L10n.tr("鼻尖和颈部都在平台上（近似两前爪）")
        case "full": ruleText = L10n.tr("身体中心和尾根都在平台上（近似四爪）")
        default: ruleText = L10n.tr("身体中心在平台上")
        }
        r.methods.append(String(format: L10n.tr("平台为 %@ × %@ cm 的矩形；%@ 时记为在平台上。僵直为运动指数 < %@ cm/s 持续 ≥ %@ s。声音、电击和奖励由各自设备记录；逐帧数据（on_platform、freezing 列）按视频时间给出，可与设备记录对齐。"),
                                num(p.pmaPlatformWidth), num(p.pmaPlatformHeight), ruleText, num(p.freezeSpeed), num(p.freezeMin)))
        if p.pmaReward {
            r.methods.append(String(format: L10n.tr("奖励口区为奖励口周围半径 %@ cm 的圆，按鼻尖判断。"), num(p.pmaRewardRadius)))
        }
        if let first = tb.firstTime(on), first < 0.5, win > 0 {
            r.warnings.append(L10n.tr("分析一开始动物就在平台上：请检查平台位置和大小，以及“分析起点”。"))
        }
        return r
    }

    // MARK: Step-down inhibitory avoidance

    static func stepDown(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let num = AnalysisContext.num
        guard let platform = c.zone("platform") else {
            r.warnings.append(L10n.tr("请在标定页把 P 手柄放到平台中心。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let full = p.sdRule != "body"
        let a = c.a0
        // Off the platform: the body center seen beyond its edge (with the four-paw rule also the tail base, when it
        // is seen). A frame without a body center keeps the previous state (as the zone masks do); before the first
        // detection the animal is neither on nor off, so a missed detection is never a step-down.
        var off = [Bool](repeating: false, count: c.n)
        var on = [Bool](repeating: false, count: c.n)
        var state = 0
        for i in 0..<c.n {
            if let b = a.pos(.bodyCenter, i) {
                let tailOn = full && (a.pos(.tailBase, i).map { platform.contains($0) } ?? false)
                state = platform.contains(b) || tailOn ? 1 : -1
            }
            on[i] = state == 1
            off[i] = state == -1
        }
        let firstOff = tb.firstTime(off)
        let cutoff = tb.windowDuration
        let latency = firstOff ?? cutoff
        let offTime = firstOff.map { $0 + tb.windowStartTime } ?? .infinity
        let freeze = c.freezingMask()
        let freezeOn = AnalysisContext.and(freeze, on)
        let tOn = tb.total(on)
        let dips = edgeDips(c, inside: { platform.contains($0) }, minDuration: p.sdDipMin)
        let dipsBefore = dips.filter { $0.start < offTime }
        let dipMask = Bouts.mask(dips, count: c.n)

        var metrics = [
            c.m("step_down_latency", L10n.tr("下台潜伏期"), latency, "s", 1, info: L10n.tr("截止时间内没有下台时记为截止时间（右删失）"))
                .censoring(L10n.tr("未下台"), if: firstOff == nil),
            c.m("stepped_down", L10n.tr("下台"), firstOff != nil ? 100 : 0, "%", 0, info: L10n.tr("100 = 截止前下台；组平均即下台的比例")),
            c.m("platform_pct", L10n.tr("平台上时间"), c.percent(tOn, cutoff), "%", 1),
            c.m("step_downs", L10n.tr("下台次数"), Double(Bouts.entries(off, tb)), "", 0),
            c.m("freeze_on_platform_pct", L10n.tr("平台上僵直"), c.percent(tb.total(freezeOn), tOn), "%", 1, info: L10n.tr("占平台上时间的比例")),
            c.m("edge_dips", L10n.tr("边缘探头次数"), Double(dips.count), "", 0, info: L10n.tr("身体中心和尾根在平台上、鼻尖伸出边缘")),
            c.m("edge_dips_before", L10n.tr("下台前探头次数"), Double(dipsBefore.count), "", 0),
            c.m("first_edge_dip_latency", L10n.tr("首次边缘探头潜伏期"), dips.first.map { $0.start - tb.windowStartTime }, "s", 1)
        ]
        r.primaryKey = "step_down_latency"
        if c.session.phase == "Test" {
            if let train = c.companion["step_down_latency"], train > 0 {
                metrics.insert(c.m("latency_ratio", L10n.tr("测试 / 训练潜伏期"), latency / train, "×", 2,
                                   info: L10n.tr("同一编号动物的训练阶段下台潜伏期")), at: 1)
            } else {
                r.warnings.append(L10n.tr("没有找到同一编号的训练阶段：测试 / 训练潜伏期之比需要先分析训练（动物编号相同）。"))
            }
        }
        r.metrics = metrics + c.locomotionMetrics()

        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("红点 = 边缘探头时的鼻尖位置"), dots: c.dots(.nose, where: dipMask, color: .headDip, radius: 1.8)))
        let tracks = [TimelineTrack(name: L10n.tr("平台上"), color: .target, bouts: Bouts.find(on, tb)),
                      TimelineTrack(name: L10n.tr("边缘探头"), color: .headDip, bouts: dips),
                      TimelineTrack(name: L10n.tr("僵直"), color: .freezing, bouts: Bouts.find(freeze, tb))]
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [("on_platform", AnalysisContext.flag(on)), ("edge_dip", AnalysisContext.flag(dipMask)), ("freezing", AnalysisContext.flag(freeze))]

        if firstOff == nil {
            r.warnings.append(String(format: L10n.tr("截止时间（%@ s）内没有下台：潜伏期记为截止时间。比较组间潜伏期时请看组间页的生存分析。"),
                                     num((cutoff * 10).rounded() / 10)))
        }
        if let first = firstOff, first < 0.5 {
            r.warnings.append(L10n.tr("分析一开始动物就不在平台上：请检查平台位置和大小，以及“分析起点”是否设为放上平台的时刻。"))
        }
        if p.windowLength <= 0 {
            r.warnings.append(L10n.tr("“分析时长”为 0（到视频结尾）：step-down 应设为截止时间（常用 180 或 300 s）。"))
        }
        r.methods.append(String(format: L10n.tr("平台为 %@ × %@ cm 的矩形；%@离开平台记为下台。截止时间为分析时长 %@ s，截止前没有下台时潜伏期记为截止时间并标为未下台（右删失）。边缘探头为身体中心和尾根仍在平台上、鼻尖伸出平台边缘，持续 ≥ %@ s。"),
                                num(p.sdPlatformWidth), num(p.sdPlatformHeight), full ? L10n.tr("身体中心和尾根都") : L10n.tr("身体中心"),
                                num((cutoff * 10).rounded() / 10), num(p.sdDipMin)))
        return r
    }

    // MARK: Visual cliff

    static func visualCliff(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        guard let shallow = c.zone("shallow"), let center = c.zone("center"), let deep = c.zone("deep") else {
            r.warnings.append(L10n.tr("需要矩形场地标定。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        func side(_ q: V2?) -> Int? {
            guard let q else { return nil }
            if deep.contains(q) { return 1 }
            if shallow.contains(q) { return -1 }
            if center.contains(q) { return 0 }
            return nil
        }
        // A side changes only when the body center (with the "full" rule also the tail base) is in it.
        let full = p.vcRule != "body"
        var sides = [Int?](repeating: nil, count: c.n)
        var current: Int?
        for i in 0..<c.n {
            let b = side(a.pos(.bodyCenter, i))
            if full {
                // The tail base must be on the same side when it is seen (not seen: the body center decides).
                let tail = a.pos(.tailBase, i)
                if let b, tail == nil || side(tail) == b { current = b } else if b == 0 { current = 0 }
            } else if let b {
                current = b
            }
            sides[i] = current
        }
        let inDeep = sides.map { $0 == 1 }
        let inShallow = sides.map { $0 == -1 }
        let inCenter = sides.map { $0 == 0 }
        let win = tb.windowDuration
        let tD = tb.total(inDeep), tS = tb.total(inShallow), tC = tb.total(inCenter)

        // First choice: the first side entered from the center board.
        let window = (0..<c.n).filter { tb.inWindow[$0] }
        let startsInCenter = window.first.map { sides[$0] == 0 } ?? false
        var firstChoice: Int?
        var leaveLatency: Double?
        for i in window {
            guard let s = sides[i], s != 0 else { continue }
            firstChoice = s
            leaveLatency = tb.t[i] - tb.windowStartTime
            break
        }
        let deepFirst = tb.firstTime(inDeep)
        let cutoff = win
        // Early window (the first minutes, reported separately as in the phenotyping protocol).
        let earlyEnd = tb.windowStartTime + max(1, p.vcEarly)
        let early = (0..<c.n).map { tb.t[$0] < earlyEnd }
        let earlyWin = c.windowTime(from: tb.windowStartTime, to: earlyEnd)
        let dips = edgeDips(c, inside: { !deep.contains($0) }, minDuration: p.vcDipMin)
        let dipMask = Bouts.mask(dips, count: c.n)
        var crossings = 0
        var last: Int?
        for i in window {
            guard let s = sides[i], s != 0 else { continue }
            if let l = last, l != s { crossings += 1 }
            last = s
        }

        let sideMetrics: [MetricValue] = [
            c.m("deep_pct", L10n.tr("深侧时间"), c.percent(tD, win), "%", 1, info: L10n.tr("身体中心在深侧的时间占分析时间段的比例")),
            c.m("shallow_pct", L10n.tr("浅侧时间"), c.percent(tS, win), "%", 1),
            c.m("center_pct", L10n.tr("中性区时间"), c.percent(tC, win), "%", 1),
            c.m("first_choice_deep", L10n.tr("首次选择深侧"), firstChoice.map { $0 == 1 ? 100 : 0 }, "%", 0,
                info: L10n.tr("100 = 离开中性区后先进入深侧；组平均即先选深侧的比例"))
                .showing(firstChoice.map { $0 == 1 ? L10n.tr("深侧") : L10n.tr("浅侧") }),
            c.m("leave_center_latency", L10n.tr("离开中性区潜伏期"), leaveLatency, "s", 1),
            c.m("deep_latency", L10n.tr("首次进入深侧潜伏期"), deepFirst ?? cutoff, "s", 1, info: L10n.tr("截止时间内没有进入时记为截止时间（右删失）"))
                .censoring(L10n.tr("未进入深侧"), if: deepFirst == nil),
            c.m("entered_deep", L10n.tr("进入深侧"), deepFirst != nil ? 100 : 0, "%", 0),
            c.m("deep_entries", L10n.tr("进入深侧次数"), Double(Bouts.entries(inDeep, tb)), "", 0),
            c.m("crossings", L10n.tr("深浅侧之间穿越"), Double(crossings), "", 0)
        ]
        let dipMetrics: [MetricValue] = [
            c.m("edge_dips", L10n.tr("边缘探头次数"), Double(dips.count), "", 0, info: L10n.tr("鼻尖伸进深侧、身体中心和尾根仍在中性区或浅侧")),
            c.m("edge_dip_time", L10n.tr("边缘探头时间"), dips.reduce(0) { $0 + $1.duration }, "s", 1),
            c.m("first_edge_dip_latency", L10n.tr("首次边缘探头潜伏期"), dips.first.map { $0.start - tb.windowStartTime }, "s", 1)
        ]
        let metric = c.fs.isMetric
        let earlyMetrics: [MetricValue] = [
            c.m("deep_pct_early", String(format: L10n.tr("前 %@ s 深侧时间"), num(p.vcEarly)), c.percent(c.total(inDeep, from: tb.windowStartTime, to: earlyEnd), earlyWin), "%", 1),
            c.m("shallow_pct_early", String(format: L10n.tr("前 %@ s 浅侧时间"), num(p.vcEarly)), c.percent(c.total(inShallow, from: tb.windowStartTime, to: earlyEnd), earlyWin), "%", 1),
            c.m("distance_early", String(format: L10n.tr("前 %@ s 路程"), num(p.vcEarly)), c.fs.isMetric ? c.distance(onlyWhere: early) / 100 : c.distance(onlyWhere: early), c.fs.isMetric ? "m" : "px", c.fs.isMetric ? 2 : 0),
            c.m("deep_distance", L10n.tr("深侧路程"), c.fs.isMetric ? c.distance(onlyWhere: inDeep) / 100 : c.distance(onlyWhere: inDeep), c.fs.isMetric ? "m" : "px", c.fs.isMetric ? 2 : 0),
            c.m("shallow_distance", L10n.tr("浅侧路程"), metric ? c.distance(onlyWhere: inShallow) / 100 : c.distance(onlyWhere: inShallow), metric ? "m" : "px", metric ? 2 : 0)
        ]
        r.metrics = sideMetrics + dipMetrics + earlyMetrics + c.locomotionMetrics()
        r.primaryKey = "deep_pct"
        // The field's main readout is the first choice: on the key result card next to the time on the deep side.
        switch firstChoice {
        case .some(1): r.keyNote = L10n.tr("首次选择：深侧")
        case .some(-1): r.keyNote = L10n.tr("首次选择：浅侧")
        default:
            // "Did not leave" only when the body was seen in the neutral zone; no frame with a known side → unknown.
            r.keyNote = tC > 0 ? L10n.tr("首次选择：没有离开中性区") : L10n.tr("首次选择：未知（没有能判定位置的帧）")
        }

        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("红点 = 边缘探头时的鼻尖位置"), dots: c.dots(.nose, where: dipMask, color: .headDip, radius: 1.8)))
        r.blocks.append(c.heatBlock(L10n.tr("停留热图"), caption: L10n.tr("分析时间段内身体中心的停留时间")))
        r.blocks.append(ReportBlock(title: L10n.tr("各区时间"), caption: nil, kind: .bars(BarData(items: [
            BarItem(label: L10n.tr("浅侧"), value: tS, color: .light),
            BarItem(label: L10n.tr("中性区"), value: tC, color: .neutral),
            BarItem(label: L10n.tr("深侧"), value: tD, color: .dark)], unit: "s"))))
        let curve = c.percentSeries(inDeep, key: "deep_pct_bin", name: "Time on the deep side", bin: p.timeBin)
        if curve.points.count > 1 {
            r.blocks.append(ReportBlock(title: L10n.tr("分段深侧时间"), caption: nil, kind: .line(LineData(series: [
                LineSeries(name: L10n.tr("深侧"), color: .dark, points: curve.points)], xLabel: c.courseAxis(p.timeBin), yLabel: "%", yRange: 0...100))))
        }
        r.series = [curve.series, c.distanceSeries(bin: p.timeBin)].compactMap { $0 }
        let tracks = [TimelineTrack(name: L10n.tr("浅侧"), color: .light, bouts: Bouts.find(inShallow, tb)),
                      TimelineTrack(name: L10n.tr("深侧"), color: .dark, bouts: Bouts.find(inDeep, tb)),
                      TimelineTrack(name: L10n.tr("边缘探头"), color: .headDip, bouts: dips)]
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.frameColumns = [("cliff_side", sides.map { s -> Double in s.map { Double($0) } ?? .nan }), ("edge_dip", AnalysisContext.flag(dipMask))]

        if !startsInCenter {
            r.warnings.append(L10n.tr("分析开始时动物不在中性区：首次选择可能不对。请检查“分析起点”是否设为把小鼠放到中间板上的时刻。"))
        }
        if win > 0, tD + tS + tC < win * 0.8 {
            r.warnings.append(String(format: L10n.tr("只有 %@%% 的时间能确定所在侧：请检查标定和分界位置。"), num(((tD + tS + tC) / win * 100).rounded())))
        }
        let deepName = p.vcDeepSide == "L" ? L10n.tr("左侧") : L10n.tr("右侧")
        r.methods.append(String(format: L10n.tr("深侧为画面%@；中性区宽度为场地长度的 %@%%。所在侧按%@判断，只有进入另一侧后才计为换边。首次选择为离开中性区后先进入的一侧。边缘探头为鼻尖伸进深侧而身体中心和尾根仍在中性区或浅侧，持续 ≥ %@ s。前 %@ s 另行统计。"),
                                deepName, num((p.vcCenterFraction * 100).rounded()), full ? L10n.tr("身体中心和尾根都在同一侧") : L10n.tr("身体中心"),
                                num(p.vcDipMin), num(p.vcEarly)))
        return r
    }
}
