// AnalysisRun.swift — pose.mpt + a session → the task's metrics and the export files.
//
// This is the second half of a RodentFlow analysis, and it is shared code end to end: the host app
// supplies the `Session` (task, calibration, parameters) as JSON and the path of the pose.mpt the
// tracking run wrote; everything below is the same `Kinematics.build` → `Analyzer.run` → `Exporter`
// path the Mac and the phone take, so the numbers do not depend on the platform.
//
// Files written into `outDir` (the names the apps use):
//   report.json                  Exporter.reportJSON — metrics, warnings, blocks, Methods
//   rodentpose_frame_metrics.csv Exporter.frameCSV — one row per analysed frame
//   metrics.csv                  Exporter.metricsCSV — one row per metric
//   summary.txt                  Exporter.textSummary
//   segments.csv                 BehaviorSegments.csv — one row per behaviour segment
//
// With `includeReport` the reply also carries the whole report for the host's result page
// (ReportView.swift): headline measure and its scale, every figure block with its zones, heat cells
// mapped onto the frame and CSV, the quality summary and the Methods sentences. Recomputing with a
// changed calibration or parameters needs only this call, not a new tracking run, as on the Mac.

import Foundation

enum AnalysisRun {
    struct Request: Decodable {
        /// A `Session` as the apps encode it (paradigm, calibration, params, inference, video …).
        var session: Session
        /// pose.mpt written by a tracking run.
        var poseFile: String
        /// Folder for the export files; created if missing.
        var outDir: String
        /// Companion measurements some tasks take from another session (e.g. the home-cage control
        /// of novelty-suppressed feeding). Keys as the analyzers expect them.
        var companion: [String: Double]?
        /// Marble readings for marble burying (`MarbleSampler` on the other platforms); nil otherwise.
        var marbles: MarbleSamples?
        /// Write the export files, or only return the metrics.
        var writeExports: Bool?
        /// Also return the whole report for the result page (ReportView.json).
        var includeReport: Bool?
        /// "english": the report's texts in English (figures saved to files, as on the other
        /// platforms). Anything else: the interface language set with rf_set_language.
        var reportLanguage: String?
    }

    static func run(_ r: Request) throws -> [String: Any] {
        let poseURL = URL(fileURLWithPath: r.poseFile)
        guard FileManager.default.fileExists(atPath: poseURL.path) else {
            throw RFError.badArgument("No pose file at " + r.poseFile)
        }
        let track = try PoseTrack.decode(try Data(contentsOf: poseURL))
        guard track.count > 0 else { throw RFError.failed("The pose file has no frames") }

        var session = r.session
        // The track is the authority on what was actually analysed, as in PoseResults.session.
        session.video.fps = track.fps
        session.video.width = track.frameWidth
        session.video.height = track.frameHeight
        session.video.duration = max(track.processedUntil, track.time.last ?? 0)
        var used = session.usedInference ?? session.inference
        used.animalCount = track.animalCount
        used.stride = track.frameStride
        let model = session.usedModel
            ?? (track.animalCount > 2 ? kGroupModelName : (track.animalCount > 1 ? kDyadModelName : kModelName))
        used.coat = (PoseModels.coat(of: model) ?? used.coat).valid(for: used.animalCount)
        session.inference = used
        session.usedInference = used
        session.usedModel = model

        guard session.paradigm.isGroup ? track.animalCount > 2 : session.paradigm.animalCount == track.animalCount else {
            throw RFError.failed("This task expects \(session.paradigm.animalCount) animal(s); the pose file has \(track.animalCount).")
        }

        let features = Kinematics.build(track: track, session: session)
        let report = Analyzer.run(session: session, features: features,
                                  companion: r.companion ?? [:], marbles: r.marbles)

        var written: [String] = []
        if r.writeExports ?? true {
            let out = URL(fileURLWithPath: r.outDir, isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            func write(_ data: Data, _ name: String) throws {
                try data.write(to: out.appendingPathComponent(name), options: .atomic)
                written.append(name)
            }
            try write(try Exporter.reportJSON(session: session, report: report), "report.json")
            try write(Exporter.frameCSV(session: session, track: track, features: features, report: report),
                      "rodentpose_frame_metrics.csv")
            try write(Data(Exporter.metricsCSV(session: session, report: report).utf8), "metrics.csv")
            try write(Data(Exporter.textSummary(session: session, report: report).utf8), "summary.txt")

            let info = BehaviorSegments.info(session, windowStart: features.tb.windowStartTime)
            let rows = BehaviorSegments.rows(report: report, manual: ManualAnnotations(),
                                             frameIndex: features.frameIndex, fps: track.fps)
            try write(Data(BehaviorSegments.csv(rows, info: info).utf8), "segments.csv")
        }

        var result: [String: Any] = [
            "outDir": r.outDir,
            "written": written,
            "paradigm": session.paradigm.rawValue,
            "task": session.paradigm.englishName,
            "model": model,
            "animalCount": track.animalCount,
            "frames": track.count,
            "fps": RFJSON.number(track.fps),
            "windowStart": RFJSON.number(features.tb.windowStartTime),
            "metrics": report.metrics.map { m -> [String: Any] in
                var d: [String: Any] = ["key": m.key, "title": m.title, "unit": m.unit,
                                        "decimals": m.decimals, "highlight": m.highlight]
                d["value"] = m.value.map { RFJSON.number($0) } ?? NSNull()
                if let c = m.censored { d["censored"] = c }
                if let t = m.valueText { d["valueText"] = t }
                return d
            },
            "warnings": report.warnings,
            "notes": report.notes,
        ]
        if r.includeReport ?? false {
            result["report"] = ReportView.json(report, session: session, english: r.reportLanguage == "english", track: track)
            // The session's summary as the Mac saves it (SessionMetrics.summary): what the group comparison of the
            // task reads (rf_group_analysis). The host keeps it with the session and sends it back unchanged.
            var summary = SessionMetricSummary(cacheKey: "", analyzer: PoseMetricEntries.analyzerVersion, computedAt: Date(),
                                               videoID: UUID(), runFolder: "", phase: session.phase,
                                               primaryKey: report.primary?.key ?? "", metrics: PoseMetricEntries.entries(report))
            summary.qcFlags = report.warnings.map { L10n.reportText($0) }
            summary.trackedFraction = report.quality.detectionRate
            summary.model = report.model.isEmpty ? nil : report.model
            summary.series = report.series
            if let tree = try? RFCoding.tree(summary) { result["summary"] = tree }
        }
        return result
    }

    // MARK: Task catalogue

    /// Every task the engine can analyse, for the host app's task list. Built from `Paradigm` so the
    /// Windows app never carries its own copy of the catalogue.
    static func paradigms() -> [String: Any] {
        [
            "models": PoseModels.all,
            "keypoints": kKeypointNames,
            "maxGroupAnimals": kGroupMaxAnimals,
            "defaultGroupAnimals": kGroupDefaultAnimals,
            "analysisMinScore": Double(kAnalysisMinScore),
            // What each task's setup needs (SetupABI.paradigmInfo).
            "paradigms": Paradigm.allCases.map { SetupABI.paradigmInfo($0) },
            "arenaKinds": ArenaKind.allCases.map { SetupABI.arenaKindInfo($0) },
        ]
    }
}
