// FigureOptions.swift — what an arena figure (trajectory / zones / heat map) shows.
//
// Every part of an arena figure can be removed before it is copied, shared or exported: the arena
// outline, each family of zones (e.g. the cups of the three-chamber test, the objects of NOR, the
// chambers), the dashed investigation rings, zone names, the path, start / end points, event dots,
// arrows, the scale bar and the legend. Heat maps can also be shown on the original video frame
// (overlay) or next to it (side by side) to check that the hot spots sit where the animal really was.
//
// The choice is remembered per task and figure (e.g. "three-chamber · Trajectory and zones") on this
// device, so every animal of an experiment is exported the same way. Shared by iOS and macOS.

import Foundation

/// A removable part of an arena figure.
enum FigureLayer: String, Codable, CaseIterable, Identifiable {
    case arenaOutline
    case zoneLabels
    case investigationRings
    case trajectory
    case startEnd
    case dots
    case arrows
    case scaleBar
    case legend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arenaOutline: return L10n.tr("场地边框")
        case .zoneLabels: return L10n.tr("区域名称")
        case .investigationRings: return L10n.tr("判定范围（虚线圈）")
        case .trajectory: return L10n.tr("轨迹")
        case .startEnd: return L10n.tr("起点 / 终点")
        case .dots: return L10n.tr("事件点")
        case .arrows: return L10n.tr("方向箭头")
        case .scaleBar: return L10n.tr("比例尺")
        case .legend: return L10n.tr("图例")
        }
    }
}

/// How a heat map is shown.
enum HeatBackdrop: String, Codable, CaseIterable, Identifiable {
    /// The heat map alone (arena coordinates, as before).
    case none
    /// The heat map drawn on the original video frame (each cell mapped into the picture).
    case overlay
    /// The heat map and the original frame next to each other.
    case sideBySide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L10n.tr("仅热图")
        case .overlay: return L10n.tr("叠加原图")
        case .sideBySide: return L10n.tr("并排原图")
        }
    }
}

/// Families of zones that are shown or hidden together (e.g. both cups, all arms).
enum ZoneFamily {
    /// Family key of a zone id: "cupL" / "cupR" / "cupL_sniff" → "cup", "objA_explore" → "obj",
    /// "armN" → "arm", "hole_3" → "hole", "corner1" → "corner", "chL" → "ch".
    static func key(_ zoneID: String) -> String {
        var base = zoneID
        if let i = base.firstIndex(of: "_") { base = String(base[..<i]) }
        while let last = base.last, last.isNumber { base.removeLast() }
        if base.count > 2, let last = base.last, last.isUppercase,
           let prev = base.dropLast().last, prev.isLowercase {
            base.removeLast()
        }
        return base.isEmpty ? zoneID : base
    }

    /// Name shown in the layer list.
    static func title(_ key: String, sample: String) -> String {
        switch key {
        case "cup": return L10n.tr("杯子")
        case "ch": return L10n.tr("箱室分区")
        case "obj": return L10n.tr("物体")
        case "arm": return L10n.tr("迷宫臂")
        case "hole": return L10n.tr("洞")
        case "corner": return L10n.tr("角落区")
        case "iz": return L10n.tr("互动区")
        case "enclosure": return L10n.tr("网罩")
        case "center": return L10n.tr("中央区")
        case "light": return L10n.tr("明箱")
        case "dark": return L10n.tr("暗箱")
        case "shelter": return L10n.tr("巢穴")
        case "quadrant": return L10n.tr("目标象限")
        case "choice": return L10n.tr("选择点")
        case "cue": return L10n.tr("提示卡")
        case "seg": return L10n.tr("开放段 / 闭合段")
        case "food": return L10n.tr("食物区")
        default: return sample.isEmpty ? key : sample
        }
    }

    /// Families present in a list of zones, in drawing order, with display names.
    static func families(_ zones: [Zone]) -> [ZoneFamilyItem] {
        var out: [ZoneFamilyItem] = []
        var seen = Set<String>()
        for z in zones where z.role != .arena {
            let k = key(z.id)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(ZoneFamilyItem(key: k, title: title(k, sample: z.title)))
        }
        return out
    }
}

struct ZoneFamilyItem: Identifiable, Hashable {
    let key: String
    let title: String
    var id: String { key }
}

/// A rectangle of the video frame in pixels.
struct FrameBox: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// What one arena figure shows. Equality-comparable so views redraw only when it changes.
struct FigureStyle: Codable, Equatable {
    /// Layers switched off.
    var hidden: Set<FigureLayer> = []
    /// Zone families switched off (keys from `ZoneFamily.key`).
    var hiddenZones: Set<String> = []
    /// Heat maps only.
    var backdrop: HeatBackdrop = .none
    /// Opacity of the heat map over the original frame (overlay).
    var overlayOpacity: Double = 0.6

    init() {}

    func shows(_ layer: FigureLayer) -> Bool { !hidden.contains(layer) }

    /// Whether a zone is drawn (its family is on; dashed rings also need their layer).
    func shows(_ zone: Zone) -> Bool {
        if zone.outlineOnly && hidden.contains(.investigationRings) { return false }
        return !hiddenZones.contains(ZoneFamily.key(zone.id))
    }

    var isDefault: Bool { self == FigureStyle() }

    enum CodingKeys: String, CodingKey { case hidden, hiddenZones, backdrop, overlayOpacity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawHidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? nil
        hidden = Set((rawHidden ?? []).compactMap(FigureLayer.init(rawValue:)))
        hiddenZones = Set(((try? c.decodeIfPresent([String].self, forKey: .hiddenZones)) ?? nil) ?? [])
        let rawBackdrop = (try? c.decodeIfPresent(String.self, forKey: .backdrop)) ?? nil
        backdrop = rawBackdrop.flatMap(HeatBackdrop.init(rawValue:)) ?? .none
        overlayOpacity = min(1, max(0.1, ((try? c.decodeIfPresent(Double.self, forKey: .overlayOpacity)) ?? nil) ?? 0.6))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hidden.map(\.rawValue).sorted(), forKey: .hidden)
        try c.encode(hiddenZones.sorted(), forKey: .hiddenZones)
        try c.encode(backdrop.rawValue, forKey: .backdrop)
        try c.encode(overlayOpacity, forKey: .overlayOpacity)
    }
}

/// Remembered figure styles (UserDefaults on this device).
enum FigureStyleStore {
    private static let prefix = "figureStyle."

    /// Stable key of a figure: task + English figure title (the same in both interface languages).
    static func key(scope: String, title: String) -> String {
        prefix + scope + "." + L10n.english(title)
    }

    static func load(scope: String, title: String) -> FigureStyle {
        guard let data = UserDefaults.standard.data(forKey: key(scope: scope, title: title)),
              let style = try? JSONDecoder().decode(FigureStyle.self, from: data) else { return FigureStyle() }
        return style
    }

    static func save(_ style: FigureStyle, scope: String, title: String) {
        let k = key(scope: scope, title: title)
        if style.isDefault {
            UserDefaults.standard.removeObject(forKey: k)
        } else if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: k)
        }
    }
}

// MARK: - Drawing helpers shared by the renderers

enum FigureGeometry {
    /// Corners of one heat-map cell in upright-frame pixels (for drawing it on the original frame).
    static func cellCorners(column c: Int, row r: Int, cell: Double, mapping: ArenaMapping) -> [V2] {
        let x0 = Double(c) * cell, y0 = Double(r) * cell
        return [V2(x0, y0), V2(x0 + cell, y0), V2(x0 + cell, y0 + cell), V2(x0, y0 + cell)].map { mapping.toImage($0) }
    }

    /// Region of the video frame (pixels) that shows the arena of a figure, with a margin, for
    /// cropping the original frame next to / under a figure. nil without a mapping.
    static func frameCrop(_ data: ArenaPlotData, margin: Double = 0.08) -> FrameBox? {
        guard let m = data.mapping, m.isMetric else { return nil }
        let e = data.extent
        let pts = [V2(0, 0), V2(e.x, 0), V2(e.x, e.y), V2(0, e.y)].map { m.toImage($0) }.filter(\.isFinite)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max(), maxX > minX, maxY > minY else { return nil }
        let pad = margin * max(maxX - minX, maxY - minY)
        let fs = m.frameSize
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(fs.x, maxX + pad), y1 = min(fs.y, maxY + pad)
        guard x1 > x0, y1 > y0 else { return nil }
        return FrameBox(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }
}
