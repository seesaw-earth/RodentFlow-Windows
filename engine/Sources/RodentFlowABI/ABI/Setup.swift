// Setup.swift — what the host needs to set up an analysis of any task, so that no task needs code of
// its own in the host app:
//
//   catalogue facts   SetupABI.paradigmInfo     arena kinds, markers, phases, default size, companions …
//   rf_default_setup  SetupABI.defaultSetup     ArenaCalibration.makeDefault + AnalysisParams.defaults(for:)
//   rf_setup_view     SetupABI.viewRequest      zones, handles and tracked region for the current setup
//   rf_move_handle    SetupABI.move             one handle dragged to a point → the new setup and its view
//
// The zones come from the engine itself (ZoneBuilder.zones — the same zones the analysis counts in).
// The handles and the drag rules live in the Mac app's UI layer, which is not part of this library:
//   handles   RodentStudio/Views/PoseCalibrationEditor.swift  PoseCalibrationCanvas.handles
//   move      RodentStudio/Views/PoseCalibrationEditor.swift  PoseCalibrationCanvas.move(_:to:)
//   reset     RodentStudio/Views/PoseCalibrationEditor.swift  PoseCalibrationEditor.resetCalibration
// They are copied below line for line. Keep them in step with that file.

import Foundation

enum SetupABI {
    // MARK: Catalogue

    /// Everything about a task that decides what its setup screen shows.
    static func paradigmInfo(_ p: Paradigm) -> [String: Any] {
        let size = p.defaultArenaSize
        var companions: [String: String] = [:]
        for phase in p.phases {
            if let other = p.companionPhase(of: phase.key) { companions[phase.key] = other }
        }
        return [
            "id": p.rawValue,
            "title": p.title,
            "englishName": p.englishName,
            "shortName": p.shortName,
            "category": p.category.rawValue,
            "categoryTitle": Lang.isChinese ? p.category.title : p.category.english,
            "animalCount": p.animalCount,
            "isGroup": p.isGroup,
            "phases": p.phases.map { ["key": $0.key, "title": $0.title] },
            "arenaKinds": SetupABI.arenaKinds(p).map { $0.rawValue },
            "defaultArena": p.defaultArena.rawValue,
            // Every marker the task can have; which are in use depends on the parameters (rf_setup_view).
            "markers": p.markers.map { ["key": $0.key, "label": $0.label, "title": $0.title] },
            "defaultArenaSize": ["width": size.width, "height": size.height],
            "primaryMetric": p.primaryMetricKey,
            // Phase → the phase of the same animal whose measures it is paired with.
            "companions": companions,
            "tagline": p.tagline,
            "summary": p.summary,
            "setupTips": p.setupTips,
        ]
    }

    static func arenaKindInfo(_ k: ArenaKind) -> [String: Any] {
        ["id": k.rawValue, "title": k.title, "mazeLabels": k.mazeLabels]
    }

    // MARK: Default setup

    struct DefaultRequest: Decodable {
        var paradigm: Paradigm
        /// Arena shape; nil or not offered by the task = the task's default shape.
        var arena: ArenaKind?
        var frameWidth: Double
        var frameHeight: Double
        /// The current parameters, for a reset of the handles only (they are kept, except what the
        /// handles themselves set). Nil for a new setup: the task's default parameters.
        var params: AnalysisParams?
    }

    /// The arena shapes a task offers on Windows: the Mac's (Paradigm.arenaKinds), plus "no calibration" for every
    /// task. Without calibration the analysis runs on the video's own pixels: zones are laid over the whole frame,
    /// distances and speeds are in pixels and the engine says so in the report (AnalysisCore: 未标定…). The Mac
    /// offers "none" only for the tasks without zones; this is a Windows choice, made here so the engine still
    /// decides what the window may offer.
    static func arenaKinds(_ p: Paradigm) -> [ArenaKind] {
        p.arenaKinds.contains(.none) ? p.arenaKinds : p.arenaKinds + [.none]
    }

    static func defaultSetup(_ r: DefaultRequest) throws -> [String: Any] {
        let frame = try frameSize(r.frameWidth, r.frameHeight)
        let p = r.paradigm
        let kind = r.arena.flatMap { SetupABI.arenaKinds(p).contains($0) ? $0 : nil } ?? p.defaultArena
        let calibration = ArenaCalibration.makeDefault(paradigm: p, kind: kind, frameSize: frame)
        var params = r.params ?? AnalysisParams.defaults(for: p)
        if r.params != nil && p == .threeChamber {
            // The movable dividers belong to the calibration controls too (PoseCalibrationEditor.resetCalibration).
            params.centerChamberFraction = 1.0 / 3.0
            params.centerChamberOffset = 0
        }
        let calibrationTree = try RFCoding.tree(calibration)
        let paramsTree = try RFCoding.tree(params)
        return ["calibration": calibrationTree, "params": paramsTree]
    }

    // MARK: View

    struct ViewRequest: Decodable {
        var session: Session
        var frameWidth: Double
        var frameHeight: Double
    }

    struct Handle {
        let id: String
        let label: String
        let point: NPoint
        /// arena (yellow) · open (cyan, an open arm) · divider (purple) · marker (cyan)
        let kind: String
        var title = ""
    }

    /// The handles of a setup (PoseCalibrationCanvas.handles).
    static func handles(_ s: Session, mapping: ArenaMapping) -> [Handle] {
        let calibration = s.calibration
        let params = s.params
        let paradigm = s.paradigm
        var hs: [Handle] = []
        switch calibration.kind {
        case .none:
            break
        case .rectangle:
            for (i, c) in calibration.corners.enumerated() {
                hs.append(Handle(id: "corner\(i)", label: "\(i + 1)", point: c, kind: "arena"))
            }
        case .circle:
            hs.append(Handle(id: "center", label: "C", point: calibration.circleCenter, kind: "arena"))
            hs.append(Handle(id: "edge", label: "R", point: calibration.circleEdge, kind: "arena"))
        case .plusMaze, .yMaze, .tMaze:
            let labels = calibration.kind.mazeLabels
            let open = ZoneBuilder.openArmIndices(params)
            for (i, p) in calibration.mazePoints.enumerated() where i < labels.count {
                let isOpen = calibration.kind == .plusMaze && i > 0 && open.contains(i - 1)
                hs.append(Handle(id: "maze\(i)", label: labels[i], point: p, kind: isOpen ? "open" : "arena"))
            }
        }
        if paradigm == .threeChamber && calibration.kind == .rectangle {
            let b = ZoneBuilder.threeChamberBounds(params)
            let e = mapping.extent
            let dividers: [(String, String, Double)] = [("dividerL", "L", b.left), ("dividerR", "R", b.right)]
            for (id, label, x) in dividers {
                let point = mapping.toNormalized(V2(x * e.x, 0.24 * e.y))
                hs.append(Handle(id: id, label: label, point: point, kind: "divider"))
            }
        }
        for m in paradigm.markers(params) {
            if let p = calibration.marker(m.key, mapping: mapping) {
                hs.append(Handle(id: "marker_" + m.key, label: m.label, point: p, kind: "marker", title: m.title))
            }
        }
        return hs
    }

    static func viewRequest(_ r: ViewRequest) throws -> [String: Any] {
        try view(r.session, frame: try frameSize(r.frameWidth, r.frameHeight))
    }

    static func view(_ s: Session, frame: V2) throws -> [String: Any] {
        let mapping = ArenaMapper.mapping(s.calibration, frameSize: frame)

        func point(_ n: NPoint) -> [Any] { [RFJSON.number(n.x), RFJSON.number(n.y)] }
        func normalized(_ a: V2) -> [Any] { point(mapping.toNormalized(a)) }

        let zones: [[String: Any]] = ZoneBuilder.zones(s, mapping: mapping)
            .filter { $0.role != .arena }
            .map { z -> [String: Any] in
                [
                    "id": z.id,
                    "title": z.title,
                    "role": z.role.rawValue,
                    "outline": z.outline().map(normalized),
                    "center": normalized(z.center),
                    "outlineOnly": z.outlineOnly,
                    "showsLabel": z.showsLabel,
                ]
            }
        let handleList: [[String: Any]] = handles(s, mapping: mapping).map { h -> [String: Any] in
            ["id": h.id, "label": h.label, "x": RFJSON.number(h.point.x), "y": RFJSON.number(h.point.y),
             "kind": h.kind, "title": h.title]
        }
        let region = ArenaROI.region(for: s.inference, calibration: s.calibration, frameSize: frame)
        let ppu = mapping.pxPerUnit
        let calibrationTree = try RFCoding.tree(s.calibration)
        let paramsTree = try RFCoding.tree(s.params)

        return [
            "zones": zones,
            "handles": handleList,
            // The part of the frame the model will be given; null = the whole frame.
            "region": region.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as Any } ?? NSNull(),
            "isMetric": mapping.isMetric,
            "pixelsPerCM": mapping.isMetric && ppu.isFinite ? ppu : NSNull(),
            // The setup as the engine reads it. The host keeps these, not what it sent: a value the
            // engine could not read (wrong type, unknown key) shows up here as the default it used.
            "calibration": calibrationTree,
            "params": paramsTree,
        ]
    }

    // MARK: Move a handle

    struct MoveRequest: Decodable {
        var session: Session
        var frameWidth: Double
        var frameHeight: Double
        var handle: String
        var x: Double
        var y: Double
    }

    /// PoseCalibrationCanvas.move(_:to:), then the view of the result.
    static func move(_ r: MoveRequest) throws -> [String: Any] {
        let frame = try frameSize(r.frameWidth, r.frameHeight)
        guard r.x.isFinite, r.y.isFinite else { throw RFError.badArgument("The handle position is not a number") }
        var s = r.session
        let mapping = ArenaMapper.mapping(s.calibration, frameSize: frame)
        let point = NPoint(r.x, r.y).clamped()
        let id = r.handle

        if id == "dividerL" || id == "dividerR" {
            var p = s.params
            let bounds = ZoneBuilder.threeChamberBounds(p)
            let e = mapping.extent
            if e.x > 0 {
                let localX = mapping.toArena(point).x / e.x
                if localX.isFinite {
                    // Each boundary moves independently, keeping at least 10% for the centre and 5% per side.
                    let left = id == "dividerL" ? clamp(localX, max(0.05, bounds.right - 0.80), bounds.right - 0.10) : bounds.left
                    let right = id == "dividerR" ? clamp(localX, bounds.left + 0.10, min(0.95, bounds.left + 0.80)) : bounds.right
                    p.centerChamberFraction = right - left
                    p.centerChamberOffset = (left + right) / 2 - 0.5
                    s.params = p
                }
            }
            return try view(s, frame: frame)
        }

        var c = s.calibration
        if id.hasPrefix("corner"), let i = Int(id.dropFirst(6)), i >= 0, i < c.corners.count {
            c.corners[i] = point
        } else if id == "center" {
            let dx = c.circleEdge.x - c.circleCenter.x, dy = c.circleEdge.y - c.circleCenter.y
            c.circleCenter = point
            c.circleEdge = NPoint(point.x + dx, point.y + dy)
        } else if id == "edge" {
            c.circleEdge = point
        } else if id.hasPrefix("maze"), let i = Int(id.dropFirst(4)), i >= 0, i < c.mazePoints.count {
            c.mazePoints[i] = point
        } else if id.hasPrefix("marker_") {
            c.markers[String(id.dropFirst(7))] = point
        } else {
            throw RFError.badArgument("No handle called " + id)
        }
        s.calibration = c
        return try view(s, frame: frame)
    }

    // MARK: Helpers

    static func frameSize(_ w: Double, _ h: Double) throws -> V2 {
        guard w.isFinite, h.isFinite, w >= 1, h >= 1 else { throw RFError.badArgument("Invalid frame size") }
        return V2(w, h)
    }
}

extension RFCoding {
    /// A Codable value as a JSONSerialization tree, so it can sit inside an RFJSON reply.
    static func tree<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder(pretty: false).encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}

// MARK: - Exports

private func setupCall<R: Decodable>(_ name: String, _ json: UnsafePointer<CChar>?, _ type: R.Type,
                                     _ body: (R) throws -> [String: Any]) -> UnsafeMutablePointer<CChar> {
    guard let text = rfReadCString(json) else {
        return rfMakeCString(RFJSON.failure(name + ": no request"))
    }
    do {
        let request = try RFCoding.decode(type, from: text)
        return rfMakeCString(RFJSON.ok(try body(request)))
    } catch {
        return rfMakeCString(RFJSON.failure(name + ": " + ((error as? LocalizedError)?.errorDescription ?? String(describing: error))))
    }
}

/// The task's default calibration (laid out for this frame) and parameters.
@_cdecl("rf_default_setup")
public func rf_default_setup(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    setupCall("rf_default_setup", requestJSON, SetupABI.DefaultRequest.self, SetupABI.defaultSetup)
}

/// Zones, handles and tracked region of a setup, plus the setup as the engine reads it.
@_cdecl("rf_setup_view")
public func rf_setup_view(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    setupCall("rf_setup_view", requestJSON, SetupABI.ViewRequest.self, SetupABI.viewRequest)
}

/// One handle dragged to a normalized point; returns the new setup's view.
@_cdecl("rf_move_handle")
public func rf_move_handle(_ requestJSON: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar> {
    setupCall("rf_move_handle", requestJSON, SetupABI.MoveRequest.self, SetupABI.move)
}
