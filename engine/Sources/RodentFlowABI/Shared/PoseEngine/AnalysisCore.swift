// AnalysisCore.swift — shared analysis context, helpers and the dispatcher.

import Foundation

struct AnalysisContext {
    let session: Session
    let fs: FeatureSet
    let zones: [Zone]
    /// Metrics of a paired session (e.g. the "no target" run of the social interaction test).
    let companion: [String: Double]
    /// Marble burying: brightness of each marble read from the video (nil until read).
    var marbles: MarbleSamples? = nil

    var tb: TimeBase { fs.tb }
    var p: AnalysisParams { session.params }
    var a0: AnimalFeatures { fs.animals[0] }
    var u: String { fs.unit }
    var n: Int { tb.count }
    var extent: V2 { fs.mapping.extent }

    func zone(_ id: String) -> Zone? { zones.first { $0.id == id } }

    // MARK: Masks

    /// Frames where keypoint `k` of `animal` satisfies `test`. Missing positions keep the
    /// previous state (`hold`), so a short tracking gap does not create a fake exit / entry.
    func mask(_ k: KP, animal: Int = 0, hold: Bool = true, _ test: (V2) -> Bool) -> [Bool] {
        let f = fs.animals[animal]
        var m = [Bool](repeating: false, count: n)
        var last = false
        for i in 0..<n {
            if let q = f.pos(k, i) {
                last = test(q)
                m[i] = last
            } else {
                m[i] = hold ? last : false
            }
        }
        return m
    }

    func mask(_ k: KP, in zone: Zone, animal: Int = 0, hold: Bool = true) -> [Bool] {
        mask(k, animal: animal, hold: hold) { zone.contains($0) }
    }

    /// Frames where a series is finite and satisfies `test`.
    func mask(_ series: [Double], _ test: (Double) -> Bool) -> [Bool] {
        series.map { $0.isFinite && test($0) }
    }

    static func and(_ a: [Bool], _ b: [Bool]) -> [Bool] { zip(a, b).map { $0 && $1 } }
    static func or(_ a: [Bool], _ b: [Bool]) -> [Bool] { zip(a, b).map { $0 || $1 } }
    static func not(_ a: [Bool]) -> [Bool] { a.map { !$0 } }

    /// Frames with valid body position inside the window.
    func trackedMask(animal: Int = 0) -> [Bool] {
        (0..<n).map { fs.animals[animal].pos(.bodyCenter, $0) != nil }
    }

    /// Immobility / freezing: motion index below threshold, sustained for the minimum duration.
    func freezingMask(animal: Int = 0) -> [Bool] {
        let raw = mask(fs.animals[animal].motion) { $0 < p.freezeSpeed }
        return Bouts.sustained(raw, tb, minDuration: p.freezeMin)
    }

    func movingMask(animal: Int = 0) -> [Bool] {
        mask(fs.animals[animal].speed) { $0 > p.moveSpeed }
    }

    // MARK: Quantities

    /// Path length of a keypoint inside the window (optionally only where `onlyWhere` is true).
    func distance(_ k: KP = .bodyCenter, animal: Int = 0, onlyWhere: [Bool]? = nil) -> Double {
        let f = fs.animals[animal]
        var d = 0.0
        guard n > 1 else { return 0 }
        for i in 1..<n where tb.inWindow[i] && tb.inWindow[i - 1] {
            if let w = onlyWhere, !w[i] { continue }
            guard tb.t[i] - tb.t[i - 1] <= 0.5, let a = f.pos(k, i - 1), let b = f.pos(k, i) else { continue }
            d += a.distance(to: b)
        }
        return d
    }

    /// Mean of a series over window frames where `onlyWhere` (if any) is true.
    func mean(_ s: [Double], onlyWhere: [Bool]? = nil) -> Double? {
        var sum = 0.0, c = 0.0
        for i in 0..<min(n, s.count) where tb.inWindow[i] && s[i].isFinite {
            if let w = onlyWhere, !w[i] { continue }
            sum += s[i]; c += 1
        }
        return c > 0 ? sum / c : nil
    }

    func values(_ s: [Double], onlyWhere: [Bool]? = nil) -> [Double] {
        var out: [Double] = []
        for i in 0..<min(n, s.count) where tb.inWindow[i] && s[i].isFinite {
            if let w = onlyWhere, !w[i] { continue }
            out.append(s[i])
        }
        return out
    }

    func percent(_ part: Double, _ whole: Double) -> Double? { whole > 0 ? part / whole * 100 : nil }

    /// (a − b) / (a + b), nil when both are zero.
    func index(_ a: Double, _ b: Double) -> Double? { a + b > 0 ? (a - b) / (a + b) : nil }

    /// Window time bins [start, end).
    func timeBins(_ size: Double) -> [(Double, Double)] {
        let s = tb.windowStartTime
        var lastT = s
        for i in stride(from: n - 1, through: 0, by: -1) where tb.inWindow[i] { lastT = tb.t[i] + tb.dur[i]; break }
        let bin = max(size, 1)
        var out: [(Double, Double)] = []
        var a = s
        while a < lastT - 1e-6 && out.count < 2000 {
            out.append((a, min(a + bin, lastT)))
            a += bin
        }
        return out
    }

    /// Bins of a time course (series contract): bins of `size` seconds from the window start, each with its centre `x`
    /// in minutes since the window start (seconds with `seconds`). A bin with less than 90 % of its width analysed (the
    /// short last bin of a window that is not a whole number of bins) is left out.
    func courseBins(_ size: Double, seconds: Bool = false) -> [(start: Double, end: Double, x: Double)] {
        let bin = max(size, 1)
        let s0 = tb.windowStartTime
        return timeBins(bin).compactMap { b0, b1 in
            guard windowTime(from: b0, to: b1) >= 0.9 * bin else { return nil }
            let centre = b0 + bin / 2 - s0
            return (start: b0, end: b1, x: seconds ? centre : centre / 60)
        }
    }

    /// x-axis title of a time course: unit and bin width ("Time (min), 1-min bins") in the interface language.
    func courseAxis(_ size: Double, seconds: Bool = false) -> String {
        TimeCourseLabel.interface(bin: max(size, 1), seconds: seconds)
    }

    /// Total time where mask is true inside [a, b).
    func total(_ mask: [Bool], from a: Double, to b: Double) -> Double {
        var s = 0.0
        for i in tb.indices(from: a, to: b) where tb.inWindow[i] && mask[i] { s += tb.dur[i] }
        return s
    }

    func windowTime(from a: Double, to b: Double) -> Double {
        var s = 0.0
        for i in tb.indices(from: a, to: b) where tb.inWindow[i] { s += tb.dur[i] }
        return s
    }

    // MARK: Plot helpers

    /// Downsampled polylines of a keypoint inside the window (optionally only where mask is true).
    /// For drawing only: a step faster than an animal can move (a residual tracking jump) starts
    /// a new polyline instead of being drawn as a long straight line across the arena.
    func segments(_ k: KP = .bodyCenter, animal: Int = 0, onlyWhere: [Bool]? = nil, maxPoints: Int = 4000, from a: Double = -.infinity, to b: Double = .infinity) -> [[V2]] {
        let f = fs.animals[animal]
        let step = max(1, n / maxPoints)
        let span = max(extent.x, extent.y)
        func plausible(_ from: V2, _ to: V2, _ dt: Double) -> Bool {
            let d = from.distance(to: to)
            if fs.isMetric && p.maxJumpSpeed > 0 { return d <= p.maxJumpSpeed * max(dt, tb.dt) * 1.25 + 2 }
            return d <= span * (0.05 + 1.5 * max(dt, tb.dt))
        }
        var segs: [[V2]] = []
        var cur: [V2] = []
        var lastT = 0.0
        var i = 0
        while i < n {
            let inRange = tb.inWindow[i] && tb.t[i] >= a && tb.t[i] < b && (onlyWhere?[i] ?? true)
            if inRange, let q = f.pos(k, i) {
                if let prev = cur.last, !plausible(prev, q, tb.t[i] - lastT) {
                    if cur.count > 1 { segs.append(cur) }
                    cur = []
                }
                cur.append(q)
                lastT = tb.t[i]
            } else if !cur.isEmpty {
                if cur.count > 1 { segs.append(cur) }
                cur = []
            }
            i += step
        }
        if cur.count > 1 { segs.append(cur) }
        return segs
    }

    func dots(_ k: KP, animal: Int = 0, where m: [Bool], color: ColorKey, maxDots: Int = 1500, radius: Double = 1.4) -> [PlotDot] {
        let f = fs.animals[animal]
        let idx = (0..<n).filter { m[$0] && tb.inWindow[$0] && f.pos(k, $0) != nil }
        let step = max(1, idx.count / maxDots)
        return stride(from: 0, to: idx.count, by: step).compactMap { j in
            f.pos(k, idx[j]).map { PlotDot(p: $0, color: color, radius: radius) }
        }
    }

    func heatGrid(_ k: KP = .bodyCenter, animal: Int = 0, cell: Double? = nil) -> HeatGrid {
        let e = extent
        let c = cell ?? (fs.isMetric ? max(0.5, p.spatialBin) : max(e.x, e.y) / 40)
        let cols = max(1, Int((e.x / c).rounded(.up)))
        let rows = max(1, Int((e.y / c).rounded(.up)))
        var v = [Double](repeating: 0, count: cols * rows)
        let f = fs.animals[animal]
        for i in 0..<n where tb.inWindow[i] {
            guard let q = f.pos(k, i) else { continue }
            let cx = Int(q.x / c), cy = Int(q.y / c)
            guard cx >= 0, cy >= 0, cx < cols, cy < rows else { continue }
            v[cy * cols + cx] += tb.dur[i]
        }
        if let arena = ZoneBuilder.arenaZone(session.calibration, mapping: fs.mapping),
           session.calibration.kind == .rectangle || session.calibration.kind == .circle {
            // Ring track (zero maze): the empty center is blank, but a cell with time in it (an edge cell whose
            // center lies just off the track) is kept.
            let ring = session.calibration.kind == .circle && session.calibration.ringWidthCM > 0
            for r in 0..<rows {
                for col in 0..<cols where !arena.contains(V2((Double(col) + 0.5) * c, (Double(r) + 0.5) * c)) {
                    if ring && v[r * cols + col] > 0 { continue }
                    v[r * cols + col] = .nan
                }
            }
        } else if let maze = MazeGeometry.from(session.calibration, mapping: fs.mapping) {
            // Mazes: the empty space between the arms is not part of the arena (drawn blank, like the
            // outside of a box). Cells with time in them (head dips over an edge) are always kept.
            for r in 0..<rows {
                for col in 0..<cols where v[r * cols + col] == 0 {
                    let q = V2((Double(col) + 0.5) * c, (Double(r) + 0.5) * c)
                    if maze.armIndex(q, tolerance: 1.6) == nil && !maze.inCenter(q, tolerance: 1.6) {
                        v[r * cols + col] = .nan
                    }
                }
            }
        }
        return HeatGrid(columns: cols, rows: rows, cell: c, values: v)
    }

    func arenaPlot(paths: [PlotPath]? = nil, dots: [PlotDot] = [], arrows: [PlotArrow] = [], heat: HeatGrid? = nil, zones z: [Zone]? = nil) -> ArenaPlotData {
        let defaultPaths: [PlotPath] = fs.animals.indices.map { a in
            PlotPath(color: fs.animals.count > 1 ? (a == 0 ? .animalA : .animalB) : .accent, segments: segments(animal: a))
        }
        return ArenaPlotData(extent: extent, arena: ZoneBuilder.arenaZone(session.calibration, mapping: fs.mapping),
                             zones: z ?? zones, paths: paths ?? defaultPaths, dots: dots, arrows: arrows, heat: heat, unit: u,
                             mapping: fs.mapping)
    }

    func trajectoryBlock(_ title: String = L10n.tr("轨迹与区域"), caption: String? = nil, dots: [PlotDot] = [], paths: [PlotPath]? = nil) -> ReportBlock {
        ReportBlock(title: title, caption: caption, kind: .arena(arenaPlot(paths: paths, dots: dots)))
    }

    func heatBlock(_ title: String = L10n.tr("停留热图"), caption: String? = nil, cell: Double? = nil,
                   keypoint k: KP = .bodyCenter, animal: Int = 0) -> ReportBlock {
        heatBlock(title, caption: caption, grid: heatGrid(k, animal: animal, cell: cell), keypoint: k)
    }

    /// Heat map figure of an already computed grid (zones drawn on top, figure layers apply).
    func heatBlock(_ title: String, caption: String?, grid: HeatGrid, keypoint k: KP) -> ReportBlock {
        var plot = arenaPlot(paths: [], heat: grid)
        plot.heatKeypoint = k
        return ReportBlock(title: title, caption: caption, kind: .arena(plot))
    }

    /// Distance per time bin (full bins only, as the time courses).
    func distanceBinsBlock(animal: Int = 0) -> ReportBlock? {
        let bins = courseBins(p.timeBin)
        guard bins.count > 1 else { return nil }
        let f = fs.animals[animal]
        var items: [BarItem] = []
        for (k, b) in bins.enumerated() {
            var d = 0.0
            let r = tb.indices(from: b.start, to: b.end)
            for i in r where i > 0 && tb.inWindow[i] && tb.inWindow[i - 1] {
                guard tb.t[i] - tb.t[i - 1] <= 0.5, let x = f.pos(.bodyCenter, i - 1), let y = f.pos(.bodyCenter, i) else { continue }
                d += x.distance(to: y)
            }
            items.append(BarItem(label: binLabel(k, b.start, b.start + max(p.timeBin, 1)), value: fs.isMetric ? d / 100 : d, color: .accent))
        }
        let dropped = timeBins(p.timeBin).count > bins.count
        let width = Self.durationText(p.timeBin)
        return ReportBlock(title: L10n.tr("分段路程"),
                           caption: dropped ? L10n.tr("每 \(width) 的移动距离；最后不满 90% 的一段未画出") : L10n.tr("每 \(width) 的移动距离"),
                           kind: .bars(BarData(items: items, unit: fs.isMetric ? "m" : "px", decimals: 2)))
    }

    /// Bar label of a time bin, with its unit: "0–1 min", "0–30 s".
    func binLabel(_ k: Int, _ a: Double, _ b: Double) -> String {
        let s = tb.windowStartTime
        let x0 = (a - s) / 60, x1 = (b - s) / 60
        if p.timeBin >= 60 { return String(format: "%@–%@ min", Self.num((x0 * 10).rounded() / 10), Self.num((x1 * 10).rounded() / 10)) }
        return String(format: "%.0f–%.0f s", a - s, b - s)
    }

    static func durationText(_ s: Double) -> String {
        if s >= 60 && abs(s.truncatingRemainder(dividingBy: 60)) < 0.01 { return "\(Int(s / 60)) min" }
        return String(format: "%.0f s", s)
    }

    /// Timeline over the analysis window.
    func timeline(_ tracks: [TimelineTrack], epochs: [Epoch] = []) -> TimelineData {
        var end = tb.windowStartTime
        for i in stride(from: n - 1, through: 0, by: -1) where tb.inWindow[i] { end = tb.t[i] + tb.dur[i]; break }
        return TimelineData(start: tb.windowStartTime, end: end, tracks: tracks, epochs: epochs)
    }

    // MARK: Metric helpers

    func m(_ key: String, _ title: String, _ value: Double?, _ unit: String = "", _ decimals: Int = 1, info: String? = nil) -> MetricValue {
        MetricValue(key: key, title: title, value: value, unit: unit, decimals: decimals, info: info)
    }

    /// Distance traveled, mean speed and moving time for one animal.
    func locomotionMetrics(animal: Int = 0, prefix: String = "", titlePrefix: String = "") -> [MetricValue] {
        let d = distance(animal: animal)
        let moving = tb.total(movingMask(animal: animal))
        let win = tb.windowDuration
        let distMetric = fs.isMetric
            ? m(prefix + "distance", titlePrefix + L10n.tr("总路程"), d / 100, "m", 2)
            : m(prefix + "distance", titlePrefix + L10n.tr("总路程"), d, "px", 0)
        return [
            distMetric,
            m(prefix + "mean_speed", titlePrefix + L10n.tr("平均速度"), win > 0 ? d / win : nil, u + "/s", 1),
            m(prefix + "moving_pct", titlePrefix + L10n.tr("运动时间"), percent(moving, win), "%", 1, info: L10n.tr("速度 > \(Self.num(p.moveSpeed)) \(u)/s"))
        ]
    }

    static func num(_ v: Double) -> String {
        abs(v - v.rounded()) < 1e-9 ? String(format: "%.0f", v) : String(format: "%g", v)
    }

    // MARK: Quality

    func quality() -> QualityInfo {
        var q = QualityInfo()
        q.frames = n
        let win = (0..<n).filter { tb.inWindow[$0] }
        q.framesInWindow = win.count
        q.windowSeconds = tb.windowDuration
        q.unit = u
        q.pxPerUnit = fs.mapping.pxPerUnit
        q.sampleRate = tb.dt > 0 ? 1 / tb.dt : 0
        guard !win.isEmpty else { return q }
        let det = win.filter { a0.detected[$0] }.count
        q.detectionRate = Double(det) / Double(win.count)
        if fs.animals.count > 2 {
            // Identities are only slots here: the rate over all animal-frames, not the first slot's.
            let found = win.reduce(0) { sum, i in sum + fs.animals.filter { $0.detected[i] }.count }
            q.detectionRate = Double(found) / Double(win.count * fs.animals.count)
        }
        q.keypointRates = (0..<kKeypointCount).map { k in
            Double(win.filter { a0.rawValid[k][$0] }.count) / Double(win.count)
        }
        q.headDirectionRate = Double(win.filter { a0.hd[$0].isFinite }.count) / Double(win.count)
        if fs.animals.count > 2 {
            let total = Double(win.count * fs.animals.count)
            q.keypointRates = (0..<kKeypointCount).map { k in
                Double(fs.animals.reduce(0) { sum, f in sum + win.filter { f.rawValid[k][$0] }.count }) / total
            }
            q.headDirectionRate = Double(fs.animals.reduce(0) { sum, f in sum + win.filter { f.hd[$0].isFinite }.count }) / total
        }
        return q
    }

    func commonWarnings(_ q: QualityInfo) -> [String] {
        var w: [String] = []
        if q.framesInWindow < 10 {
            w.append(L10n.tr("分析时间段内的帧太少，请检查“分析起点 / 时长”是否超出了已识别的范围。"))
            return w
        }
        if q.detectionRate < 0.8 {
            w.append(String(format: L10n.tr("检出率只有 %.0f%%：结果可能偏差较大。请检查光照、遮挡，或在回看中确认。"), q.detectionRate * 100))
        }
        if !fs.isMetric && session.paradigm != .poseOnly && session.paradigm != .rotation {
            w.append(L10n.tr("未标定：距离和速度以像素为单位，基于厘米的阈值不适用。"))
        }
        if fs.animals.count == 2 {
            let both = (0..<n).filter { tb.inWindow[$0] && fs.animals[0].detected[$0] && fs.animals[1].detected[$0] }.count
            let frac = Double(both) / Double(max(1, q.framesInWindow))
            if frac < 0.8 {
                w.append(String(format: L10n.tr("只有 %.0f%% 的帧同时检出两只鼠；双鼠贴近或重叠时可能漏检或身份交换。"), frac * 100))
            }
        }
        return w
    }

    // MARK: Base per-frame columns

    /// Flags exported in the frame-by-frame CSV.
    static func flag(_ m: [Bool]) -> [Double] { m.map { $0 ? 1 : 0 } }
}

// MARK: - Dispatcher

enum Analyzer {
    static func run(session: Session, track: PoseTrack, companion: [String: Double] = [:], marbles: MarbleSamples? = nil) -> AnalysisReport {
        run(session: session, features: Kinematics.build(track: track, session: session), companion: companion, marbles: marbles)
    }

    static func run(session: Session, features fs: FeatureSet, companion: [String: Double] = [:], marbles: MarbleSamples? = nil) -> AnalysisReport {
        if let raw = session.unknownParadigm {
            // A task of a newer RodentFlow: never analysed (or overwritten) with a different paradigm here.
            var r = AnalysisReport()
            r.warnings = [String(format: L10n.tr("这次分析来自更新版本的 RodentFlow（任务 %@），当前版本无法分析它。请更新 App；已有的结果和数据都保留。"), raw)]
            r.primaryKey = ""
            return r
        }
        let zones = ZoneBuilder.zones(session, mapping: fs.mapping)
        let ctx = AnalysisContext(session: session, fs: fs, zones: zones, companion: companion, marbles: marbles)
        var r: AnalysisReport
        if fs.tb.count == 0 {
            r = AnalysisReport()
            r.warnings = [L10n.tr("还没有姿态数据。")]
            r.zones = zones
            r.primaryKey = session.paradigm.primaryMetricKey
            return r
        }
        switch session.paradigm {
        case .threeChamber: r = SocialAnalyzers.threeChamber(ctx)
        case .socialInteraction: r = SocialAnalyzers.socialInteraction(ctx)
        case .dyadicSocial: r = SocialAnalyzers.dyadic(ctx)
        case .residentIntruder: r = AggressionAnalyzers.residentIntruder(ctx)
        case .groupBehavior: r = GroupAnalyzers.analyze(ctx)
        case .headDirection: r = SpaceAnalyzers.headDirection(ctx)
        case .spatialExploration: r = SpaceAnalyzers.spatial(ctx)
        case .openField: r = SpaceAnalyzers.openField(ctx)
        case .rotation: r = SpaceAnalyzers.rotation(ctx)
        case .poseOnly: r = SpaceAnalyzers.poseOnly(ctx)
        case .elevatedPlusMaze: r = AnxietyAnalyzers.epm(ctx)
        case .elevatedZeroMaze: r = ZeroMazeAnalyzer.analyze(ctx)
        case .lightDark: r = AnxietyAnalyzers.lightDark(ctx)
        case .noveltySuppressedFeeding: r = FeedingAnalyzer.analyze(ctx)
        case .novelObject: r = MemoryAnalyzers.novelObject(ctx)
        case .barnesMaze: r = MemoryAnalyzers.barnes(ctx)
        case .waterMaze: r = MemoryAnalyzers.waterMaze(ctx)
        case .passiveAvoidance: r = PlaceAnalyzers.passiveAvoidance(ctx)
        case .placePreference: r = PlaceAnalyzers.placePreference(ctx)
        case .yMaze: r = MemoryAnalyzers.yMaze(ctx)
        case .tMaze: r = MemoryAnalyzers.tMaze(ctx)
        case .fearConditioning: r = MemoryAnalyzers.fear(ctx)
        case .looming: r = MemoryAnalyzers.looming(ctx)
        case .platformAvoidance: r = PlatformAnalyzers.platformAvoidance(ctx)
        case .stepDown: r = PlatformAnalyzers.stepDown(ctx)
        case .visualCliff: r = PlatformAnalyzers.visualCliff(ctx)
        case .marbleBurying: r = MarbleAnalyzer.analyze(ctx)
        }
        if r.zones.isEmpty { r.zones = zones }
        if r.primaryKey.isEmpty { r.primaryKey = session.paradigm.primaryMetricKey }
        // Time course for the group comparison (RodentFlow 2.1): every single-animal task has distance per bin; fear
        // conditioning also freezing per bin. Tasks with their own series keep them.
        if r.series.isEmpty, fs.animals.count == 1, session.paradigm != .poseOnly {
            let bin = session.params.timeBin
            if session.paradigm == .fearConditioning, let f = ctx.percentSeries(ctx.freezingMask(), key: "freeze_pct_bin", name: "Freezing", bin: bin).series {
                r.series.append(f)
            }
            if let d = ctx.distanceSeries(bin: bin) { r.series.append(d) }
        }
        if let i = r.metrics.firstIndex(where: { $0.key == r.primaryKey }) { r.metrics[i].highlight = true }
        r.quality = ctx.quality()
        r.warnings = ctx.commonWarnings(r.quality) + r.warnings
        let preamble = methodsPreamble(ctx)
        r.methods.insert(contentsOf: preamble, at: 0)
        if !r.series.isEmpty {
            let bin = session.paradigm == .marbleBurying ? max(60, session.params.timeBin) : max(session.params.timeBin, 1)
            r.methods.append(L10n.tr("时间进程从分析起点起每 \(AnalysisContext.durationText(bin)) 一段，按每段的中点作图；分析时间不足一段 90% 的段（如最后较短的一段）不计入。"))
        }
        flagOutsideArena(ctx, into: &r)
        let model = modelNotes(session)
        if let m = model.method { r.methods.insert(m, at: preamble.count) }
        if let w = model.warning { r.warnings.append(w) }
        r.model = session.usedModel ?? kModelName
        if r.model == kDyadBWModelName { coatNotes(ctx, into: &r) }
        // Standing notes of the task after every warning, so a collapsed list shows a real problem first.
        r.warnings += r.notes
        r.notes = []
        return r
    }

    /// Version of the measure definitions stored with a session (Session.metricsVersion). Raise it when a stored
    /// measure, its name or the series format changes: the phone then recomputes the stored entries of earlier
    /// analyses from their saved pose data (AppModel). 1 = RodentFlow 2.1 build 22 and earlier (not stored);
    /// 2 = build 23: Barnes latency censored + found_target, Y-maze AAR and chance, T-maze VTE ≥ 10 trials,
    /// series at bin centres with partial bins left out. 3 = build 24: open-field corner zones (corner_* measures).
    static let metricsVersion = 3

    /// Oldest definitions version whose stored numbers are still current for `paradigm`. A new version that changes only
    /// some tasks raises only theirs, so the stored numbers of every other task stay as they are: only those tasks are
    /// refreshed on the phone (AppModel) and recomputed on the Mac (SessionMetrics.cacheKey).
    static func requiredMetricsVersion(_ paradigm: Paradigm) -> Int {
        switch paradigm {
        case .openField: return 3
        default: return 2
        }
    }

    /// Dark–white pairs: which animal is the dark one, and detection of each (the dark mouse can be missed on
    /// dark bedding; the white one when the two touch). RodentFlow 2.0 iOS build 19 / Mac build 15.
    static func coatNotes(_ c: AnalysisContext, into r: inout AnalysisReport) {
        let fs = c.fs
        guard fs.animals.count == 2 else { return }
        guard let dark = fs.darkAnimal else {
            r.warnings.append(L10n.tr("没能从背部毛色分清哪只是深色鼠、哪只是白鼠（两只亮度相近，或这段数据没有记录毛色）。请确认“小鼠毛色”选得对。"))
            return
        }
        r.darkAnimal = dark
        let names = ["A", "B"]
        let white = 1 - dark
        r.methods.append(String(format: L10n.tr("按背部毛色，%@ 为深色鼠，%@ 为白鼠。"), names[dark], names[white]))
        let window = (0..<c.n).filter { c.tb.inWindow[$0] }
        guard window.count >= 10 else { return }
        func rate(_ a: Int) -> Double { Double(window.filter { fs.animals[a].detected[$0] }.count) / Double(window.count) }
        let darkRate = rate(dark), whiteRate = rate(white)
        if darkRate < 0.8 {
            r.warnings.append(String(format: L10n.tr("深色鼠（%@）只有 %.0f%% 的帧检出：深色垫料上黑鼠可能漏检。可以把“小鼠毛色”改成“两只都是深色”（标准双鼠模型）重新识别一次，对比两次结果。"),
                                     names[dark], darkRate * 100))
        }
        if whiteRate < 0.8 {
            r.warnings.append(String(format: L10n.tr("白鼠（%@）只有 %.0f%% 的帧检出：两只贴在一起时白鼠更容易漏检。请在回看中检查贴身的片段。"),
                                     names[white], whiteRate * 100))
        }
    }

    // MARK: Tracking outside the calibrated arena (RodentFlow 2.0 build 10)

    /// Flags the frames whose tracked body point lies outside the calibrated arena (ArenaBounds): per-frame
    /// columns of the frame-by-frame data, a row on the review timeline, a warning and a Methods sentence.
    /// The tracking and every measure stay exactly as computed.
    static func flagOutsideArena(_ c: AnalysisContext, into r: inout AnalysisReport) {
        guard let bounds = ArenaBounds.make(c.session.calibration, mapping: c.fs.mapping) else { return }
        let multi = c.fs.animals.count > 1
        let tolerance = AnalysisContext.num((bounds.tolerance * 10).rounded() / 10)
        r.outsideArenaTolerance = bounds.tolerance
        let window = (0..<c.n).filter { c.tb.inWindow[$0] }
        var warnings: [String] = []
        for (a, f) in c.fs.animals.enumerated() {
            let body = f.rawBody.x.count == c.n ? f.rawBody : Series2(count: c.n)
            let frames = OutsideArenaFrames.make(body, bounds: bounds)
            r.outsideArena.append(frames)
            let pre = multi ? "m\(a + 1)_" : ""
            r.frameColumns.append((pre + "outside_arena", AnalysisContext.flag(frames.flags)))
            r.frameColumns.append((pre + "outside_arena_dist_cm", frames.distance))
            let outside = window.lazy.filter { frames.flags[$0] }.count
            r.quality.outsideArenaFraction.append(window.isEmpty ? 0 : Double(outside) / Double(window.count))
            guard outside > 0 else { continue }
            let bouts = Bouts.find(frames.flags, c.tb, mergeGap: 0.5)
            let letter = AnimalColors.letter(a, animals: c.fs.animals.count)
            r.reviewTracks.append(TimelineTrack(name: multi ? letter + " · " + L10n.tr("超出标定范围") : L10n.tr("超出标定范围"),
                                                color: .error, bouts: bouts, style: .flag))
            let percent = Double(outside) / Double(window.count) * 100
            let share = percent >= 0.1 ? String(format: "%.1f", percent) : "< 0.1"
            let seconds = String(format: "%.1f", c.tb.total(frames.flags))
            if multi {
                warnings.append(String(format: L10n.tr("%@ 鼠有 %@%% 的帧（%d 段，共 %@ s）追踪位置超出标定范围（身体中心在场地边缘外 > %@ cm）。可能是把场地外的物体误认成了这只鼠，也可能是它离开了场地。请在回看中检查时间轴上标出的片段；逐帧数据的 %@ 列已标出这些帧，结果未作修改。"),
                                       letter, share, bouts.count, seconds, tolerance, pre + "outside_arena"))
            } else {
                warnings.append(String(format: L10n.tr("有 %@%% 的帧（%d 段，共 %@ s）追踪位置超出标定范围（身体中心在场地边缘外 > %@ cm）。可能是把场地外的物体误认成了动物，也可能是动物离开了场地。请在回看中检查时间轴上标出的“超出标定范围”片段；逐帧数据的 outside_arena 列已标出这些帧，结果未作修改。"),
                                       share, bouts.count, seconds, tolerance))
            }
        }
        r.warnings += warnings
        r.methods.append(String(format: L10n.tr("身体中心（未检出时用可信关键点的平均位置）超出标定场地边缘 > %@ cm 的帧标记为“超出标定范围”（逐帧数据 outside_arena 列；outside_arena_dist_cm 为超出的距离）。这些帧只作标记，轨迹和各项指标均未修改。"), tolerance))
    }

    /// Which pose model produced the data (reports of the original single-animal model are unchanged).
    static func modelNotes(_ s: Session) -> (method: String?, warning: String?) {
        let animals = s.usedInference?.animalCount ?? s.inference.animalCount
        switch s.usedModel ?? kModelName {
        case kGroupModelName:
            return (L10n.tr("多鼠数据由多鼠姿态模型 GroupPose6_960_int8 识别（YOLO26s pose，960 × 960，与单鼠模型输出相同的 6 个关键点；训练数据为 MABe22、MouseSIS、UDMT 等多鼠视频和 DooM 双鼠视频，共 20,429 张，只含深色小鼠）。"), nil)
        case kWhiteModelName:
            return (L10n.tr("白鼠数据由白鼠姿态模型 WhiteMousePose6_960_int8 识别（YOLO26n pose，960 × 960，与单鼠模型输出相同的 6 个关键点；训练标签来自 DooM 数据集 9 个实验室白鼠的追踪轨迹，颈部和身体中心按规则推算）。识别和分析流程与单鼠模型相同。"), nil)
        case kDyadBWModelName:
            return (L10n.tr("一黑一白的双鼠数据由黑白双鼠姿态模型 MousePose6DyadBW_960_int8 识别（YOLO26s pose，960 × 960，与单鼠模型输出相同的 6 个关键点；训练数据为 DooM 数据集中一黑一白和两只黑鼠的双鼠视频，每帧两只鼠均标注，标签来自追踪轨迹）。识别、身份追踪和分析流程与双鼠模型相同。"), nil)
        case kDyadModelName where animals > 1:
            return (L10n.tr("双鼠数据由双鼠专用姿态模型 MousePose6Dyad_960_int8 识别（YOLO26s pose，960 × 960，与单鼠模型输出相同的 6 个关键点；训练时每帧所有鼠均标注，并加大了贴身接触帧的比例）。"), nil)
        default:
            guard animals > 1 else { return (nil, nil) }
            return (nil, L10n.tr("这些双鼠数据由单鼠模型识别。重新识别即可使用双鼠专用模型（贴身接触时漏检和合并更少）。"))
        }
    }

    /// First Methods sentences: pose estimation and, when only the arena was tracked, the tracking region (a separate
    /// entry, so that each sentence is translated on its own in English exports).
    static func methodsPreamble(_ c: AnalysisContext) -> [String] {
        let s = c.session
        // Phrases of their own (not the "逐帧" / "每 N 帧" interface labels) so the English sentence reads naturally.
        let step = s.inference.stride > 1 ? L10n.tr("每 \(s.inference.stride) 帧取一帧") : L10n.tr("对每一帧")
        let gray = s.inference.grayscale ? L10n.tr("（先转灰度）") : ""
        var sentences = [L10n.tr("姿态由 RodentFlow（YOLO pose，6 个关键点：鼻尖、左耳、右耳、颈部、身体中心、尾根）在设备上\(step)识别\(gray)；置信度 < \(AnalysisContext.num(s.params.kpConf)) 的关键点视为缺失，≤ \(AnalysisContext.num(s.params.maxGap)) s 的缺失做线性插值，并以 \(AnalysisContext.num(s.params.smoothing)) s 滑动平均平滑。")]
        if let used = s.usedInference, used.region == .arena, let roi = used.roi {
            sentences.append(String(format: L10n.tr("只把标定场地四周外扩 %.0f%% 的矩形区域（画面的 %.0f%%）交给模型，区域外的画面不参与识别。"),
                                    used.arenaMargin * 100, roi.area * 100))
        }
        return sentences
    }

    /// Headline metrics cached in the session for lists and summary tables.
    static func cache(_ report: AnalysisReport, into s: inout Session) {
        guard s.unknownParadigm == nil else { return }
        var values: [String: Double] = [:]
        var labels: [String: String] = [:]
        var order: [String] = []
        for m in report.metrics {
            order.append(m.key)
            labels[m.key] = L10n.metricLabel(m.exportHeader, key: m.key)
            if let v = m.value, v.isFinite { values[m.key] = v }
        }
        s.metrics = values
        s.metricOrder = order
        s.metricLabels = labels
        s.metricEntries = PoseMetricEntries.entries(report)
        s.metricsVersion = metricsVersion
        s.metricSeries = report.series
        s.primaryKey = report.primary?.key ?? ""
        s.qcFlags = report.warnings.map { L10n.reportText($0) }
        s.primaryTitle = report.primary.map { L10n.metricLabel($0.title, key: $0.key) } ?? ""
        s.primaryDisplay = report.primary.map { m in
            guard m.value != nil else { return "—" }
            // A censored latency is the cut-off, not a measured time: "≥ 300.0 s" in the session lists too.
            let value = m.censored != nil ? "≥ " + m.formatted : m.formatted
            return m.unit.isEmpty ? value : "\(value) \(L10n.reportText(m.unit))"
        } ?? ""
    }
}
