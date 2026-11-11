// TSTArchive.swift — a saved multi-chamber tail suspension recording (shared by iPhone / iPad and Mac).
//
// One folder per recording:  record.json (TSTStoredRecording), measures.json (raw per-frame measures, so the
// scoring can be changed without the video), the original video, settings.json, framewise.csv,
// original_summary.csv, keyframe.csv and animal_summary.csv. The Mac keeps the folders under
//   ~/Library/Application Support/RodentDesktopNative/TSTMulti/<task>/<recording>/
// the phone under Documents/TST/<recording>/ (visible in the Files app). The phone writes exactly the same
// folder into the sync package, so the Mac imports a phone recording by copying it.
import Foundation
struct TSTAnimalMapping: Codable, Identifiable, Equatable {
    var chamber: Int
    var id: Int { chamber }
    var animalID: String = ""
    var group: String = ""
    var sex: String = ""
    // Optional keys allow old 0.7.0 TST archives to be decoded without discarding the archive.
    var sessionDate: String?
    var sessionNumber: Int?
    var excluded: Bool = false
    var exclusionReason: String = ""
    /// The user chose not to save this chamber (empty, failed, selected by mistake): no session is
    /// created for it. Optional so archives written before this field existed still decode.
    var skipped: Bool?

    var isSkipped: Bool { skipped ?? false }
}

/// Compact persisted per-chamber trace for later review in the regular Session page.
/// Only the displayed motion signal, time points and QC masks are duplicated here;
/// original pixel/shape measurements are retained in the recording-level framewise CSV.
struct TSTArchivedTrace: Codable {
    var time: [Double]
    var motion: [Double]
    var immobile: [Bool]
    var noMouse: [Bool]

    init(_ original: ChamberTrace) {
        time = original.time
        motion = original.motion.map { $0.isFinite ? $0 : 0 }
        immobile = original.immobile
        noMouse = original.noMouse
    }

    var chartTrace: ChamberTrace {
        ChamberTrace(time: time, motion: motion, pixelPercent: [], shapePercent: [], immobile: immobile,
                     noMouse: noMouse, area: [], cx: [], cy: [])
    }
}

struct TSTStoredRecording: Codable, Identifiable {
    var id: UUID
    var taskID: UUID
    var videoName: String
    var savedAt: Date
    var detector: String
    var keyFrameTime: Double
    var settings: AnalysisSettings
    var fps: Double
    var summaries: [ChamberSummary]
    var mappings: [TSTAnimalMapping]
    var videoFileName: String?
    var videoDuration: Double?
    var videoFPS: Double?
    var videoWidth: Int?
    var videoHeight: Int?
    var traces: [TSTArchivedTrace]?
    // Everything needed to open the recording again for new settings or a new analysis (0.7.1 round 6+).
    // Optional so older archives still decode; for those the chambers are read from settings.json.
    var layout: ChamberLayout?
    var scanTimes: [Double]?
    var scanDetections: [[DetBox?]]?
    var keyFrameManual: Bool?
    var keyFrameSettings: KeyFrameSettings?
    /// measures.json (raw per-frame measures) was written: scoring can be changed without decoding the video.
    var hasMeasures: Bool?

    var animalCount: Int { mappings.filter { !$0.animalID.isEmpty && !$0.excluded && !$0.isSkipped }.count }
}

/// Raw per-frame measures of every chamber, stored column-wise (measures.json). With them a saved
/// recording can be re-scored (threshold, minimum bout, measure, windows) at once, without the video.
struct TSTArchivedMeasures: Codable {
    struct Chamber: Codable {
        var time: [Double] = []
        var pixelChange: [Double] = []
        var shapeChange: [Double] = []
        var area: [Double] = []
        var cx: [Double] = []
        var cy: [Double] = []
        var boxChange: [Double] = []
        var boxPresent: [Bool] = []
        var boxBody: [Double] = []
    }
    var chambers: [Chamber]

    init(_ measures: [[FrameMeasure]]) {
        chambers = measures.map { ms in
            var c = Chamber()
            for m in ms {
                c.time.append(m.time); c.pixelChange.append(m.pixelChange); c.shapeChange.append(m.shapeChange)
                c.area.append(m.area); c.cx.append(m.cx); c.cy.append(m.cy)
                c.boxChange.append(m.boxChange); c.boxPresent.append(m.boxPresent); c.boxBody.append(m.boxBody)
            }
            return c
        }
    }

    var measures: [[FrameMeasure]]? {
        var out: [[FrameMeasure]] = []
        for c in chambers {
            let n = c.time.count
            guard [c.pixelChange.count, c.shapeChange.count, c.area.count, c.cx.count, c.cy.count,
                   c.boxChange.count, c.boxPresent.count, c.boxBody.count].allSatisfy({ $0 == n }) else { return nil }
            out.append((0..<n).map { k in
                var m = FrameMeasure(time: c.time[k], pixelChange: c.pixelChange[k], shapeChange: c.shapeChange[k],
                                     area: c.area[k], cx: c.cx[k], cy: c.cy[k])
                m.boxChange = c.boxChange[k]
                m.boxPresent = c.boxPresent[k]
                m.boxBody = c.boxBody[k]
                return m
            })
        }
        return out
    }

    /// NaN marks "unknown" in the measures; plain JSON has no NaN, so it is written as a string.
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}

/// What is needed to open a saved recording in the recording sheet again.
struct TSTReanalysisSource {
    var record: TSTStoredRecording
    var url: URL
    var layout: ChamberLayout?
    var measures: [[FrameMeasure]]?

    init?(_ record: TSTStoredRecording) {
        guard let url = TSTTaskArchive.sourceURL(record) else { return nil }
        self.record = record
        self.url = url
        layout = record.layout ?? TSTTaskArchive.legacyLayout(record)
        measures = record.hasMeasures == true ? TSTTaskArchive.loadMeasures(record) : nil
    }

    /// When each mouse was suspended (absolute video time), as used by the saved analysis.
    var onsets: [Double]? {
        record.settings.chamberOnsetSec.map { $0.map { record.settings.startSec + $0 } }
    }
}

extension ChamberLayout {
    /// The same chambers in a picture of another size (another processing width).
    func scaled(toWidth w: Int, height h: Int) -> ChamberLayout {
        guard w > 0, h > 0, imageWidth > 0, imageHeight > 0, w != imageWidth || h != imageHeight else { return self }
        let sx = Double(w) / Double(imageWidth), sy = Double(h) / Double(imageHeight)
        var l = self
        l.walls = walls.map { min(Double(w - 1), max(0, $0 * sx)) }
        l.y0 = max(0, Int((Double(y0) * sy).rounded()))
        l.y1 = min(h, max(l.y0 + 10, Int((Double(y1) * sy).rounded())))
        l.imageWidth = w
        l.imageHeight = h
        l.spacing = spacing * sx
        l.wallProfile = []
        return l
    }
}

/// Dedicated immutable run archive. All files live in application support, not in the .app bundle.
/// The canonical run ID and per-chamber mapping appear in every animal-level export.
enum TSTTaskArchive {
    /// The phone has no task tree: every recording belongs to this one task and lives in Documents/TST.
    static let phoneTaskID = UUID(uuidString: "7A57A57A-0000-4000-8000-000000000001")!

    static func taskFolder(_ task: UUID) throws -> URL {
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("RodentDesktopNative/TSTMulti", isDirectory: true)
            .appendingPathComponent(task.uuidString, isDirectory: true)
        #else
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("TST", isDirectory: true)
        #endif
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func recordFolder(_ record: TSTStoredRecording) throws -> URL {
        try taskFolder(record.taskID).appendingPathComponent(record.id.uuidString, isDirectory: true)
    }

    static var recordEncoder: JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    /// Reads a record.json; chamber summaries of older versions come back in the current definitions.
    static func decodeRecord(_ data: Data) -> TSTStoredRecording? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(TSTStoredRecording.self, from: data))?.upgradingSummaries()
    }

    /// Writes changed animal information (IDs, groups, exclusion) of a saved recording: record.json and
    /// animal_summary.csv. The analysis itself is not touched. `savedAt` becomes the time of the change
    /// (whole seconds, as stored), so the Mac sees a new revision of the recording.
    @discardableResult
    static func updateMappings(_ record: TSTStoredRecording, _ mappings: [TSTAnimalMapping]) throws -> TSTStoredRecording {
        var r = record
        r.mappings = mappings
        r.savedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let folder = try recordFolder(r)
        try recordEncoder.encode(r).write(to: folder.appendingPathComponent("record.json"), options: .atomic)
        try Data(taskCSV([r]).utf8).write(to: folder.appendingPathComponent("animal_summary.csv"), options: .atomic)
        return r
    }

    static func list(_ task: UUID) -> [TSTStoredRecording] {
        guard let folder = try? taskFolder(task),
              let dirs = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")) else { return nil }
            return decodeRecord(data)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    static func load(_ task: UUID, record id: UUID) -> TSTStoredRecording? {
        guard let folder = try? taskFolder(task) else { return nil }
        let url = folder.appendingPathComponent(id.uuidString).appendingPathComponent("record.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeRecord(data)
    }

    static func sourceURL(_ record: TSTStoredRecording) -> URL? {
        guard let name = record.videoFileName,
              let folder = try? taskFolder(record.taskID) else { return nil }
        let url = folder.appendingPathComponent(record.id.uuidString).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func loadMeasures(_ record: TSTStoredRecording) -> [[FrameMeasure]]? {
        guard let folder = try? taskFolder(record.taskID),
              let data = try? Data(contentsOf: folder.appendingPathComponent(record.id.uuidString).appendingPathComponent("measures.json")),
              let archived = try? TSTArchivedMeasures.decoder.decode(TSTArchivedMeasures.self, from: data) else { return nil }
        return archived.measures
    }

    /// Chambers of an archive written before the layout was stored, read back from its settings.json.
    static func legacyLayout(_ record: TSTStoredRecording) -> ChamberLayout? {
        struct Saved: Decodable { var walls: [Double]; var y0: Int; var y1: Int; var imageWidth: Int; var imageHeight: Int }
        guard let folder = try? taskFolder(record.taskID),
              let data = try? Data(contentsOf: folder.appendingPathComponent(record.id.uuidString).appendingPathComponent("settings.json")),
              let s = try? JSONDecoder().decode(Saved.self, from: data), s.walls.count >= 2 else { return nil }
        let n = s.walls.count - 1
        let analysed = Set(record.summaries.filter(\.analysed).map(\.chamber))
        return ChamberLayout(walls: s.walls, y0: s.y0, y1: s.y1, empty: Array(repeating: false, count: n),
                             enabled: (1...n).map { analysed.contains($0) }, imageWidth: s.imageWidth, imageHeight: s.imageHeight,
                             spacing: (s.walls[n] - s.walls[0]) / Double(n), wallProfile: [], notes: [])
    }

    static func remove(_ record: TSTStoredRecording) {
        guard let folder = try? taskFolder(record.taskID) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.id.uuidString))
    }

    /// One row per saved chamber. The columns of earlier versions keep their names (see CSVExport.columnDictionary);
    /// the columns every TST table shares (TSTSessionValues) follow, so the phone's file has the same columns,
    /// units and rounding as the Mac's tst_sessions.csv.
    static func taskCSV(_ records: [TSTStoredRecording]) -> String {
        func escaped(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func number(_ value: Double?) -> String { TSTSessionValues.number(value) }
        var rows: [(record: TSTStoredRecording, summary: ChamberSummary, mapping: TSTAnimalMapping?, values: TSTSessionValues)] = []
        for r in records.sorted(by: { $0.savedAt < $1.savedAt }) {
            for s in r.summaries where s.analysed {
                let m = r.mappings.first { $0.chamber == s.chamber }
                if m?.isSkipped == true { continue }   // not saved as a session: no animal row
                let trace = r.traces.flatMap { s.chamber >= 1 && s.chamber <= $0.count ? $0[s.chamber - 1].chartTrace : nil }
                rows.append((r, s, m, TSTSessionValues(summary: s, settings: r.settings, fps: r.fps, trace: trace,
                                                       keyFrameVideoS: r.keyFrameTime, detector: r.detector)))
            }
        }
        let minutes = rows.map { $0.values.perMinuteImmobileS.count }.max() ?? 0
        let cols = ["task_id","run_id","saved_at","video","chamber","animal_id","group","sex","excluded","exclusion_reason","analysed","immobile_total_s","immobile_pct","last_window_immobile_s","latency_s","bouts","mean_bout_s","longest_bout_s","no_mouse_pct","detector","threshold_pct","sample_fps","key_frame_s","suspended_at_video_s","immobile_early_s","immobile_primary_s","immobile_primary_pct","no_mouse_primary_pct","exclusion_suggested","immobile_test_s","immobile_test_pct","test_coverage","mobility_intensity_pct_body"]
        let written = Set(cols)
        let tailCols = TSTSessionValues.columnNames(minutes: minutes).filter { !written.contains($0) }
        var lines = [(cols + tailCols).joined(separator: ",")]
        for row in rows {
            let r = row.record, s = row.summary, m = row.mapping
            let tail = Dictionary(row.values.columns(minutes: minutes), uniquingKeysWith: { a, _ in a })
            lines.append(([
                r.taskID.uuidString, r.id.uuidString, ISO8601DateFormatter().string(from: r.savedAt),
                escaped(r.videoName), String(s.chamber), escaped(m?.animalID ?? ""), escaped(m?.group ?? ""),
                escaped(m?.sex ?? ""), m?.excluded == true ? "true" : "false",
                escaped(m?.exclusionReason ?? ""), s.analysed ? "true" : "false",
                number(s.immobileTotalSec), number(s.immobilePercent), number(s.immobileLastWindowSec),
                number(s.latencySec), String(s.bouts), number(s.meanBoutSec), number(s.longestBoutSec),
                number(s.noMousePercent), escaped(r.detector), number(r.settings.immobilityThreshold),
                number(r.fps), number(r.keyFrameTime),
                number(s.onsetSec.map { $0 + r.settings.startSec }), number(s.earlyImmobileSec), number(s.primaryImmobileSec),
                number(s.primaryImmobilePercent), number(s.primaryNoMousePercent), TSTSessionValues.trueFalse(s.exclusionSuggested),
                number(s.testImmobileSec), number(s.testImmobilePercent),
                number(s.testCoverage), number(s.mobilityIntensity)
            ] + tailCols.map { Exporter.csvField(tail[$0] ?? "") }).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    enum ArchiveError: LocalizedError {
        case missingResults, missingSource, unmapped(Int), sessionInfo(Int), exclusionReason(Int), duplicateIDs, nothingToSave
        var errorDescription: String? {
            switch self {
            case .missingResults:
                return L("Run the analysis before saving.", "请先完成分析再保存。")
            case .missingSource:
                return L("The source video is no longer available.", "原始视频已无法访问。")
            case .sessionInfo(let c):
                return String(format: L("Enter the date and session number for chamber %d.", "请填写第 %d 格的日期和实验次数。"), c)
            case .unmapped(let c):
                return String(format: L("Enter an animal ID for chamber %d.", "请填写第 %d 格的小鼠编号。"), c)
            case .exclusionReason(let c):
                return String(format: L("Enter an exclusion reason for chamber %d.", "请填写第 %d 格的排除原因。"), c)
            case .duplicateIDs:
                return L("Animal IDs must be unique within one multi-chamber recording.", "同一段多格录像中的小鼠编号不能重复。")
            case .nothingToSave:
                return L("No chamber is marked to be saved.", "没有勾选任何要保存的格子。")
            }
        }
    }
}

enum TSTMetricTitle {
    static func title(_ m: MotionMetric) -> String {
        switch m {
        case .box: return L("Pixel change in the motion box", "运动框内像素变化")
        case .shape: return L("Posture change of the outline", "轮廓姿态变化")
        case .pixel: return L("Pixel change on the outline", "轮廓内像素变化")
        }
    }
}

/// One chamber of a saved recording that was saved as an animal's session.
struct TSTSavedChamber {
    var summary: ChamberSummary
    var mapping: TSTAnimalMapping
    /// Stable id of this animal's session (the same in every revision of the recording, on the phone and the Mac).
    var recordID: UUID
}

extension TSTStoredRecording {
    /// Stable id of the session of one chamber, derived from the recording id.
    func chamberRecordID(_ chamber: Int) -> UUID {
        var b = id.uuid
        b.14 ^= 0xC7
        b.15 ^= UInt8(truncatingIfNeeded: chamber)
        return UUID(uuid: b)
    }

    /// Analysed chambers that are saved as sessions (ticked, with an animal ID), in chamber order.
    var savedChambers: [TSTSavedChamber] {
        summaries.filter(\.analysed).sorted { $0.chamber < $1.chamber }.compactMap { s in
            guard let m = mappings.first(where: { $0.chamber == s.chamber }), !m.isSkipped,
                  !m.animalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TSTSavedChamber(summary: s, mapping: m, recordID: chamberRecordID(s.chamber))
        }
    }

    /// The measures of one saved chamber (TSTSessionMetrics), keyed by the recording revision and the summary
    /// definitions (a new version gives a new key).
    func metricSummary(_ c: TSTSavedChamber) -> SessionMetricSummary {
        TSTSessionMetrics.summary(record: self, chamber: c.summary,
                                  key: "TST v\(Scorer.definitionVersion) " + id.uuidString + " #\(c.summary.chamber) "
                                      + String(Int(savedAt.timeIntervalSince1970)),
                                  videoID: c.recordID, runFolder: id.uuidString, phase: "")
    }

    /// The record with every chamber summary in the current definitions (Scorer.definitionVersion). Older
    /// summaries are recomputed from the archived traces (the scored immobile / no-mouse flag of every frame, the
    /// same flags the summaries were counted from); onset, mobility intensity and the analysed flag are kept.
    /// Reading does not rewrite the archive by itself (a later save, e.g. a mapping change or the Mac import, stores the
    /// upgraded summaries). Without traces a summary stays as saved and carries a QC flag (TSTSessionMetrics.summary).
    func upgradingSummaries() -> TSTStoredRecording {
        guard let traces, fps > 0,
              summaries.contains(where: { ($0.definitionVersion ?? 0) < Scorer.definitionVersion }) else { return self }
        var r = self
        r.summaries = summaries.map { old -> ChamberSummary in
            guard (old.definitionVersion ?? 0) < Scorer.definitionVersion,
                  old.chamber >= 1, old.chamber <= traces.count else { return old }
            let trace = traces[old.chamber - 1]
            var s = old
            Scorer.applyWindows(&s, time: trace.time, immobile: trace.immobile, noMouse: trace.noMouse,
                                onset: old.onsetSec ?? 0, settings: settings, fps: fps)
            return s
        }
        return r
    }
}

extension TSTStoredRecording {
    /// The saved result for review (charts, tables): re-scored from measures.json when it was archived
    /// (the same numbers), otherwise built from the archived traces. The saved chamber summaries are kept.
    func reviewResult() -> TSTMultiAnalysisResult? {
        guard let layout = layout ?? TSTTaskArchive.legacyLayout(self) else { return nil }
        if hasMeasures == true, let m = TSTTaskArchive.loadMeasures(self), m.count == layout.count {
            var r = Scorer.score(measures: m, layout: layout, settings: settings, fps: fps)
            r.summaries = summaries
            return r
        }
        guard let traces else { return nil }
        let rebuilt = traces.enumerated().map { item -> ChamberTrace in
            var t = item.element.chartTrace
            t.onsetSec = summaries.first { $0.chamber == item.offset + 1 }?.onsetSec ?? 0
            return t
        }
        return TSTMultiAnalysisResult(settings: settings, layout: layout, fps: fps, summaries: summaries, traces: rebuilt)
    }
}
