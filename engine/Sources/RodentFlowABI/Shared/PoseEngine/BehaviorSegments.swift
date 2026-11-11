// BehaviorSegments.swift — behaviour bouts ("time segments") of an analysis as one row per bout, manual
// scoring in the review, agreement of manual and automatic scoring, and the DeepLabCut keypoint layout.
// Shared by the iPhone / iPad and Mac apps (RodentFlow 2.0: iOS build 14, Mac build 13).
//
// Time base: video seconds (the pose data's own time on both platforms). Segments are the bouts the review
// timeline shows; where an analyzer merges very short gaps for the timeline, the summed duration can differ
// slightly from a measure computed frame by frame (the frame-by-frame CSV has the exact flags).

import Foundation

// MARK: - Manual scoring

struct ManualSegment: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Behaviour label as shown (an automatic behaviour's name, or the researcher's own label).
    var behavior: String
    /// Stable key: the automatic behaviour's key when picked from the list, else derived from the label.
    var key: String
    /// "" (one animal / both), "A" or "B".
    var animal: String = ""
    var start: Double
    var end: Double
    var note: String = ""

    var duration: Double { max(0, end - start) }

    init(behavior: String, key: String, animal: String = "", start: Double, end: Double) {
        self.behavior = behavior
        self.key = key
        self.animal = animal
        self.start = min(start, end)
        self.end = max(start, end)
    }

    enum CodingKeys: String, CodingKey { case id, behavior, key, animal, start, end, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.v(.id, UUID())
        behavior = c.v(.behavior, "")
        key = c.v(.key, BehaviorSegments.slug(behavior))
        animal = c.v(.animal, "")
        start = c.v(.start, 0)
        end = c.v(.end, start)
        note = c.v(.note, "")
    }
}

/// Manual scoring of one session, saved next to its pose data (`manual_annotations.json`).
struct ManualAnnotations: Codable, Equatable {
    static let fileName = "manual_annotations.json"

    var version = 1
    var annotator = ""
    var segments: [ManualSegment] = []
    /// Part of the video that was scored (nil = the analysis window). Agreement is computed inside it.
    var scoredStart: Double?
    var scoredEnd: Double?
    var updatedAt = Date()

    init() {}

    enum CodingKeys: String, CodingKey { case version, annotator, segments, scoredStart, scoredEnd, updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.v(.version, 1)
        annotator = c.v(.annotator, "")
        segments = c.v(.segments, [])
        scoredStart = c.v(.scoredStart, nil as Double?)
        scoredEnd = c.v(.scoredEnd, nil as Double?)
        updatedAt = c.v(.updatedAt, Date())
    }

    var isEmpty: Bool { segments.isEmpty }

    /// Labels used so far, in order of first use.
    var labels: [String] {
        var seen = Set<String>()
        return segments.map(\.behavior).filter { seen.insert($0).inserted }
    }

    static func load(from folder: URL) -> ManualAnnotations {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let a = try? JSONDecoder.iso.decode(ManualAnnotations.self, from: data) else { return ManualAnnotations() }
        return a
    }

    func save(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.fileName)
        if segments.isEmpty && scoredStart == nil && scoredEnd == nil {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var copy = self
        copy.updatedAt = Date()
        try JSONEncoder.isoPretty.encode(copy).write(to: url, options: .atomic)
    }

    /// Manual segments as review-timeline rows (one row per label and animal).
    func timelineTracks() -> [TimelineTrack] {
        var order: [String] = []
        var bouts: [String: [Bout]] = [:]
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let name = "✎ " + (s.animal.isEmpty ? "" : s.animal + " · ") + s.behavior
            if bouts[name] == nil { order.append(name) }
            bouts[name, default: []].append(Bout(start: s.start, end: max(s.end, s.start + 0.04), i0: 0, i1: 0))
        }
        return order.map { TimelineTrack(name: $0, color: .series3, bouts: bouts[$0] ?? []) }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var isoPretty: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - Agreement of manual and automatic scoring

struct ScoringAgreement: Identifiable {
    var key: String
    var behavior: String
    var animal: String
    var manualTime: Double
    var autoTime: Double
    var overlap: Double
    var manualBouts: Int
    var autoBouts: Int
    var matchedBouts: Int
    /// Mean |onset difference| of matched bouts (s).
    var onsetError: Double?
    var scoredFrom: Double
    var scoredTo: Double

    var id: String { animal + "|" + key }
    /// Share of the automatic time that was also scored by hand.
    var precision: Double? { autoTime > 0 ? overlap / autoTime : nil }
    /// Share of the manual time that the automatic scoring found.
    var recall: Double? { manualTime > 0 ? overlap / manualTime : nil }
    var f1: Double? {
        guard let p = precision, let r = recall, p + r > 0 else { return nil }
        return 2 * p * r / (p + r)
    }
}

enum BehaviorSegments {
    /// Stable key from an English name ("Attack", "A · Outside the calibrated arena" → "attack", "outside_the_calibrated_arena").
    static func slug(_ name: String) -> String {
        var s = name
        if s.hasPrefix("✎ ") { s.removeFirst(2) }
        if s.count > 4, s.hasPrefix("A · ") || s.hasPrefix("B · ") { s.removeFirst(4) }
        var out = ""
        var lastUnderscore = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastUnderscore = false
            } else if !lastUnderscore && !out.isEmpty {
                out.append("_")
                lastUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "behavior" : out
    }

    /// Key and English name of an automatic timeline row, and the animal it belongs to.
    static func identify(_ track: TimelineTrack) -> (key: String, name: String, animal: String) {
        var name = L10n.english(track.name)
        var animal = ""
        if let range = name.range(of: "^(A|B|[0-9]+) · ", options: .regularExpression), name.count > name.distance(from: range.lowerBound, to: range.upperBound) {
            animal = String(name[range]).components(separatedBy: " ").first ?? ""
            name.removeSubrange(range)
        }
        if L10n.hasHan(name) { name = slug(track.name) }
        return (slug(name), name, animal)
    }

    /// Automatic rows that can be scored by hand (behaviours, not review flags).
    static func scorableTracks(_ tracks: [TimelineTrack]) -> [TimelineTrack] {
        tracks.filter { $0.style == .behavior && !$0.name.hasPrefix("✎ ") }
    }

    // MARK: Intervals

    private static func merged(_ iv: [(Double, Double)]) -> [(Double, Double)] {
        let s = iv.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var out: [(Double, Double)] = []
        for x in s {
            if let last = out.last, x.0 <= last.1 { out[out.count - 1].1 = max(last.1, x.1) } else { out.append(x) }
        }
        return out
    }

    private static func clipped(_ iv: [(Double, Double)], _ a: Double, _ b: Double) -> [(Double, Double)] {
        iv.compactMap { x in
            let s = max(x.0, a), e = min(x.1, b)
            return e > s ? (s, e) : nil
        }
    }

    private static func length(_ iv: [(Double, Double)]) -> Double { iv.reduce(0) { $0 + ($1.1 - $1.0) } }

    private static func intersection(_ a: [(Double, Double)], _ b: [(Double, Double)]) -> Double {
        var i = 0, j = 0, total = 0.0
        while i < a.count && j < b.count {
            let s = max(a[i].0, b[j].0), e = min(a[i].1, b[j].1)
            if e > s { total += e - s }
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return total
    }

    /// Manual vs automatic scoring for every manual behaviour whose key matches an automatic row.
    static func agreement(manual: ManualAnnotations, tracks: [TimelineTrack], window: (Double, Double)) -> [ScoringAgreement] {
        let from = manual.scoredStart ?? window.0
        let to = manual.scoredEnd ?? window.1
        guard to > from else { return [] }
        var auto: [String: (name: String, iv: [(Double, Double)])] = [:]
        for t in scorableTracks(tracks) {
            let id = identify(t)
            let k = id.animal + "|" + id.key
            auto[k, default: (id.name, [])].iv += t.bouts.map { ($0.start, $0.end) }
        }
        var groups: [String: [ManualSegment]] = [:]
        for s in manual.segments { groups[s.animal + "|" + s.key, default: []].append(s) }
        var out: [ScoringAgreement] = []
        for (k, segs) in groups.sorted(by: { $0.key < $1.key }) {
            guard let a = auto[k] else { continue }
            let m = merged(clipped(segs.map { ($0.start, $0.end) }, from, to))
            let x = merged(clipped(a.iv, from, to))
            var errors: [Double] = []
            for mb in m {
                // The automatic bout that overlaps this manual bout most.
                var best: (Double, Double)?
                var bestOverlap = 0.0
                for ab in x {
                    let o = min(mb.1, ab.1) - max(mb.0, ab.0)
                    if o > bestOverlap { bestOverlap = o; best = ab }
                }
                if let best { errors.append(abs(best.0 - mb.0)) }
            }
            let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            out.append(ScoringAgreement(key: parts.count > 1 ? parts[1] : k, behavior: a.name, animal: parts.first ?? "",
                                        manualTime: length(m), autoTime: length(x), overlap: intersection(m, x),
                                        manualBouts: m.count, autoBouts: x.count, matchedBouts: errors.count,
                                        onsetError: errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count),
                                        scoredFrom: from, scoredTo: to))
        }
        return out
    }

    // MARK: Segment table

    struct Row {
        var animal: String
        var key: String
        var name: String
        var category: String   // behavior · qc · epoch · manual
        var source: String     // auto · manual
        var start: Double
        var end: Double
        var startFrame: Int?
        var endFrame: Int?
        var attributes: String = ""
    }

    /// All segments of an analysis: behaviours and review flags of the report, its epochs (CS, stimuli) and
    /// the manual scoring. `frameIndex` maps pose samples to video frames (nil: from fps).
    static func rows(report: AnalysisReport, manual: ManualAnnotations, frameIndex: [Int]?, fps: Double) -> [Row] {
        func frame(_ i: Int, _ t: Double) -> Int? {
            if let fi = frameIndex, i >= 0, i < fi.count { return fi[i] }
            return fps > 0 ? Int((t * fps).rounded()) : nil
        }
        var out: [Row] = []
        for t in report.reviewTracks {
            let id = identify(t)
            let category = t.style == .flag ? "qc" : "behavior"
            for b in t.bouts {
                out.append(Row(animal: id.animal, key: id.key, name: id.name, category: category, source: "auto",
                               start: b.start, end: b.end, startFrame: frame(b.i0, b.start), endFrame: frame(b.i1, b.end)))
            }
        }
        for e in report.reviewEpochs {
            let name = L10n.english(e.name)
            out.append(Row(animal: "", key: slug(name), name: L10n.hasHan(name) ? slug(e.name) : name, category: "epoch", source: "auto",
                           start: e.start, end: e.end,
                           startFrame: fps > 0 ? Int((e.start * fps).rounded()) : nil, endFrame: fps > 0 ? Int((e.end * fps).rounded()) : nil))
        }
        for s in manual.segments {
            out.append(Row(animal: s.animal, key: s.key, name: s.behavior, category: "manual", source: "manual",
                           start: s.start, end: s.end,
                           startFrame: fps > 0 ? Int((s.start * fps).rounded()) : nil, endFrame: fps > 0 ? Int((s.end * fps).rounded()) : nil,
                           attributes: s.note))
        }
        return out.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }

    struct SessionInfo {
        var sessionID: String
        var subject: String
        var group: String
        var sex: String
        var phase: String
        var day: Int?
        var trial: Int?
        var task: String
        var video: String
        var windowStart: Double
        var fps: Double
        /// Recording start written in the video file (nil when the file has none), to line up device logs.
        var recordingStart: Date? = nil
    }

    static func info(_ s: Session, windowStart: Double) -> SessionInfo {
        SessionInfo(sessionID: s.id.uuidString, subject: s.subjectID, group: s.group, sex: s.sex, phase: s.phase,
                    day: s.day, trial: s.trial, task: s.studyAssay?.rawValue ?? s.paradigm.rawValue,
                    video: s.videoName, windowStart: windowStart, fps: s.video.fps, recordingStart: s.video.creationDate)
    }

    /// ISO 8601 recording start (UTC), "" when unknown.
    static func isoTime(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static let header = ["session_id", "subject_id", "group", "sex", "phase", "day", "trial", "task", "animal",
                         "behavior_key", "behavior", "category", "source", "start_s", "end_s", "duration_s",
                         "start_from_window_s", "start_frame", "end_frame", "attributes"]

    static func csv(_ rows: [Row], info i: SessionInfo, includeHeader: Bool = true) -> String {
        var lines: [String] = includeHeader ? [header.joined(separator: ",")] : []
        func q(_ s: String) -> String { Exporter.csvField(s) }
        func n(_ v: Double, _ d: Int = 3) -> String { v.isFinite ? String(format: "%.\(d)f", v) : "" }
        // Built in typed steps: one long heterogeneous literal with `map(String.init) ?? ""` makes the
        // type checker time out ("unable to type-check this expression in reasonable time").
        let day: String = i.day.map { String($0) } ?? ""
        let trial: String = i.trial.map { String($0) } ?? ""
        let sessionFields: [String] = [q(i.sessionID), q(i.subject), q(i.group), q(i.sex), q(i.phase), day, trial, q(i.task)]
        for r in rows {
            let startFrame: String = r.startFrame.map { String($0) } ?? ""
            let endFrame: String = r.endFrame.map { String($0) } ?? ""
            let what: [String] = [q(r.animal), q(r.key), q(r.name), r.category, r.source]
            let times: [String] = [n(r.start), n(r.end), n(r.end - r.start), n(r.start - i.windowStart)]
            let tail: [String] = [startFrame, endFrame, q(r.attributes)]
            let fields: [String] = sessionFields + what + times + tail
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The same segments as START / STOP events in the form used by BORIS (one row per event, time-ordered).
    static func borisCSV(_ rows: [Row], info i: SessionInfo) -> String {
        var events: [(Double, Int, [String])] = []
        for r in rows where r.category != "epoch" {
            let subject = r.animal.isEmpty ? (i.subject.isEmpty ? "subject" : i.subject) : r.animal
            let cat = r.source == "manual" ? "manual" : r.category
            events.append((r.start, 0, [subject, r.name, cat, "START"]))
            events.append((r.end, 1, [subject, r.name, cat, "STOP"]))
        }
        events.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var lines = ["Observation id,Media file,FPS,Time,Subject,Behavior,Behavioral category,Status"]
        for e in events {
            lines.append(([i.sessionID, i.video, String(format: "%.3f", i.fps), String(format: "%.3f", e.0)] + e.2)
                .map { Exporter.csvField($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func agreementCSV(_ a: [ScoringAgreement], info i: SessionInfo, includeHeader: Bool = true) -> String {
        var lines = includeHeader ? ["session_id,subject_id,animal,behavior_key,behavior,scored_from_s,scored_to_s,manual_s,auto_s,overlap_s,precision,recall,f1,manual_bouts,auto_bouts,matched_bouts,mean_onset_error_s"] : []
        func n(_ v: Double?, _ d: Int = 3) -> String { v.map { $0.isFinite ? String(format: "%.\(d)f", $0) : "" } ?? "" }
        for x in a {
            lines.append([Exporter.csvField(i.sessionID), Exporter.csvField(i.subject), Exporter.csvField(x.animal), Exporter.csvField(x.key),
                          Exporter.csvField(x.behavior), n(x.scoredFrom), n(x.scoredTo), n(x.manualTime), n(x.autoTime), n(x.overlap),
                          n(x.precision), n(x.recall), n(x.f1), String(x.manualBouts), String(x.autoBouts), String(x.matchedBouts), n(x.onsetError)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Definitions of the segment keys of one report (English), for segments_metadata.json.
    static func metadata(report: AnalysisReport, rows: [Row], info i: SessionInfo, manual: ManualAnnotations,
                         agreement: [ScoringAgreement]) -> [String: Any] {
        var behaviours: [String: [String: Any]] = [:]
        for r in rows {
            let k = (r.animal.isEmpty ? "" : r.animal + "_") + r.key + (r.source == "manual" ? "_manual" : "")
            var e = behaviours[k] ?? ["behavior_key": r.key, "behavior": r.name, "animal": r.animal, "category": r.category,
                                      "source": r.source, "bouts": 0, "total_s": 0.0]
            e["bouts"] = (e["bouts"] as? Int ?? 0) + 1
            e["total_s"] = (e["total_s"] as? Double ?? 0) + (r.end - r.start)
            behaviours[k] = e
        }
        return [
            "format": "rodentflow.segments/1",
            "session_id": i.sessionID,
            "task": i.task,
            "time_base": "video seconds; start_from_window_s is relative to the analysis window start",
            "window_start_s": i.windowStart,
            "fps": i.fps,
            // Clock time of video second 0, as written in the video file (empty when the file has none): add the
            // video seconds of a segment to it to line it up with the logs of a shock, tone or reward device.
            "recording_start": isoTime(i.recordingStart),
            "note": "Segments are the bouts shown on the review timeline (category behavior / qc), the stimulus epochs (epoch) and the manual scoring (manual). Where the timeline merges very short gaps, summed durations can differ slightly from measures computed frame by frame; the frame-by-frame CSV has the exact per-frame flags.",
            "behaviors": behaviours.keys.sorted().compactMap { behaviours[$0] },
            "methods": report.methods.map(L10n.reportText),
            "manual_annotator": manual.annotator,
            "manual_scored_from_s": manual.scoredStart as Any,
            "manual_scored_to_s": manual.scoredEnd as Any,
            "agreement": agreement.map { a -> [String: Any] in
                ["behavior_key": a.key, "animal": a.animal, "precision": a.precision as Any, "recall": a.recall as Any,
                 "f1": a.f1 as Any, "mean_onset_error_s": a.onsetError as Any, "manual_s": a.manualTime, "auto_s": a.autoTime]
            }
        ]
    }

    static func json(_ object: [String: Any]) -> Data {
        func clean(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.mapValues(clean) }
            if let a = v as? [Any] { return a.map(clean) }
            if let x = v as? Double { return x.isFinite ? x : NSNull() }
            // `nil` wrapped as Any (Optional.none) becomes JSON null.
            let mirror = Mirror(reflecting: v)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return NSNull() }
                return clean(child.value)
            }
            return v
        }
        return (try? JSONSerialization.data(withJSONObject: clean(object), options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }
}

// MARK: - DeepLabCut layout

extension Exporter {
    /// Keypoints in the DeepLabCut CSV layout (scorer / [individuals] / bodyparts / coords), pixels of the upright
    /// frame, one row per analysed frame (the Mac task export writes the same layout). Undetected frames are empty.
    static func dlcCSV(track: PoseTrack, model: String) -> Data {
        var w = ByteWriter()
        let n = max(1, track.animalCount)
        let names = kKeypointNames
        let columns = n * names.count * 3
        let scorer = "RodentFlow_" + model
        w.row(["scorer"] + Array(repeating: scorer, count: columns))
        if n > 1 {
            let individuals: [String] = (0..<n).map { a in n > 2 ? "m\(a + 1)" : (a == 0 ? "A" : "B") }
            w.row(["individuals"] + individuals.flatMap { Array(repeating: $0, count: names.count * 3) })
        }
        w.row(["bodyparts"] + (0..<n).flatMap { _ in names.flatMap { [$0, $0, $0] } })
        w.row(["coords"] + (0..<columns / 3).flatMap { _ in ["x", "y", "likelihood"] })
        for i in 0..<track.count {
            var fields = [String(i)]
            for a in 0..<n {
                let detected = track.conf(i, a) > 0
                for k in 0..<names.count {
                    if detected {
                        let p = track.point(i, a, k)
                        fields += [String(format: "%.2f", p.x), String(format: "%.2f", p.y), String(format: "%.3f", p.c)]
                    } else {
                        fields += ["", "", ""]
                    }
                }
            }
            w.row(fields)
        }
        return w.data
    }
}
