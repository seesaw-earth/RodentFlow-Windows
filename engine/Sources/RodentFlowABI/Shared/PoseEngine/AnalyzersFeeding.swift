// AnalyzersFeeding.swift — novelty-suppressed feeding from pose, semi-automatic (RodentFlow 2.0: iOS build 15,
// Mac build 14).
//
// Standard video tracking cannot tell sniffing the pellet from eating it (Samuels & Hen 2011), so the first bite is
// confirmed by a person in the review ("Set as first bite" / "No feeding before the cut-off", stored in the
// analysis parameters so it reaches the Mac with the session). Pose gives what it can measure reliably: the
// approach to the food (nose in the food zone), time there, center / periphery and distance, and *candidate*
// feeding bouts (nose in the food zone with the body almost still for a few seconds) to jump to in the review.
// The latency enters group statistics only once confirmed; no bite before the cut-off is right-censored at the
// cut-off (Kaplan–Meier + log-rank on the group page). Home-cage consumption and weight loss are the hunger
// control (and can be ANCOVA covariates).

import Foundation

enum FeedingAnalyzer {
    static func analyze(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        let p = c.p
        let tb = c.tb
        let a = c.a0
        let num = AnalysisContext.num
        let start = tb.windowStartTime
        let cutoff = tb.windowDuration
        guard let food = c.zone("food") else {
            r.warnings.append(L10n.tr("需要标定场地，并把 F 手柄放在食物上。"))
            r.metrics = c.locomotionMetrics()
            return r
        }
        let noseFood = c.mask(.nose, in: food)
        let visits = Bouts.find(noseFood, tb, mergeGap: 0.2)
        var candidateRaw = [Bool](repeating: false, count: c.n)
        for i in 0..<c.n where noseFood[i] && a.speed[i].isFinite && a.speed[i] < p.nsfStillSpeed {
            candidateRaw[i] = true
        }
        let candidates = Bouts.find(candidateRaw, tb, minDuration: p.nsfStillMin, mergeGap: 0.5)
        let candidateMask = Bouts.mask(candidates, count: c.n)

        // The confirmed first bite.
        var latency: Double?
        var ate: Double?
        var biteTime: Double?
        if p.nsfFeedingTime >= 0 {
            let rel = p.nsfFeedingTime - start
            if cutoff > 0 && rel > cutoff {
                latency = cutoff
                ate = 0
                r.warnings.append(L10n.tr("确认的首次进食在截止时间之后：按截止前未进食计（潜伏期 = 截止时间，右删失）。"))
            } else {
                if rel < 0 {
                    r.warnings.append(L10n.tr("确认的首次进食早于“分析起点”：潜伏期记为 0。请检查分析起点是否为放入场地的时刻。"))
                }
                latency = max(0, rel)
                ate = 100
                biteTime = p.nsfFeedingTime
            }
        } else if p.nsfNoFeeding {
            latency = cutoff
            ate = 0
        }
        let confirmed = latency != nil

        var beforeBite = [Bool](repeating: false, count: c.n)
        if let t = biteTime { for i in 0..<c.n where tb.t[i] < t { beforeBite[i] = true } }

        var metrics: [MetricValue] = [
            c.m("feeding_latency", L10n.tr("进食潜伏期"), latency, "s", 1,
                info: confirmed ? L10n.tr("人工确认的首次咬食；截止前未进食记为截止时间（右删失）") : L10n.tr("未确认：在回看中确认第一口后才有数值"))
                .censoring(L10n.tr("未进食"), if: ate == 0),
            c.m("ate_pct", L10n.tr("截止前进食"), ate, "%", 0, info: L10n.tr("100 = 截止前进食；组平均即进食的比例")),
            c.m("feeding_confirmed", L10n.tr("首次进食已确认"), confirmed ? 1 : 0, "", 0, info: L10n.tr("1 = 已在回看中确认")),
            c.m("candidate_latency", L10n.tr("首个候选进食"), candidates.first.map { $0.start - start }, "s", 1,
                info: L10n.tr("自动判定，只用于提示")),
            c.m("candidate_bouts", L10n.tr("候选进食次数"), Double(candidates.count), "", 0),
            c.m("approach_latency", L10n.tr("首次接近食物"), tb.firstTime(noseFood), "s", 1, info: L10n.tr("鼻尖首次进入食物区")),
            c.m("approaches", L10n.tr("接近食物次数"), Double(visits.count), "", 0, info: L10n.tr("鼻尖进入食物区的次数（间隔 ≤ 0.2 s 的合并）")),
            c.m("food_zone_time", L10n.tr("食物区时间"), tb.total(noseFood), "s", 1)
        ]
        if let t = biteTime {
            metrics.append(c.m("approaches_before_feeding", L10n.tr("进食前接近次数"), Double(visits.filter { $0.start < t }.count), "", 0))
            let d = c.distance(onlyWhere: beforeBite)
            metrics.append(c.fs.isMetric ? c.m("path_to_feeding", L10n.tr("进食前路程"), d / 100, "m", 2)
                                         : c.m("path_to_feeding", L10n.tr("进食前路程"), d, "px", 0))
        }
        if let center = c.zone("center") {
            metrics.append(c.m("center_pct", L10n.tr("中央区时间"), c.percent(tb.total(c.mask(.bodyCenter, in: center)), cutoff), "%", 1))
        }
        metrics += c.locomotionMetrics()
        if p.nsfHomeCageFood >= 0 {
            metrics.append(c.m("homecage_food", L10n.tr("家笼 5 min 摄食量"), p.nsfHomeCageFood, "g", 2, info: L10n.tr("测试后立即放回家笼，5 min 内的摄食量")))
        }
        if p.nsfWeightBefore > 0 && p.nsfWeightTest > 0 {
            metrics.append(c.m("weight_loss_pct", L10n.tr("禁食后体重下降"), (p.nsfWeightBefore - p.nsfWeightTest) / p.nsfWeightBefore * 100, "%", 1,
                               info: L10n.tr("（禁食前 − 测试前）÷ 禁食前")))
        }
        r.metrics = metrics
        r.primaryKey = "feeding_latency"

        var dots = c.dots(.nose, where: candidateMask, color: .warning, radius: 1.6)
        if let t = biteTime, let i = (0..<c.n).first(where: { tb.t[$0] >= t }), let q = a.pos(.nose, i) {
            dots.append(PlotDot(p: q, color: .target, radius: 3.2))
        }
        r.blocks.append(c.trajectoryBlock(caption: biteTime == nil ? L10n.tr("黄点 = 候选进食时的鼻尖位置")
                                                                    : L10n.tr("黄点 = 候选进食时的鼻尖位置；绿点 = 确认的第一口"), dots: dots))
        r.blocks.append(c.heatBlock())
        if let d = c.distanceBinsBlock() { r.blocks.append(d) }
        var tracks = [
            TimelineTrack(name: L10n.tr("鼻尖在食物区"), color: .sniff, bouts: visits),
            TimelineTrack(name: L10n.tr("候选进食"), color: .warning, bouts: candidates, style: .flag)
        ]
        if let t = biteTime {
            tracks.append(TimelineTrack(name: L10n.tr("首次进食（确认）"), color: .target, bouts: [Bout(start: t, end: t + 1, i0: 0, i1: 0)]))
        }
        r.blocks.append(ReportBlock(title: L10n.tr("时间轴"), caption: nil, kind: .timeline(c.timeline(tracks))))
        r.reviewTracks = tracks
        r.feedingCandidates = candidates
        r.frameColumns = [("nose_in_food_zone", AnalysisContext.flag(noseFood)), ("candidate_feeding", AnalysisContext.flag(candidateMask)),
                          ("before_first_bite", AnalysisContext.flag(beforeBite))]

        if !confirmed {
            r.warnings.append(candidates.isEmpty
                ? L10n.tr("首次进食尚未确认（没有找到候选进食）：请在回看中按“设为首次进食”或“确认截止前未进食”。确认前不进入组间统计。")
                : L10n.tr("首次进食尚未确认：请在回看中查看时间轴上的“候选进食”，按“设为首次进食”或“确认截止前未进食”。确认前不进入组间统计。"))
        } else if ate == 0 {
            r.warnings.append(String(format: L10n.tr("截止时间（%@ s）内没有进食：潜伏期记为截止时间。比较组间潜伏期时请看组间页的生存分析。"),
                                     num((cutoff * 10).rounded() / 10)))
        }
        if p.windowLength <= 0 {
            r.warnings.append(L10n.tr("“分析时长”为 0（到视频结尾）：NSF 应设为截止时间（常用 600 s）。"))
        }
        r.methods.append(String(format: L10n.tr("食物区为以 F 为中心、半径 %@ cm 的圆，接近为鼻尖进入食物区。候选进食为鼻尖在食物区、身体中心速度 < %@ cm/s 且持续 ≥ %@ s，只用于提示；进食潜伏期以回看中人工确认的第一口为准。截止时间为分析时长 %@ s，截止前未进食记为截止时间并标为未进食（右删失）。"),
                                num(p.nsfFoodRadius), num(p.nsfStillSpeed), num(p.nsfStillMin), num((cutoff * 10).rounded() / 10)))
        r.methods.append(confirmed ? L10n.tr("首次进食已由人工在回看中确认。") : L10n.tr("首次进食尚未人工确认。"))
        return r
    }
}
