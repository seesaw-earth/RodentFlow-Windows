// AnalyzersAggression.swift — resident–intruder test: aggression from keypoint kinematics.
//
// Everything is measured in body lengths (BL), so no arena calibration is needed: each mouse's
// body length is its neck → tail base distance (median while walking alone), distances are
// divided by the mean body length of the pair and speeds are BL/s. Speeds of the pair are also
// expressed relative to each other: the relative speed |v_R − v_I| and each animal's approach
// speed (its velocity projected on the line to the other animal; > 0 = closing in).
//
// Rules (thresholds in AnalysisParams.ri*):
//   attack       scuffle: close (centroid distance < riCloseDist, or one detection for both) AND
//                the pair moves fast and incoherently (relative speed > riFightSpeed or body-axis
//                rotation > riFightTurn) — sustained ≥ riFightMin; tracking turbulence (merged
//                detection, ≥ 2 keypoints lost) counts as evidence when the pair is moving. Who
//                started it is not judged.
//   clinch       part of an attack where both keep moving but the pair barely translates (rolling
//                in place), sustained ≥ riClinchMin.
//   chase        both fast (resident > riChaseSpeed), resident moving toward the intruder, the
//                intruder moving away along the same direction.
//   keep down    close, resident clearly visible on top while the intruder's keypoints are hidden
//                (occluded) and the intruder barely moves, ≥ riKeepDownMin, within 5 s of an
//                attack or chase.
//   mounting     body axes aligned, resident behind and over the intruder, ≥ riMountMin.
//   lateral      resident broadside to the intruder (axis 55–125° to the line between them),
//   threat       moving sideways toward it.
//   upright      neck → tail base shorter than riUprightRatio × body length, centroid still,
//                facing the other mouse at close range (resident: aggressive; intruder: defensive).

import Foundation

enum AggressionAnalyzers {

    // MARK: Body length

    /// Neck → tail base distance. `raw`: only keypoints detected in this frame (no interpolation).
    static func spine(_ f: AnimalFeatures, _ i: Int, raw: Bool) -> Double? {
        if raw && !(f.rawValid[KP.neck.rawValue][i] && f.rawValid[KP.tailBase.rawValue][i]) { return nil }
        guard let neck = f.pos(.neck, i), let tail = f.pos(.tailBase, i) else { return nil }
        return neck.distance(to: tail)
    }

    /// Body length of one animal: median neck → tail base distance while walking (0.5–3 BL/s) at
    /// least 1.5 BL from the other animal; falls back to the 75th percentile of all frames.
    static func bodyLength(_ f: AnimalFeatures, other g: AnimalFeatures, merged: [Bool], speed: (Int) -> Double?) -> (value: Double, walking: Bool)? {
        let n = f.count
        var all: [Double] = []
        for i in 0..<n where f.detected[i] && !merged[i] {
            if let s = spine(f, i, raw: true) { all.append(s) }
        }
        guard all.count >= 10, let rough = all.percentile(0.75), rough > 0 else { return nil }
        var walk: [Double] = []
        for i in 0..<n where f.detected[i] && g.detected[i] && !merged[i] {
            guard let s = spine(f, i, raw: true), let v = speed(i) else { continue }
            guard let a = center(f, i), let b = center(g, i), a.distance(to: b) > 2 * rough else { continue }
            if v > 0.7 * rough && v < 4 * rough { walk.append(s) }
        }
        if walk.count >= 30, let m = walk.finiteMedian { return (m, true) }
        return (rough, false)
    }

    /// Body centre; when it is hidden (e.g. under a mounting animal), the midpoint of the neck or
    /// head and the tail base.
    static func center(_ f: AnimalFeatures, _ i: Int) -> V2? {
        if let b = f.pos(.bodyCenter, i) { return b }
        guard let tail = f.pos(.tailBase, i) else { return nil }
        if let a = f.pos(.neck, i) ?? f.headBase(i) ?? f.pos(.nose, i) { return V2.mid(a, tail) }
        return nil
    }

    /// Body axis (tail base → neck), falling back to the body centre, the ears or the nose.
    static func axis(_ f: AnimalFeatures, _ i: Int) -> V2? {
        let front = f.pos(.neck, i) ?? f.pos(.bodyCenter, i) ?? f.headBase(i) ?? f.pos(.nose, i)
        guard let front else { return nil }
        let back = f.pos(.tailBase, i) ?? (f.pos(.neck, i) != nil ? f.pos(.bodyCenter, i) : nil)
        guard let back else { return nil }
        let v = front - back
        return v.length > 1e-6 ? v.normalized : nil
    }

    static func heading(_ f: AnimalFeatures, _ i: Int) -> V2? {
        guard let nose = f.pos(.nose, i), let base = f.headBase(i) else { return axis(f, i) }
        let v = nose - base
        return v.length > 1e-6 ? v.normalized : axis(f, i)
    }

    // MARK: Series helpers

    /// Central-difference velocity of the body centre over ±k samples.
    static func velocity(_ f: AnimalFeatures, t: [Double], k: Int, maxSpan: Double = 0.5) -> [V2?] {
        let n = f.count
        var out = [V2?](repeating: nil, count: n)
        for i in 0..<n {
            let a = max(0, i - k), b = min(n - 1, i + k)
            guard b > a, let p = center(f, a), let q = center(f, b) else { continue }
            let dt = t[b] - t[a]
            guard dt > 0, dt < maxSpan else { continue }
            out[i] = (q - p) / dt
        }
        return out
    }

    static func derivative(_ x: [Double], t: [Double], k: Int) -> [Double] {
        let n = x.count
        var out = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            let a = max(0, i - k), b = min(n - 1, i + k)
            guard b > a, x[a].isFinite, x[b].isFinite else { continue }
            let dt = t[b] - t[a]
            guard dt > 0, dt < 0.5 else { continue }
            out[i] = (x[b] - x[a]) / dt
        }
        return out
    }

    /// Centred moving mean over finite values (half-width h samples).
    static func movingMean(_ x: [Double], h: Int) -> [Double] {
        let n = x.count
        guard h > 0, n > 0 else { return x }
        var prefix = [Double](repeating: 0, count: n + 1)
        var count = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            let ok = x[i].isFinite
            prefix[i + 1] = prefix[i] + (ok ? x[i] : 0)
            count[i + 1] = count[i] + (ok ? 1 : 0)
        }
        var out = [Double](repeating: .nan, count: n)
        for i in 0..<n {
            let a = max(0, i - h), b = min(n, i + h + 1)
            let c = count[b] - count[a]
            if c > 0 { out[i] = (prefix[b] - prefix[a]) / Double(c) }
        }
        return out
    }

    /// "m:ss.s" video time.
    static func clock(_ t: Double) -> String {
        guard t.isFinite else { return "—" }
        let m = Int(max(0, t) / 60)
        return String(format: "%d:%04.1f", m, max(0, t) - Double(m) * 60)
    }

    static func cosine(_ a: V2?, _ b: V2?) -> Double? {
        guard let a, let b else { return nil }
        let la = a.length, lb = b.length
        guard la > 1e-9, lb > 1e-9 else { return nil }
        return a.dot(b) / (la * lb)
    }

    // MARK: Entry and roles

    /// Intruder introduction: the parameter if set, else the first moment both mice are detected
    /// for ≥ 1 s in a row.
    static func entryTime(_ c: AnalysisContext, _ A: AnimalFeatures, _ B: AnimalFeatures) -> (time: Double, auto: Bool, found: Bool) {
        let tb = c.tb
        if c.p.riIntruderEntry > 0 { return (c.p.riIntruderEntry, false, true) }
        var runStart: Int?
        for i in 0..<c.n {
            if A.detected[i] && B.detected[i] {
                if runStart == nil { runStart = i }
                if let s = runStart, tb.t[i] - tb.t[s] >= 1.0 { return (tb.t[s], true, true) }
            } else {
                runStart = nil
            }
        }
        return (tb.t.first ?? 0, true, false)
    }

    /// Resident: the parameter, else the mouse seen alone in the 10 s before the entry.
    static func residentIndex(_ c: AnalysisContext, _ A: AnimalFeatures, _ B: AnimalFeatures, entry: Double) -> (index: Int, auto: Bool, decided: Bool) {
        switch c.p.riResident {
        case "A": return (0, false, true)
        case "B": return (1, false, true)
        default: break
        }
        var ta = 0.0, tb = 0.0
        for i in c.tb.indices(from: entry - 10, to: entry) {
            if A.detected[i] { ta += c.tb.dur[i] }
            if B.detected[i] { tb += c.tb.dur[i] }
        }
        if max(ta, tb) >= 0.5 && max(ta, tb) >= 2 * min(ta, tb) { return (ta >= tb ? 0 : 1, true, true) }
        return (0, true, false)
    }

    // MARK: Analyzer

    static func residentIntruder(_ c: AnalysisContext) -> AnalysisReport {
        var r = AnalysisReport()
        guard c.fs.animals.count >= 2 else {
            r.warnings.append(L10n.tr("此会话只识别了一只鼠。请在“信息”中开启双鼠模式后重新识别。"))
            r.metrics = c.locomotionMetrics()
            r.blocks = [c.trajectoryBlock()]
            return r
        }
        let p = c.p, tb = c.tb, n = c.n
        let A = c.fs.animals[0], B = c.fs.animals[1]
        let merged = c.fs.identityMask(IdentityFlag.merged)
        let k = max(1, Int((0.05 / tb.dt).rounded()))
        let h = max(1, Int((0.165 / tb.dt).rounded()))      // ≈ 0.33 s window

        // Roles.
        let entry = entryTime(c, A, B)
        let role = residentIndex(c, A, B, entry: entry.time)
        let R = c.fs.animals[role.index], I = c.fs.animals[1 - role.index]
        let rName = role.index == 0 ? "A" : "B", iName = role.index == 0 ? "B" : "A"

        // Velocities, body lengths.
        let velR = velocity(R, t: tb.t, k: k), velI = velocity(I, t: tb.t, k: k)
        guard let blR = bodyLength(R, other: I, merged: merged, speed: { velR[$0]?.length }),
              let blI = bodyLength(I, other: R, merged: merged, speed: { velI[$0]?.length }) else {
            r.warnings.append(L10n.tr("关键点不足，无法估计体长，未做攻击分析。请检查识别结果（两只鼠的鼻尖、身体中心和尾根需要大部分时间可见）。"))
            r.metrics = c.locomotionMetrics(animal: 0, prefix: "a_", titlePrefix: "A ") + c.locomotionMetrics(animal: 1, prefix: "b_", titlePrefix: "B ")
            r.blocks = [c.trajectoryBlock()]
            return r
        }
        let BLR = blR.value, BLI = blI.value, BLm = (BLR + BLI) / 2

        // Per-frame kinematics in body lengths.
        var d = [Double](repeating: .nan, count: n)           // centroid distance (BL)
        var relV = d, sR = d, sI = d, apR = d, apI = d, turnR = d, turnI = d, ratioR = d, ratioI = d
        var nn = [Bool](repeating: false, count: n)
        var agRI = nn, agIR = nn
        let wR = derivative(R.bodyU, t: tb.t, k: k), wI = derivative(I.bodyU, t: tb.t, k: k)
        var visR = [Int](repeating: 0, count: n), visI = visR
        for i in 0..<n {
            if R.detected[i] { visR[i] = (0..<kKeypointCount).filter { R.rawValid[$0][i] }.count }
            if I.detected[i] { visI[i] = (0..<kKeypointCount).filter { I.rawValid[$0][i] }.count }
            if let v = velR[i] { sR[i] = v.length / BLR }
            if let v = velI[i] { sI[i] = v.length / BLI }
            if wR[i].isFinite { turnR[i] = abs(wR[i]) }
            if wI[i].isFinite { turnI[i] = abs(wI[i]) }
            if let s = spine(R, i, raw: true) { ratioR[i] = s / BLR }
            if let s = spine(I, i, raw: true) { ratioI[i] = s / BLI }
            guard let a = center(R, i), let b = center(I, i) else { continue }
            let gap = b - a
            d[i] = gap.length / BLm
            let u = gap.normalized
            if let va = velR[i], let vb = velI[i] {
                relV[i] = (va - vb).length / BLm
                apR[i] = va.dot(u) / BLm
                apI[i] = vb.dot(u * -1) / BLm
            }
            if let na = R.pos(.nose, i), let nb = I.pos(.nose, i) { nn[i] = na.distance(to: nb) < p.riSniffDist * BLm }
            if let na = R.pos(.nose, i), let ti = I.pos(.tailBase, i) { agRI[i] = na.distance(to: ti) < p.riSniffDist * BLm }
            if let ni = I.pos(.nose, i), let ta = R.pos(.tailBase, i) { agIR[i] = ni.distance(to: ta) < p.riSniffDist * BLm }
        }

        // Test period: from the intruder's entry, for riDuration seconds (0 = to the end).
        let testEnd = p.riDuration > 0 ? entry.time + p.riDuration : Double.infinity
        let inTest = (0..<n).map { tb.inWindow[$0] && tb.t[$0] >= entry.time - 1e-9 && tb.t[$0] < testEnd }
        let testDur = tb.total(inTest)
        func only(_ m: [Bool]) -> [Bool] { (0..<n).map { m[$0] && inTest[$0] } }

        // Close: centroids within riCloseDist, one detection for both, or one mouse hidden right
        // after being close (occluded under / over the other).
        var close = [Bool](repeating: false, count: n)
        var hiddenI = close, hiddenR = close
        var lastCloseI = false, lastCloseR = false
        for i in 0..<n {
            let both = R.detected[i] && I.detected[i]
            if both {
                close[i] = merged[i] || (d[i].isFinite && d[i] < p.riCloseDist)
                lastCloseI = close[i]; lastCloseR = close[i]
            } else if R.detected[i] && !I.detected[i] {
                hiddenI[i] = lastCloseI || merged[i]
                lastCloseI = hiddenI[i]; lastCloseR = false
                close[i] = hiddenI[i]
            } else if I.detected[i] && !R.detected[i] {
                hiddenR[i] = lastCloseR || merged[i]
                lastCloseR = hiddenR[i]; lastCloseI = false
                close[i] = hiddenR[i]
            } else {
                close[i] = lastCloseI || lastCloseR
            }
        }

        // Windowed pair motion.
        var meanSpeed = [Double](repeating: .nan, count: n), meanTurn = meanSpeed, pairSpeed = meanSpeed
        var turbulent = [Bool](repeating: false, count: n)
        var pairCenter = [V2?](repeating: nil, count: n)
        for i in 0..<n {
            let s = [sR[i], sI[i]].filter(\.isFinite)
            if !s.isEmpty { meanSpeed[i] = s.reduce(0, +) / Double(s.count) }
            let w = [turnR[i], turnI[i]].filter(\.isFinite)
            if !w.isEmpty { meanTurn[i] = w.reduce(0, +) / Double(w.count) }
            let a = center(R, i), b = center(I, i)
            if let a, let b { pairCenter[i] = V2.mid(a, b) } else { pairCenter[i] = a ?? b }
            let lost = (R.detected[i] && visR[i] <= kKeypointCount - 2) || (I.detected[i] && visI[i] <= kKeypointCount - 2)
            turbulent[i] = merged[i] || lost || (R.detected[i] != I.detected[i])
        }
        for i in 0..<n {
            let a = max(0, i - k), b = min(n - 1, i + k)
            guard b > a, let pa = pairCenter[a], let pb = pairCenter[b], tb.t[b] > tb.t[a] else { continue }
            pairSpeed[i] = pa.distance(to: pb) / (tb.t[b] - tb.t[a]) / BLm
        }
        let Sw = movingMean(meanSpeed, h: h), Tw = movingMean(meanTurn, h: h), Vw = movingMean(relV, h: h)
        let Pw = movingMean(pairSpeed, h: h)
        let sRw = movingMean(sR, h: h), sIw = movingMean(sI, h: h)
        let vF = p.riFightSpeed

        // Scuffles.
        var scuffle = [Bool](repeating: false, count: n)
        for i in 0..<n where close[i] && Sw[i].isFinite && Sw[i] > 0.6 * vF {
            let incoherent = (Vw[i].isFinite && Vw[i] > vF) || (Tw[i].isFinite && Tw[i] > p.riFightTurn)
            scuffle[i] = incoherent || (turbulent[i] && Sw[i] > vF)
        }
        let fightMask = Bouts.sustained(only(scuffle), tb, minDuration: p.riFightMin, mergeGap: 0.4)
        let notFight = AnalysisContext.not(fightMask)

        // Chase (resident → intruder) and following.
        var chaseRaw = [Bool](repeating: false, count: n)
        var followRaw = chaseRaw
        for i in 0..<n where notFight[i] {
            guard d[i].isFinite, let va = velR[i], let vb = velI[i], let a = center(R, i), let b = center(I, i) else { continue }
            let u = b - a
            let toward = cosine(va, u) ?? 0, away = cosine(vb, u) ?? 0
            if sR[i] > p.riChaseSpeed && sI[i] > 0.75 * p.riChaseSpeed && d[i] > 0.5 && d[i] < 5 && toward > 0.8 && away > 0.5 {
                chaseRaw[i] = true
            } else if sR[i] > 0.4 && sI[i] > 0.4 && d[i] < 2.7 && toward > 0.7 && away > 0.3 {
                followRaw[i] = true
            }
        }
        let chase = Bouts.sustained(only(chaseRaw), tb, minDuration: p.riChaseMin, mergeGap: 0.25)
        let follow = AnalysisContext.and(Bouts.sustained(only(followRaw), tb, minDuration: 0.5, mergeGap: 0.2), AnalysisContext.not(chase))

        // Every scuffle is an attack (who started it is not judged).
        let attackBouts = Bouts.find(fightMask, tb)
        let attackMask = Bouts.mask(attackBouts, count: n)

        // Clinch: inside a scuffle, both moving but the pair barely translates.
        var clinchRaw = [Bool](repeating: false, count: n)
        for i in 0..<n where fightMask[i] && Sw[i].isFinite && Sw[i] > 0.6 * vF {
            clinchRaw[i] = Pw[i].isFinite && Pw[i] < 0.5 * Sw[i]
        }
        let clinch = Bouts.sustained(clinchRaw, tb, minDuration: p.riClinchMin, mergeGap: 0.3)

        // Mounting: axes aligned, resident behind and over the intruder (continues while the
        // intruder is hidden under the resident).
        var mountRaw = [Bool](repeating: false, count: n)
        var mounting = false
        for i in 0..<n where notFight[i] {
            let slow = !sRw[i].isFinite || sRw[i] < 2
            if hiddenI[i] && mounting && slow { mountRaw[i] = true; continue }
            mounting = false
            guard slow, let aR = axis(R, i), let aI = axis(I, i), let cR = center(R, i), let cI = center(I, i),
                  let noseR = R.pos(.nose, i), let tailI = I.pos(.tailBase, i) else { continue }
            guard aR.dot(aI) > cos(35 * Double.pi / 180) else { continue }
            let rel = cR - cI
            let along = rel.dot(aI) / BLI, lateral = abs(rel.cross(aI)) / BLI
            let ahead = (noseR - tailI).dot(aI) / BLI
            if along > -1.2 && along < 0.15 && lateral < 0.55 && ahead > 0.35 {
                mountRaw[i] = true
                mounting = true
            }
        }
        let mount = Bouts.sustained(only(mountRaw), tb, minDuration: p.riMountMin, mergeGap: 0.5)

        // Keep down: resident visible on top, intruder hidden and still, after aggression.
        var kdRaw = [Bool](repeating: false, count: n)
        for i in 0..<n where notFight[i] && !mount[i] && close[i] && R.detected[i] && visR[i] >= 4 {
            let intruderHidden = !I.detected[i] || visI[i] <= 3
            let still = !I.detected[i] || !sIw[i].isFinite || sIw[i] < 0.7
            let residentCalm = !sRw[i].isFinite || sRw[i] < 2
            kdRaw[i] = intruderHidden && still && residentCalm
        }
        let aggressionEnds = (attackBouts + Bouts.find(chase, tb)).map(\.end).sorted()
        let keepDownBouts = Bouts.find(only(kdRaw), tb, minDuration: p.riKeepDownMin, mergeGap: 0.3).filter { b in
            aggressionEnds.contains { $0 <= b.start + 0.5 && b.start - $0 <= 5 }
        }
        let keepDown = Bouts.mask(keepDownBouts, count: n)

        // Lateral threat: broadside to the intruder, moving sideways toward it.
        var threatRaw = [Bool](repeating: false, count: n)
        for i in 0..<n where notFight[i] && !chase[i] {
            guard d[i].isFinite, d[i] > 0.5, d[i] < 2.4, sR[i] < 2.7, let aR = axis(R, i), let v = velR[i],
                  let cR = center(R, i), let cI = center(I, i) else { continue }
            let u = (cI - cR).normalized
            guard abs(aR.dot(u)) < cos(55 * Double.pi / 180) else { continue }
            let vs = v / BLR
            let along = vs.dot(aR), side = vs.dot(aR.perp)
            threatRaw[i] = abs(side) > 0.4 && abs(side) > 1.2 * abs(along) && vs.dot(u) > 0.2
        }
        let threat = Bouts.sustained(only(threatRaw), tb, minDuration: p.riThreatMin, mergeGap: 0.3)

        // Upright: spine path shortened, centroid still, facing the other mouse at close range.
        func upright(_ X: AnimalFeatures, _ Y: AnimalFeatures, ratio: [Double], speedW: [Double]) -> [Bool] {
            var m = [Bool](repeating: false, count: n)
            for i in 0..<n where notFight[i] {
                guard ratio[i].isFinite, ratio[i] < p.riUprightRatio, speedW[i].isFinite, speedW[i] < 0.8,
                      let hX = heading(X, i), let cX = center(X, i), let cY = center(Y, i) else { continue }
                let near: Bool
                if let a = X.pos(.nose, i), let b = Y.pos(.nose, i) { near = a.distance(to: b) < 1.1 * BLm || cX.distance(to: cY) < 1.5 * BLm }
                else { near = cX.distance(to: cY) < 1.5 * BLm }
                m[i] = near && (cosine(hX, cY - cX) ?? -1) > cos(45 * Double.pi / 180)
            }
            return Bouts.sustained(only(m), tb, minDuration: 0.3, mergeGap: 0.3)
        }
        let uprightR = upright(R, I, ratio: ratioR, speedW: sRw)
        let uprightI = upright(I, R, ratio: ratioI, speedW: sIw)

        // Investigation (outside scuffles).
        let nnT = AnalysisContext.and(only(nn), notFight)
        let agRIT = AnalysisContext.and(only(agRI), notFight)
        let agIRT = AnalysisContext.and(only(agIR), notFight)

        // Aggressive behaviour other than attacks.
        var aggressive = [Bool](repeating: false, count: n)
        for i in 0..<n { aggressive[i] = (chase[i] || keepDown[i] || threat[i] || uprightR[i]) && !attackMask[i] }

        // Metrics.
        let attackTotal = attackBouts.reduce(0) { $0 + $1.duration }
        let firstAttack = attackBouts.first.map { $0.start - entry.time }
        let chaseBouts = Bouts.find(chase, tb)
        let mountBouts = Bouts.find(mount, tb)
        r.metrics = [
            c.m("attack_latency", L10n.tr("攻击潜伏期"), firstAttack ?? (testDur > 0 ? testDur : nil), "s", 1,
                info: L10n.tr("从 intruder 放入到首次攻击；没有攻击时记为测试时长（删失值）"))
                .censoring(L10n.tr("没有攻击"), if: firstAttack == nil),
            c.m("attack_occurred", L10n.tr("发生攻击"), attackBouts.isEmpty ? 0 : 1, "", 0,
                info: L10n.tr("1 = 至少一次攻击；汇总表中一组的平均值 × 100 = 攻击鼠百分比")),
            c.m("attack_bouts", L10n.tr("攻击次数"), Double(attackBouts.count), "", 0),
            c.m("attack_total", L10n.tr("攻击总时长"), attackTotal, "s", 1),
            c.m("attack_mean", L10n.tr("平均攻击时长"), attackBouts.isEmpty ? nil : attackTotal / Double(attackBouts.count), "s", 2),
            c.m("clinch_total", L10n.tr("扭打时长"), tb.total(AnalysisContext.and(clinch, attackMask)), "s", 1,
                info: L10n.tr("攻击中两鼠都在动、但整体几乎不位移（原地翻滚）的时间；包含在攻击总时长内")),
            c.m("aggressive_total", L10n.tr("其他攻击性行为时长"), tb.total(aggressive), "s", 1,
                info: L10n.tr("追逐、压制、侧身威胁、攻击性直立的并集，不含攻击本身")),
            c.m("chase_total", L10n.tr("追逐时长"), tb.total(chase), "s", 1),
            c.m("chase_bouts", L10n.tr("追逐次数"), Double(chaseBouts.count), "", 0),
            c.m("keepdown_total", L10n.tr("压制时长"), tb.total(keepDown), "s", 1),
            c.m("lateral_threat_total", L10n.tr("侧身威胁时长"), tb.total(threat), "s", 1),
            c.m("upright_resident_total", L10n.tr("攻击性直立时长（resident）"), tb.total(uprightR), "s", 1),
            c.m("upright_intruder_total", L10n.tr("防御性直立时长（intruder）"), tb.total(uprightI), "s", 1),
            c.m("mount_total", L10n.tr("骑跨时长"), tb.total(mount), "s", 1),
            c.m("mount_bouts", L10n.tr("骑跨次数"), Double(mountBouts.count), "", 0),
            c.m("ag_ri", L10n.tr("resident 嗅 intruder 肛殖区"), tb.total(agRIT), "s", 1),
            c.m("ag_ir", L10n.tr("intruder 嗅 resident 肛殖区"), tb.total(agIRT), "s", 1),
            c.m("nose_nose", L10n.tr("鼻–鼻接触"), tb.total(nnT), "s", 1),
            c.m("follow_ri", L10n.tr("resident 跟随 intruder"), tb.total(follow), "s", 1),
            c.m("intruder_entry", L10n.tr("intruder 放入时间"), entry.time, "s", 1, info: L10n.tr("视频时间；所有指标从这一刻开始计")),
            c.m("test_duration", L10n.tr("测试时长"), testDur, "s", 1),
            c.m("body_length_resident", L10n.tr("resident 体长"), BLR, c.u, 1, info: L10n.tr("行走时颈到尾根距离的中位数")),
            c.m("body_length_intruder", L10n.tr("intruder 体长"), BLI, c.u, 1)
        ] + c.locomotionMetrics(animal: role.index, prefix: "r_", titlePrefix: "Resident ")
          + c.locomotionMetrics(animal: 1 - role.index, prefix: "i_", titlePrefix: "Intruder ")
        r.primaryKey = "attack_latency"

        // Blocks. One colour per behaviour (warm = aggression, blue = mounting, cool = social
        // investigation), the same in the bars, the timeline and the review player.
        let clinchInAttack = AnalysisContext.and(clinch, attackMask)
        let clinchBouts = Bouts.find(clinchInAttack, tb)
        var dots: [PlotDot] = []
        for b in attackBouts {
            let i = (b.i0 + b.i1) / 2
            if let pc = pairCenter[i] { dots.append(PlotDot(p: pc, color: .attack, radius: 2.4)) }
        }
        r.blocks.append(c.trajectoryBlock(caption: L10n.tr("红点 = 攻击发生的位置"), dots: dots))
        r.blocks.append(ReportBlock(title: L10n.tr("攻击与相关行为时长"), caption: L10n.tr("扭打包含在攻击内"), kind: .bars(BarData(items: [
            BarItem(label: L10n.tr("攻击"), value: attackTotal, color: .attack),
            BarItem(label: L10n.tr("扭打"), value: tb.total(clinchInAttack), color: .clinch),
            BarItem(label: L10n.tr("追逐"), value: tb.total(chase), color: .chase),
            BarItem(label: L10n.tr("压制"), value: tb.total(keepDown), color: .keepDown),
            BarItem(label: L10n.tr("侧身威胁"), value: tb.total(threat), color: .threat),
            BarItem(label: L10n.tr("攻击性直立"), value: tb.total(uprightR), color: .upright),
            BarItem(label: L10n.tr("骑跨"), value: tb.total(mount), color: .mount),
            BarItem(label: L10n.tr("肛殖区嗅探"), value: tb.total(agRIT), color: .investigate),
            BarItem(label: L10n.tr("鼻–鼻"), value: tb.total(nnT), color: .investigate),
            BarItem(label: L10n.tr("跟随"), value: tb.total(follow), color: .follow)
        ], unit: "s", horizontal: true))))
        // Before the intruder is in the cage: shaded, nothing is scored there.
        let preEntry = Epoch(name: L10n.tr("放入前"), start: min(tb.t.first ?? 0, entry.time), end: entry.time, color: .neutral)
        let epochs = entry.time > (tb.t.first ?? 0) + 0.5 ? [preEntry] : []
        let attackTrack = TimelineTrack(name: L10n.tr("攻击"), color: .attack, bouts: attackBouts,
                                        inner: clinchBouts, innerColor: .clinch, innerName: L10n.tr("扭打"))
        let tracks = [
            attackTrack,
            TimelineTrack(name: L10n.tr("追逐"), color: .chase, bouts: chaseBouts),
            TimelineTrack(name: L10n.tr("压制"), color: .keepDown, bouts: keepDownBouts),
            TimelineTrack(name: L10n.tr("侧身威胁"), color: .threat, bouts: Bouts.find(threat, tb)),
            TimelineTrack(name: L10n.tr("攻击性直立"), color: .upright, bouts: Bouts.find(uprightR, tb)),
            TimelineTrack(name: L10n.tr("骑跨"), color: .mount, bouts: mountBouts),
            TimelineTrack(name: L10n.tr("肛殖区嗅探"), color: .investigate, bouts: c.bouts(agRIT, minDuration: 0.1)),
            TimelineTrack(name: L10n.tr("跟随"), color: .follow, bouts: Bouts.find(follow, tb))
        ]
        var timelineTracks = tracks
        let toCheck = Bouts.find(c.fs.identityMask(IdentityFlag.uncertain), tb)
        let checkTrack = TimelineTrack(name: L10n.tr("身份待核对"), color: .neutral, bouts: toCheck, style: .flag)
        if c.fs.identity != nil && !toCheck.isEmpty { timelineTracks.append(checkTrack) }
        r.blocks.append(ReportBlock(title: L10n.tr("行为时间轴"), caption: L10n.tr("resident 的行为；深色段为攻击中的扭打，灰色为 intruder 放入前，斜线为需核对身份的时刻"),
                                    kind: .timeline(c.timeline(timelineTracks, epochs: epochs))))
        // Review player: the main behaviours (threat postures in one row, sniffing in one row),
        // then the moments to check.
        let threatAny = AnalysisContext.or(threat, uprightR)
        let sniffAny = AnalysisContext.or(agRIT, nnT)
        r.reviewTracks = [
            attackTrack, tracks[1], tracks[2],
            TimelineTrack(name: L10n.tr("威胁姿势"), color: .threat, bouts: Bouts.find(threatAny, tb)),
            tracks[5],
            TimelineTrack(name: L10n.tr("嗅探"), color: .investigate, bouts: c.bouts(sniffAny, minDuration: 0.1))
        ]
        if c.fs.identity != nil && !toCheck.isEmpty { r.reviewTracks.append(checkTrack) }
        r.reviewEpochs = epochs

        var pts: [LinePoint] = []
        let s0 = tb.windowStartTime
        let widx = (0..<n).filter { tb.inWindow[$0] && d[$0].isFinite }
        let st = max(1, widx.count / 600)
        for j in stride(from: 0, to: widx.count, by: st) { pts.append(LinePoint(x: (tb.t[widx[j]] - s0) / 60, y: d[widx[j]])) }
        r.blocks.append(ReportBlock(title: L10n.tr("两鼠间距（体长）"), caption: L10n.tr("身体中心距离 ÷ 两鼠平均体长"),
                                    kind: .line(LineData(series: [LineSeries(name: L10n.tr("间距"), color: .accent, points: pts)], xLabel: "min", yLabel: "BL", referenceY: p.riCloseDist,
                                                         referenceYLabel: L10n.tr("攻击判定距离 \(AnalysisContext.num(p.riCloseDist)) BL")))))
        if !attackBouts.isEmpty {
            let rows = attackBouts.map { b -> [String] in
                let cl = (b.i0...b.i1).reduce(0.0) { $0 + (clinch[$1] ? tb.dur[$1] : 0) }
                return [clock(b.start), String(format: "%.1f", b.duration), String(format: "%.1f", cl)]
            }
            r.blocks.append(ReportBlock(title: L10n.tr("攻击片段"), caption: L10n.tr("开始为视频时间（m:ss.s），不是距放入的时间"),
                                        kind: .table(TableData(columns: [L10n.tr("开始（视频时间）"), L10n.tr("时长 (s)"), L10n.tr("扭打 (s)")], rows: rows))))
        }

        // Frame columns (resident = R, intruder = I).
        func col(_ x: [Double]) -> [Double] { x.map { $0.isFinite ? ($0 * 1000).rounded() / 1000 : .nan } }
        r.frameColumns = [
            ("in_test", AnalysisContext.flag(inTest)),
            ("attack", AnalysisContext.flag(attackMask)), ("clinch", AnalysisContext.flag(AnalysisContext.and(clinch, attackMask))),
            ("chase", AnalysisContext.flag(chase)), ("keep_down", AnalysisContext.flag(keepDown)),
            ("lateral_threat", AnalysisContext.flag(threat)), ("upright_resident", AnalysisContext.flag(uprightR)),
            ("upright_intruder", AnalysisContext.flag(uprightI)), ("mount", AnalysisContext.flag(mount)),
            ("anogenital_R_to_I", AnalysisContext.flag(agRIT)), ("anogenital_I_to_R", AnalysisContext.flag(agIRT)),
            ("nose_nose", AnalysisContext.flag(nnT)), ("follow_R_I", AnalysisContext.flag(follow)),
            ("distance_bl", col(d)), ("relative_speed_bl_s", col(relV)),
            ("resident_speed_bl_s", col(sR)), ("intruder_speed_bl_s", col(sI)),
            ("resident_approach_bl_s", col(apR)), ("intruder_approach_bl_s", col(apI)),
            ("resident_length_ratio", col(ratioR)), ("intruder_length_ratio", col(ratioI)),
            ("contact_merged", AnalysisContext.flag(merged))
        ]

        // Warnings.
        // Standing note: listed after every warning (Analyzer.run), so the list opens with a real problem.
        r.notes.append(L10n.tr("攻击相关行为由关键点运动学规则判定（俯拍、6 个关键点），未经训练的分类器。发表前请用几段人工打分的视频核对（精确率 / 召回率、攻击潜伏期一致性），必要时在参数中调整阈值。"))
        if !entry.found {
            r.warnings.append(L10n.tr("没有找到两只鼠同时稳定出现的时刻，intruder 放入时间按视频开头计。请在参数中填写放入时间。"))
        } else if entry.auto {
            r.warnings.append(L10n.tr("intruder 放入时间为自动检测（两只鼠首次同时稳定出现）。如不准确，请在参数中填写。"))
        }
        if role.auto && !role.decided {
            r.warnings.append(L10n.tr("放入前没有只有一只鼠的画面，无法自动判断 resident，默认 resident = A。请在回看中确认，必要时在参数中指定。"))
        }
        if !blR.walking || !blI.walking {
            r.warnings.append(L10n.tr("行走时可用于估计体长的帧较少，体长用所有帧的 75% 分位数估计，阈值可能偏差。"))
        }
        if c.fs.identity == nil {
            r.warnings.append(L10n.tr("这些姿态数据没有全视频身份判定；resident / intruder 可能在接触后交换。重新识别即可使用全视频身份判定。"))
        }
        let stride = c.session.usedInference?.stride ?? c.session.inference.stride
        if stride > 1 {
            r.warnings.append(L10n.tr("攻击检测需要逐帧识别（一次扑击只有 100–200 ms）。当前为抽帧识别，请改为逐帧后重新识别。"))
        }
        if mountBouts.count > 0 {
            r.notes.append(L10n.tr("骑跨的性质（性、支配或攻击）无法从运动学判断，请结合配对的性别和实验设计解释。"))
        }

        // Methods.
        let roleText = role.auto ? L10n.tr("自动判断（放入前单独出现的鼠）") : L10n.tr("由实验者指定")
        r.methods.append(L10n.tr("居住者–入侵者测试：resident = \(rName)、intruder = \(iName)（\(roleText)）；intruder 放入时间 \(AnalysisContext.num((entry.time * 10).rounded() / 10)) s，测试时长 \(AnalysisContext.num((testDur * 10).rounded() / 10)) s，所有指标从放入开始计算。"))
        r.methods.append(L10n.tr("所有距离和速度以体长（BL）为单位：每只鼠的体长为行走时（0.7–4 BL/s、与另一只鼠相距 > 2 BL）颈到尾根距离的中位数（resident \(AnalysisContext.num((BLR * 10).rounded() / 10)) \(c.u)，intruder \(AnalysisContext.num((BLI * 10).rounded() / 10)) \(c.u)）；两鼠间距除以平均体长。相对速度为两鼠速度向量之差的模。"))
        r.methods.append(L10n.tr("攻击：身体中心距离 < \(AnalysisContext.num(p.riCloseDist)) BL（或重叠成一个检测），且 0.33 s 窗口内平均速度 > \(AnalysisContext.num(0.6 * vF)) BL/s、相对速度 > \(AnalysisContext.num(vF)) BL/s 或体轴角速度 > \(AnalysisContext.num(p.riFightTurn))°/s，持续 ≥ \(AnalysisContext.num(p.riFightMin)) s；不区分发起者。扭打为攻击中两鼠都在动、整体位移速度 < 平均速度一半、持续 ≥ \(AnalysisContext.num(p.riClinchMin)) s 的部分。"))
        r.methods.append(L10n.tr("追逐：resident 速度 > \(AnalysisContext.num(p.riChaseSpeed)) BL/s、intruder 速度 > \(AnalysisContext.num(0.75 * p.riChaseSpeed)) BL/s，resident 朝 intruder 移动、intruder 沿同一方向远离，间距 0.5–5 BL，持续 ≥ \(AnalysisContext.num(p.riChaseMin)) s。压制：两鼠贴近，resident 关键点清楚可见而 intruder 的关键点被遮挡且几乎不动，持续 ≥ \(AnalysisContext.num(p.riKeepDownMin)) s，且在攻击或追逐结束后 5 s 内开始。"))
        r.methods.append(L10n.tr("侧身威胁：resident 体轴与两鼠连线成 55–125°，以侧向为主朝 intruder 移动，间距 0.5–2.4 BL，持续 ≥ \(AnalysisContext.num(p.riThreatMin)) s。直立：颈到尾根距离 < \(AnalysisContext.num(p.riUprightRatio)) × 体长、身体中心几乎不动、面向近处的另一只鼠，持续 ≥ 0.3 s（resident 记为攻击性直立，intruder 记为防御性直立）。骑跨：两鼠体轴同向（< 35°），resident 位于 intruder 后上方，持续 ≥ \(AnalysisContext.num(p.riMountMin)) s。"))
        r.methods.append(L10n.tr("嗅探：鼻尖到对方鼻尖或尾根 < \(AnalysisContext.num(p.riSniffDist)) BL，不含打斗时段；跟随：两鼠都在移动（> 0.4 BL/s）、resident 朝 intruder 移动、间距 < 2.7 BL，持续 ≥ 0.5 s，且不属于追逐。"))
        return r
    }
}
