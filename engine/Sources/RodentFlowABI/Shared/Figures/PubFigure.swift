// PubFigure.swift — publication figures as plain vector drawings (RodentFlow 2.0: iOS build 15, Mac build 14).
//
// A figure is a list of shapes and texts in points (1/72 inch) at its final printed size. The same list is drawn on
// screen (SwiftUI Canvas), into a vector PDF and a PNG at 300 / 600 dpi (CoreGraphics, PoseUI/PubFigureRender.swift)
// and into SVG (below), so the preview, the PDF, the SVG and the PNG are the same figure. Layout uses Helvetica
// metrics (the font is Helvetica in PDF / PNG and Arial / Helvetica in SVG), sizes come from journal presets:
//   • single column 85 mm, 1.5 column 114 mm, double column 174 mm (Cell Press); text 5–8 pt, 7 pt by default.
// Foundation only: compiled into both apps and into the shared tests.

import Foundation

// MARK: - Primitives

struct PubPoint: Hashable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

struct PubColor: Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    static func gray(_ v: Double, alpha: Double = 1) -> PubColor { PubColor(r: v, g: v, b: v, a: alpha) }
    static let black = PubColor.gray(0)
    static let white = PubColor.gray(1)
    /// Axis lines and tick labels.
    static let ink = PubColor.gray(0.1)
    static let secondaryInk = PubColor.gray(0.38)

    func opacity(_ alpha: Double) -> PubColor { PubColor(r: r, g: g, b: b, a: alpha) }

    /// "#RRGGBB"
    var hexString: String {
        func c(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Luminance-preserving gray of the color (grayscale printing).
    var grayscale: PubColor { PubColor.gray(0.2126 * r + 0.7152 * g + 0.0722 * b, alpha: a) }
}

enum PubPathOp: Hashable {
    case move(PubPoint)
    case line(PubPoint)
    case curve(PubPoint, PubPoint, PubPoint)
    case close
}

struct PubPath: Hashable {
    var ops: [PubPathOp] = []

    mutating func move(_ x: Double, _ y: Double) { ops.append(.move(PubPoint(x, y))) }
    mutating func line(_ x: Double, _ y: Double) { ops.append(.line(PubPoint(x, y))) }
    mutating func close() { ops.append(.close) }

    static func segment(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> PubPath {
        var p = PubPath()
        p.move(x0, y0)
        p.line(x1, y1)
        return p
    }

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PubPath {
        var p = PubPath()
        p.move(x, y); p.line(x + w, y); p.line(x + w, y + h); p.line(x, y + h); p.close()
        return p
    }

    /// Circle from four cubic Bézier arcs.
    static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> PubPath {
        let k = 0.5522847498 * r
        var p = PubPath()
        p.ops = [.move(PubPoint(cx + r, cy)),
                 .curve(PubPoint(cx + r, cy + k), PubPoint(cx + k, cy + r), PubPoint(cx, cy + r)),
                 .curve(PubPoint(cx - k, cy + r), PubPoint(cx - r, cy + k), PubPoint(cx - r, cy)),
                 .curve(PubPoint(cx - r, cy - k), PubPoint(cx - k, cy - r), PubPoint(cx, cy - r)),
                 .curve(PubPoint(cx + k, cy - r), PubPoint(cx + r, cy - k), PubPoint(cx + r, cy)),
                 .close]
        return p
    }

    static func polyline(_ pts: [PubPoint], closed: Bool = false) -> PubPath {
        var p = PubPath()
        for (i, q) in pts.enumerated() { p.ops.append(i == 0 ? .move(q) : .line(q)) }
        if closed && !pts.isEmpty { p.close() }
        return p
    }

    /// Point marker of a group (grayscale figures distinguish groups by shape).
    static func marker(_ shape: Int, _ cx: Double, _ cy: Double, _ r: Double) -> PubPath {
        switch ((shape % 4) + 4) % 4 {
        case 1: return rect(cx - r * 0.89, cy - r * 0.89, r * 1.78, r * 1.78)
        case 2: return polyline([PubPoint(cx, cy - r * 1.2), PubPoint(cx + r * 1.1, cy + r * 0.8), PubPoint(cx - r * 1.1, cy + r * 0.8)], closed: true)
        case 3: return polyline([PubPoint(cx, cy - r * 1.25), PubPoint(cx + r * 1.1, cy), PubPoint(cx, cy + r * 1.25), PubPoint(cx - r * 1.1, cy)], closed: true)
        default: return circle(cx, cy, r)
        }
    }
}

struct PubStroke: Hashable {
    var color: PubColor
    var width: Double
    var dash: [Double] = []
}

enum PubAnchor: Hashable { case start, middle, end }
enum PubBaseline: Hashable { case alphabetic, middle, hanging }

struct PubText: Hashable {
    var text: String
    var at: PubPoint
    var size: Double
    var bold = false
    var color = PubColor.ink
    var anchor: PubAnchor = .start
    var baseline: PubBaseline = .alphabetic
    /// Degrees, clockwise on the page (−90 = reading upwards, for Y-axis titles).
    var rotation: Double = 0
}

enum PubItem: Hashable {
    case shape(PubPath, fill: PubColor?, stroke: PubStroke?)
    case text(PubText)
}

struct PubFigure: Hashable {
    /// Points (1/72 inch).
    var width: Double
    var height: Double
    var items: [PubItem] = []
    var background: PubColor? = .white

    mutating func fill(_ path: PubPath, _ color: PubColor) { items.append(.shape(path, fill: color, stroke: nil)) }
    mutating func stroke(_ path: PubPath, _ color: PubColor, _ width: Double, dash: [Double] = []) {
        items.append(.shape(path, fill: nil, stroke: PubStroke(color: color, width: width, dash: dash)))
    }
    mutating func shape(_ path: PubPath, fill: PubColor?, stroke: PubColor?, width: Double = 0.5) {
        items.append(.shape(path, fill: fill, stroke: stroke.map { PubStroke(color: $0, width: width) }))
    }
    mutating func text(_ t: PubText) { items.append(.text(t)) }

    /// Another figure drawn at an offset (panels of a multi-panel figure).
    mutating func place(_ other: PubFigure, dx: Double, dy: Double) {
        func move(_ p: PubPoint) -> PubPoint { PubPoint(p.x + dx, p.y + dy) }
        for item in other.items {
            switch item {
            case .shape(let path, let fill, let stroke):
                var moved = PubPath()
                moved.ops = path.ops.map { op in
                    switch op {
                    case .move(let p): return .move(move(p))
                    case .line(let p): return .line(move(p))
                    case .curve(let a, let b, let c): return .curve(move(a), move(b), move(c))
                    case .close: return .close
                    }
                }
                items.append(.shape(moved, fill: fill, stroke: stroke))
            case .text(var t):
                t.at = move(t.at)
                items.append(.text(t))
            }
        }
    }

    static func mm(_ v: Double) -> Double { v * 72 / 25.4 }
}

// MARK: - Text metrics (Helvetica, 1/1000 em)

enum PubTextMetrics {
    private static let widths: [Int] = [
        278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,   // space … /
        556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,   // 0 … ?
        1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,  // @ … O
        667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,   // P … _
        333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,   // ` … o
        556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584          // p … ~
    ]

    /// Approximate width of `text` in points.
    static func width(_ text: String, size: Double, bold: Bool = false) -> Double {
        var units = 0.0
        for s in text.unicodeScalars {
            let v = Int(s.value)
            if v >= 32 && v <= 126 {
                units += Double(widths[v - 32])
            } else if (0x3000...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v) || (0xFF00...0xFFEF).contains(v) {
                units += 1000
            } else {
                units += 600
            }
        }
        return units / 1000 * size * (bold ? 1.06 : 1)
    }

    /// Splits a label into at most two lines that fit `maxWidth` (at a space, else unchanged).
    static func wrap(_ text: String, size: Double, maxWidth: Double) -> [String] {
        guard width(text, size: size) > maxWidth, text.contains(" ") else { return [text] }
        let words = text.split(separator: " ").map(String.init)
        var best = [text]
        var bestWidth = Double.infinity
        for i in 1..<words.count {
            let a = words[..<i].joined(separator: " "), b = words[i...].joined(separator: " ")
            let w = max(width(a, size: size), width(b, size: size))
            if w < bestWidth { bestWidth = w; best = [a, b] }
        }
        return best
    }
}

// MARK: - Size presets and export settings

enum FigureWidthPreset: String, Codable, CaseIterable, Identifiable {
    case single, oneAndHalf = "one_and_half", double, custom
    var id: String { rawValue }

    var millimetres: Double? {
        switch self {
        case .single: return 85
        case .oneAndHalf: return 114
        case .double: return 174
        case .custom: return nil
        }
    }

    var displayName: String {
        switch self {
        case .single: return L("Single column (85 mm)", "单栏（85 mm）")
        case .oneAndHalf: return L("1.5 column (114 mm)", "1.5 栏（114 mm）")
        case .double: return L("Double column (174 mm)", "双栏（174 mm）")
        case .custom: return L("Custom width", "自定义宽度")
        }
    }
}

enum FigureRasterDPI: Int, Codable, CaseIterable, Identifiable {
    case dpi300 = 300, dpi600 = 600
    var id: Int { rawValue }
    var displayName: String { "\(rawValue) dpi" }
}

/// Size, text and formats of exported figures, remembered on this device (the same for all tasks, so all
/// figures of a paper match).
struct FigureExportSettings: Codable, Equatable {
    var preset: FigureWidthPreset = .single
    var customWidthMM: Double = 60
    /// 0 = automatic (from the figure's content).
    var heightMM: Double = 0
    /// One font size for every text of the figure (pt).
    var fontPt: Double = 7
    var dpi: FigureRasterDPI = .dpi300
    var pdf = true
    var png = true
    /// macOS only.
    var svg = true

    init() {}

    var widthMM: Double { preset.millimetres ?? min(250, max(30, customWidthMM)) }
    var widthPt: Double { PubFigure.mm(widthMM) }
    var font: Double { min(12, max(5, fontPt)) }

    /// Height in points for an automatic height of `aspect` × width (or the fixed height).
    func heightPt(aspect: Double) -> Double {
        heightMM > 0 ? PubFigure.mm(min(250, max(20, heightMM))) : widthPt * aspect
    }

    enum CodingKeys: String, CodingKey { case preset, customWidthMM, heightMM, fontPt, dpi, pdf, png, svg }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = c.v(.preset, FigureWidthPreset.single)
        customWidthMM = c.v(.customWidthMM, 60.0)
        heightMM = c.v(.heightMM, 0.0)
        fontPt = c.v(.fontPt, 7.0)
        dpi = c.v(.dpi, FigureRasterDPI.dpi300)
        pdf = c.v(.pdf, true)
        png = c.v(.png, true)
        svg = c.v(.svg, true)
    }

    private static let key = "figureExportSettings"

    static func load() -> FigureExportSettings {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(FigureExportSettings.self, from: d) else {
            return FigureExportSettings()
        }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}

// MARK: - SVG

enum PubSVG {
    private static func n(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.2f", r)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func pathData(_ p: PubPath) -> String {
        var d = ""
        for op in p.ops {
            switch op {
            case .move(let a): d += "M\(n(a.x)) \(n(a.y))"
            case .line(let a): d += "L\(n(a.x)) \(n(a.y))"
            case .curve(let a, let b, let c): d += "C\(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(c.x)) \(n(c.y))"
            case .close: d += "Z"
            }
        }
        return d
    }

    static func render(_ f: PubFigure, title: String = "") -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(n(f.width))pt\" height=\"\(n(f.height))pt\" viewBox=\"0 0 \(n(f.width)) \(n(f.height))\">\n"
        if !title.isEmpty { out += "<title>\(escape(title))</title>\n" }
        if let bg = f.background { out += "<rect x=\"0\" y=\"0\" width=\"\(n(f.width))\" height=\"\(n(f.height))\" fill=\"\(bg.hexString)\"/>\n" }
        for item in f.items {
            switch item {
            case .shape(let path, let fill, let stroke):
                var attrs = "d=\"\(pathData(path))\""
                if let fill {
                    attrs += " fill=\"\(fill.hexString)\""
                    if fill.a < 1 { attrs += " fill-opacity=\"\(n(fill.a))\"" }
                } else {
                    attrs += " fill=\"none\""
                }
                if let s = stroke {
                    attrs += " stroke=\"\(s.color.hexString)\" stroke-width=\"\(n(s.width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
                    if s.color.a < 1 { attrs += " stroke-opacity=\"\(n(s.color.a))\"" }
                    if !s.dash.isEmpty { attrs += " stroke-dasharray=\"\(s.dash.map(n).joined(separator: " "))\"" }
                }
                out += "<path \(attrs)/>\n"
            case .text(let t):
                let anchor: String
                switch t.anchor {
                case .start: anchor = "start"
                case .middle: anchor = "middle"
                case .end: anchor = "end"
                }
                var attrs = "x=\"\(n(t.at.x))\" y=\"\(n(t.at.y))\" font-family=\"Arial, Helvetica, sans-serif\" font-size=\"\(n(t.size))\" text-anchor=\"\(anchor)\" fill=\"\(t.color.hexString)\""
                if t.bold { attrs += " font-weight=\"bold\"" }
                switch t.baseline {
                case .alphabetic: break
                case .middle: attrs += " dominant-baseline=\"central\""
                case .hanging: attrs += " dominant-baseline=\"hanging\""
                }
                if t.rotation != 0 { attrs += " transform=\"rotate(\(n(t.rotation)) \(n(t.at.x)) \(n(t.at.y)))\"" }
                out += "<text \(attrs)>\(escape(t.text))</text>\n"
            }
        }
        out += "</svg>\n"
        return out
    }
}
