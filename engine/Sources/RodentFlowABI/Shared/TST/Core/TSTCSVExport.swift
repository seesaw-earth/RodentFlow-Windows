import Foundation

public enum CSVExport {

    static func f(_ x: Double?, _ digits: Int = 2) -> String {
        guard let x, x.isFinite else { return "" }
        return String(format: "%.\(digits)f", x)
    }

    /// One row per chamber of a recording. The columns of the earlier versions come first (unchanged names);
    /// then the columns every TST table shares (TSTSessionValues), so this file and the Mac's tst_sessions.csv
    /// have the same names, units and rounding (3 decimals).
    public static func summary(_ r: TSTMultiAnalysisResult, videoName: String, keyFrameSec: Double? = nil,
                               detector: String = "") -> String {
        let nMin = r.summaries.first?.perMinuteImmobileSec.count ?? 0
        let values = r.summaries.enumerated().map { i, s in
            TSTSessionValues(summary: s, settings: r.settings, fps: r.fps, trace: i < r.traces.count ? r.traces[i] : nil,
                             keyFrameVideoS: keyFrameSec, detector: detector)
        }
        let minutes = values.map(\.perMinuteImmobileS.count).max() ?? 0
        // Windows are measured from each mouse's own suspension (onset_s after the analysis start);
        // "primary" = the last part of the standard test (minutes 2–6 by default).
        let head = ["video", "chamber", "analysed", "immobile_total_s", "immobile_pct", "immobile_last\(Int(r.settings.lastWindowSec))s_s",
                    "latency_s", "bouts", "mean_bout_s", "longest_bout_s", "no_mouse_pct",
                    "suspended_at_video_s", "test_length_s", "immobile_early_s", "immobile_primary_s", "immobile_primary_pct",
                    "no_mouse_primary_pct", "exclusion_suggested", "immobile_test_s", "immobile_test_pct",
                    "test_coverage", "mobility_intensity_pct_body"]
            + (1...max(1, nMin)).map { "min\($0)_immobile_s" }
        let shared = Set(head)
        let tailHead = TSTSessionValues.columnNames(minutes: minutes).filter { !shared.contains($0) }
        var lines = [(head + tailHead).joined(separator: ",")]
        let g = { (x: Double?) in TSTSessionValues.number(x) }
        for (s, v) in zip(r.summaries, values) {
            var row = [Exporter.csvField(videoName), "\(s.chamber)", s.analysed ? "yes" : "no", g(s.immobileTotalSec), g(s.immobilePercent),
                       g(s.immobileLastWindowSec), g(s.latencySec), "\(s.bouts)", g(s.meanBoutSec),
                       g(s.longestBoutSec), g(s.noMousePercent),
                       g(s.onsetSec.map { $0 + r.settings.startSec }), g(s.testLengthSec), g(s.earlyImmobileSec), g(s.primaryImmobileSec),
                       g(s.primaryImmobilePercent), g(s.primaryNoMousePercent), TSTSessionValues.trueFalse(s.exclusionSuggested),
                       g(s.testImmobileSec), g(s.testImmobilePercent),
                       g(s.testCoverage), g(s.mobilityIntensity)]
            row += (0..<max(1, nMin)).map { $0 < s.perMinuteImmobileSec.count ? g(s.perMinuteImmobileSec[$0]) : "" }
            let tail = Dictionary(v.columns(minutes: minutes), uniquingKeysWith: { a, _ in a })
            row += tailHead.map { Exporter.csvField(tail[$0] ?? "") }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What every column of the TST tables means (phone: data_dictionary.csv next to the shared files; Mac:
    /// part of tst_data_dictionary.csv). English: exported text.
    public static let columnDictionary: [(column: String, unit: String, description: String)] = [
        ("suspended_at_video_s", "s", "when this mouse was suspended, in video time; every measure is timed from here"),
        ("key_frame_video_s", "s", "first moment every selected chamber had a mouse (or the start set by hand)"),
        ("analysis_start_video_s / analysis_end_video_s", "s", "part of the video that was analysed"),
        ("recorded_after_suspension_s", "s", "video available after this mouse's suspension"),
        ("test_length_s", "s", "standard test length (default 360 s = 6 min)"),
        ("primary_window_start_s / primary_window_end_s", "s from suspension", "primary window (default 120-360 s = minutes 2-6)"),
        ("test_coverage_pct", "%", "share of the standard test that was recorded; < 98 % means the test is incomplete"),
        ("immobile_primary_s", "s", "PRIMARY MEASURE: immobility in the primary window"),
        ("immobile_primary_pct", "%", "immobility as % of every recorded frame of the primary window: frames without the mouse count in the denominator, not as immobility (see no_mouse_primary_pct). Changed with TST summary definitions 2 (RodentFlow 2.1 after iOS build 22 / Mac build 18); earlier versions divided by the frames with the mouse visible"),
        ("no_mouse_primary_pct", "%", "frames without the mouse (climbing the tail, fallen, out of view) as % of the recorded primary window"),
        ("exclusion_suggested", "true/false", "true = no_mouse_primary_pct or no_mouse_test_pct is above exclusion_no_mouse_threshold_pct: watch the video and decide. A suggestion only; the session is not excluded automatically"),
        ("immobile_early_s", "s", "immobility before the primary window (default minutes 0-2)"),
        ("immobile_test_s / immobile_test_pct", "s / %", "immobility in the whole standard test (default minutes 0-6); % of every recorded frame of the test as for immobile_primary_pct (changed with definitions 2)"),
        ("no_mouse_test_pct", "%", "frames without the mouse as % of the recorded standard test"),
        ("latency_s", "s", "time from suspension to the first immobility bout that starts within the standard test; without one = the end of the observed test (test_length_s when it was fully recorded) and became_immobile = false, i.e. censored (use survival methods). Changed with definitions 2; earlier versions searched the whole recording and left the value empty without a bout"),
        ("became_immobile", "true/false", "an immobility bout started within the standard test (event indicator for latency_s)"),
        ("bouts_test / mean_bout_s / longest_bout_s", "count / s / s", "immobility bouts within the standard test"),
        ("mobility_intensity_pct_body", "% body", "mean motion while mobile within the test (struggling vigour)"),
        ("mean_motion_test_pct_body / median_motion_test_pct_body", "% body", "mean / median of the scored motion over the test frames with the mouse visible"),
        ("immobile_min<k>_s", "s", "immobility in minute k after suspension (0-60 s; empty = minute not fully recorded)"),
        ("immobile_whole_recording_s / _pct", "s / %", "immobility from suspension to the end of the analysed video; % of the frames with the mouse visible (not comparable between videos of different length)"),
        ("no_mouse_pct", "%", "QC: frames without the mouse from suspension to the end of the analysed video (includes frames after the mouse was taken down)"),
        ("qc_flags", "", "quality warnings: test incomplete, exclusion suggested, older timing"),
        ("measure", "", "motion measure: box = pixel change in the motion box after swing alignment; shape; pixel"),
        ("immobility_threshold_pct", "% body per analysed frame", "motion below this is immobile. It applies to the change between consecutive ANALYSED frames, so it depends on sample_fps: compare or reuse thresholds only at the same sample_fps"),
        ("min_bout_s", "s", "shorter immobile runs are not counted"),
        ("smoothing_s / sample_fps", "s / fps", "median smoothing of the motion signal; frames analysed per second (the video rate divided by a whole number, e.g. 12-16.7 fps for the 15-fps target)"),
        ("exclusion_no_mouse_threshold_pct", "%", "no-mouse % above which exclusion is suggested (setting, default 10 %)"),
        ("detector / refined_outline", "", "mouse detector of the key-frame scan; outline refinement of the posture measures"),
        ("immobile_total_s / immobile_pct / last_window_immobile_s / bouts / threshold_pct / test_coverage / key_frame_s", "",
         "earlier names kept in the phone's animal_summary.csv for existing scripts: = immobile_whole_recording_s / immobile_whole_recording_pct / immobile_primary_s / bouts_test / immobility_threshold_pct / test_coverage_pct as a 0-1 fraction / key_frame_video_s"),
        ("immobile_last<N>s_s / min<k>_immobile_s", "s",
         "earlier names kept in original_summary.csv: = immobile_primary_s; immobility in minute k of the whole recording after suspension (immobile_min<k>_s: standard test, complete minutes only)"),
        ("(all tables)", "", "the phone and the Mac write these columns with the same names, units and rounding (3 decimals)"),
    ]

    public static func framewise(_ r: TSTMultiAnalysisResult) -> String {
        var lines = ["chamber,time_s,motion_smoothed_pct,pixel_change_pct,shape_change_pct,immobile,no_mouse,area_px,cx,cy,box_change_pct,box_mouse_present"]
        for (ci, tr) in r.traces.enumerated() {
            for k in tr.time.indices {
                lines.append([
                    "\(ci + 1)", f(tr.time[k], 3), f(tr.motion[k], 3), f(tr.pixelPercent[k], 3),
                    f(tr.shapePercent[k], 3), tr.immobile[k] ? "1" : "0", tr.noMouse[k] ? "1" : "0",
                    f(tr.area[k], 0), f(tr.cx[k], 1), f(tr.cy[k], 1),
                    k < tr.boxPercent.count ? f(tr.boxPercent[k], 3) : "",
                    k < tr.boxPresent.count ? (tr.boxPresent[k] ? "1" : "0") : "",
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Key-frame scan: when each mouse first appeared stably. A plain table (header + one row per chamber) that
    /// pandas / R read as it is; the detector, key frame and analysis window are in settings.json ("keyFrame",
    /// `KeyFrameInfo`). Archives of earlier versions start with four "#" lines holding the same facts.
    public static func keyFrame(_ k: KeyFrameResult) -> String {
        var lines = ["chamber,selected,hung_at_s,presence_pct"]
        for c in 0..<k.selected.count {
            let pres = k.presence[c]
            let pct = pres.isEmpty ? 0 : 100 * Double(pres.filter { $0 }.count) / Double(pres.count)
            lines.append("\(c + 1),\(k.selected[c] ? "yes" : "no"),\(f(k.hungAt[c])),\(f(pct, 1))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Key-frame facts of a recording, stored in settings.json under "keyFrame" (earlier versions wrote them as
    /// "#" comment lines at the top of keyframe.csv). Times are video seconds; nil = not found.
    public struct KeyFrameInfo: Codable, Equatable {
        public var detector: String
        /// Key frame found by the scan: first moment every selected chamber had a mouse, plus the settle delay
        /// (a start set by hand shows in analysis_start_s).
        public var keyFrameSec: Double?
        public var analysisStartSec: Double
        public var analysisDurationSec: Double
        /// First time after the key frame at which a mouse was missing again.
        public var allPresentEndSec: Double?

        enum CodingKeys: String, CodingKey {
            case detector
            case keyFrameSec = "key_frame_s"
            case analysisStartSec = "analysis_start_s"
            case analysisDurationSec = "analysis_duration_s"
            case allPresentEndSec = "all_present_end_s"
        }

        public init(_ k: KeyFrameResult, analysisStart: Double, analysisDuration: Double, detector: String) {
            // Plain JSON has no NaN / infinity (one would make the whole file fail to encode).
            func finite(_ x: Double?) -> Double? { x.flatMap { $0.isFinite ? $0 : nil } }
            self.detector = detector
            keyFrameSec = finite(k.keyTime)
            analysisStartSec = finite(analysisStart) ?? 0
            analysisDurationSec = finite(analysisDuration) ?? 0
            allPresentEndSec = finite(k.allPresentEnd)
        }
    }

    public static func settingsJSON(_ r: TSTMultiAnalysisResult, keyFrame: KeyFrameInfo? = nil) -> String {
        struct Out: Codable { var settings: AnalysisSettings; var walls: [Double]; var y0: Int; var y1: Int
                              var imageWidth: Int; var imageHeight: Int; var fps: Double; var notes: [String]
                              var keyFrame: KeyFrameInfo? }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let o = Out(settings: r.settings, walls: r.layout.walls, y0: r.layout.y0, y1: r.layout.y1,
                    imageWidth: r.layout.imageWidth, imageHeight: r.layout.imageHeight, fps: r.fps, notes: r.layout.notes,
                    keyFrame: keyFrame)
        return (try? enc.encode(o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// One chamber (one animal's session) as every TST table writes it: the phone's animal_summary.csv and
/// original_summary.csv and the Mac's tst_sessions.csv / tst_export.json. Computed here once, so a column has
/// the same name, unit and rounding (3 decimals) on both platforms.
struct TSTSessionValues {
    var summary: ChamberSummary
    var settings: AnalysisSettings
    var fps: Double
    var keyFrameVideoS: Double?
    var detector: String
    var suspendedAtVideoS: Double
    var recordedAfterSuspensionS: Double
    var testLengthS: Double
    var primaryWindowStartS: Double
    /// Minutes of the standard test after suspension; nil = that minute was not fully recorded.
    var perMinuteImmobileS: [Double?]
    /// Mean / median of the scored motion over the test frames with the mouse visible.
    var meanMotionTestPctBody: Double?
    var medianMotionTestPctBody: Double?
    var qcFlags: [String]

    var analysisStartVideoS: Double { settings.startSec }
    var analysisEndVideoS: Double { settings.startSec + settings.durationSec }
    var primaryWindowEndS: Double { testLengthS }
    var testCoveragePct: Double? { summary.testCoverage.map { 100 * $0 } }

    init(summary s: ChamberSummary, settings: AnalysisSettings, fps: Double, trace: ChamberTrace?,
         keyFrameVideoS: Double? = nil, detector: String = "") {
        summary = s
        self.settings = settings
        self.fps = fps
        self.keyFrameVideoS = keyFrameVideoS
        self.detector = detector
        let onset = s.onsetSec ?? 0
        let test = s.testLengthSec ?? settings.standardTestSec
        let recorded = max(0, settings.durationSec - onset)
        suspendedAtVideoS = settings.startSec + onset
        recordedAfterSuspensionS = recorded
        testLengthS = test
        primaryWindowStartS = s.primaryStartSec ?? max(0, test - settings.lastWindowSec)
        let testMinutes = Int((test / 60).rounded(.down))
        perMinuteImmobileS = (0..<testMinutes).map { m in
            guard m < s.perMinuteImmobileSec.count, Double(m + 1) * 60 <= recorded + 0.5 else { return nil }
            return s.perMinuteImmobileSec[m]
        }
        var motion: [Double] = []
        if let tr = trace {
            for k in tr.time.indices where k < tr.motion.count && k < tr.noMouse.count && !tr.noMouse[k] {
                let rel = tr.time[k] - onset
                if rel >= 0, rel < test, tr.motion[k].isFinite { motion.append(tr.motion[k]) }
            }
        }
        meanMotionTestPctBody = motion.isEmpty ? nil : motion.reduce(0, +) / Double(motion.count)
        medianMotionTestPctBody = motion.isEmpty ? nil : motion.sorted()[motion.count / 2]
        var flags: [String] = []
        if s.analysed, let c = s.testCoverage, c < 0.98 { flags.append(String(format: "test incomplete: %.0f%% recorded", 100 * c)) }
        if !s.analysed {
            // A chamber that was not analysed (original_summary.csv lists every chamber): no measures, no flags.
        } else if s.exclusionSuggested == true {
            flags.append(String(format: "exclusion suggested: no mouse in %.1f%% of the primary window and %.1f%% of the test (threshold %g%%)",
                                s.primaryNoMousePercent ?? 0, s.testNoMousePercent ?? 0, settings.exclusionNoMousePct))
        } else if s.exclusionSuggested == nil, s.noMousePercent > settings.exclusionNoMousePct {
            // A summary that could not be brought to the current definitions (archive without traces).
            flags.append(String(format: "no-mouse frames > %g%%", settings.exclusionNoMousePct))
        }
        if s.onsetSec == nil { flags.append("timed from the key frame (older analysis)") }
        qcFlags = flags
    }

    /// Every exported number: 3 decimals; empty = not available.
    static func number(_ v: Double?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(digits)f", v)
    }

    /// true / false, like most yes-or-no columns of the TST tables (animal_summary excluded / analysed, Mac included,
    /// refined_outline); original_summary.csv keeps its earlier yes / no `analysed` column unchanged.
    static func trueFalse(_ v: Bool?) -> String { v.map { $0 ? "true" : "false" } ?? "" }

    /// The shared columns in their order; `minutes` = number of immobile_min<k>_s columns of the table.
    static func columnNames(minutes: Int) -> [String] {
        ["suspended_at_video_s", "key_frame_video_s", "analysis_start_video_s", "analysis_end_video_s",
         "recorded_after_suspension_s", "test_length_s", "primary_window_start_s", "primary_window_end_s",
         "test_coverage_pct", "immobile_primary_s", "immobile_primary_pct", "no_mouse_primary_pct", "exclusion_suggested",
         "immobile_early_s", "immobile_test_s", "immobile_test_pct", "no_mouse_test_pct", "latency_s", "became_immobile",
         "bouts_test", "mean_bout_s", "longest_bout_s", "mobility_intensity_pct_body", "mean_motion_test_pct_body",
         "median_motion_test_pct_body"]
            + (0..<minutes).map { "immobile_min\($0 + 1)_s" }
            + ["immobile_whole_recording_s", "immobile_whole_recording_pct", "no_mouse_pct", "qc_flags", "measure",
               "immobility_threshold_pct", "min_bout_s", "smoothing_s", "sample_fps", "exclusion_no_mouse_threshold_pct",
               "detector", "refined_outline"]
    }

    /// (column, value) of every shared column, in the order of `columnNames` (values not CSV-escaped).
    func columns(minutes: Int) -> [(String, String)] {
        let s = summary
        let n: (Double?) -> String = { Self.number($0) }
        var values: [String] = [
            n(suspendedAtVideoS), n(keyFrameVideoS), n(analysisStartVideoS), n(analysisEndVideoS),
            n(recordedAfterSuspensionS), n(testLengthS), n(primaryWindowStartS), n(primaryWindowEndS),
            n(testCoveragePct), n(s.primaryImmobileSec ?? s.immobileLastWindowSec), n(s.primaryImmobilePercent),
            n(s.primaryNoMousePercent), Self.trueFalse(s.exclusionSuggested),
            n(s.earlyImmobileSec), n(s.testImmobileSec), n(s.testImmobilePercent), n(s.testNoMousePercent),
            n(s.latencySec), Self.trueFalse(s.becameImmobile), String(s.bouts), n(s.meanBoutSec), n(s.longestBoutSec),
            n(s.mobilityIntensity), n(meanMotionTestPctBody), n(medianMotionTestPctBody),
        ]
        values += (0..<minutes).map { $0 < perMinuteImmobileS.count ? n(perMinuteImmobileS[$0]) : "" }
        values += [n(s.immobileTotalSec), n(s.immobilePercent), n(s.noMousePercent), qcFlags.joined(separator: "; "),
                   settings.metric.rawValue, n(settings.immobilityThreshold), n(settings.minBoutSec), n(settings.smoothSec),
                   n(fps), n(settings.exclusionNoMousePct), detector, settings.useRefinedOutline ? "true" : "false"]
        return Array(zip(Self.columnNames(minutes: minutes), values))
    }
}
