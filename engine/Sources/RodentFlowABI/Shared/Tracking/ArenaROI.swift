// ArenaROI.swift — the part of the frame that is tracked.
//
// Once the arena is calibrated, only a rectangle around it is given to the pose model (and the
// classic centroid tracker): the bounding box of the arena outline in the image, widened by a
// margin so that a rearing animal or a head dip over a maze edge stays inside. Everything else in
// the picture (bench, cables, people, a second cage) is never analysed. Cropping before the model
// also gives the animal more pixels at the model's fixed 960 × 960 input.
//
// Coordinates: normalized upright-frame coordinates (0–1, origin top-left), as in ArenaCalibration.
// Shared by the iPhone / iPad and the Mac app, so both crop exactly the same region.

import Foundation

/// A rectangle in normalized upright-frame coordinates (origin top-left).
struct NRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    static let full = NRect(x: 0, y: 0, w: 1, h: 1)

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var area: Double { max(0, w) * max(0, h) }
    var isFullFrame: Bool { x <= 1e-6 && y <= 1e-6 && maxX >= 1 - 1e-6 && maxY >= 1 - 1e-6 }

    /// Clamped to the frame.
    func clamped() -> NRect {
        let x0 = min(max(0, x), 1), y0 = min(max(0, y), 1)
        let x1 = min(max(0, maxX), 1), y1 = min(max(0, maxY), 1)
        return NRect(x: x0, y: y0, w: max(0, x1 - x0), h: max(0, y1 - y0))
    }

    /// True when `other` lies inside this rectangle (with a tolerance in normalized units).
    func contains(_ other: NRect, tolerance: Double = 0.002) -> Bool {
        other.x >= x - tolerance && other.y >= y - tolerance
            && other.maxX <= maxX + tolerance && other.maxY <= maxY + tolerance
    }

    func contains(_ p: NPoint) -> Bool { p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY }

    /// Whole-pixel rectangle in a frame of `size` pixels (top-left origin), at least 32 px per side
    /// and always inside the frame.
    func pixelRect(in size: V2) -> (x: Int, y: Int, width: Int, height: Int) {
        let fw = max(1, Int(size.x.rounded())), fh = max(1, Int(size.y.rounded()))
        let c = clamped()
        var x0 = Int((c.x * Double(fw)).rounded(.down))
        var y0 = Int((c.y * Double(fh)).rounded(.down))
        var x1 = Int((c.maxX * Double(fw)).rounded(.up))
        var y1 = Int((c.maxY * Double(fh)).rounded(.up))
        let minSide = min(32, fw, fh)
        if x1 - x0 < minSide { x1 = min(fw, x0 + minSide); x0 = max(0, x1 - minSide) }
        if y1 - y0 < minSide { y1 = min(fh, y0 + minSide); y0 = max(0, y1 - minSide) }
        x0 = max(0, x0); y0 = max(0, y0); x1 = min(fw, x1); y1 = min(fh, y1)
        return (x0, y0, max(1, x1 - x0), max(1, y1 - y0))
    }
}

/// How much of the frame is tracked.
enum TrackingRegion: String, Codable, CaseIterable, Identifiable {
    /// The calibrated arena plus a margin (default for new analyses).
    case arena
    /// The whole picture (analyses made before 2.0, uncalibrated videos).
    case fullFrame

    var id: String { rawValue }
}

enum ArenaROI {
    /// Margin around the arena as a fraction of its larger side in the image.
    static let defaultMargin = 0.12
    /// Choices offered in the interface.
    static let marginChoices: [Double] = [0.05, 0.12, 0.25]
    /// Never smaller than this many pixels on each side (a mouse rearing on a wall).
    static let minimumMarginPixels = 24.0

    /// Outline of the calibrated arena in upright-frame pixels (nil: no calibration, track the whole frame).
    static func outlinePixels(_ cal: ArenaCalibration, frameSize: V2) -> [V2]? {
        let fs = V2(max(frameSize.x, 1), max(frameSize.y, 1))
        switch cal.kind {
        case .none:
            return nil
        case .rectangle:
            guard cal.corners.count == 4 else { return nil }
            return cal.corners.map { $0.pixels(fs) }
        case .circle:
            let c = cal.circleCenter.pixels(fs)
            let r = max(1, c.distance(to: cal.circleEdge.pixels(fs)))
            return (0..<32).map { i in
                let a = Double(i) / 32 * 2 * Double.pi
                return V2(c.x + r * cos(a), c.y + r * sin(a))
            }
        case .plusMaze, .yMaze, .tMaze:
            let mapping = ArenaMapper.mapping(cal, frameSize: fs)
            guard let m = MazeGeometry.from(cal, mapping: mapping) else { return nil }
            var pts: [V2] = []
            for i in m.ends.indices {
                pts.append(contentsOf: m.armPolygon(i).map { mapping.toImage($0) })
            }
            // The center region of the junction.
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * Double.pi
                pts.append(mapping.toImage(V2(m.center.x + m.centerRadius * cos(a), m.center.y + m.centerRadius * sin(a))))
            }
            return pts.filter { $0.isFinite }
        }
    }

    /// Region to track for a calibration: the arena's bounding box widened by `margin` × its larger
    /// side (at least `minimumMarginPixels`), clamped to the frame. nil = track the whole frame.
    static func rect(_ cal: ArenaCalibration, frameSize: V2, margin: Double = defaultMargin) -> NRect? {
        guard let pts = outlinePixels(cal, frameSize: frameSize), pts.count >= 2 else { return nil }
        let fs = V2(max(frameSize.x, 1), max(frameSize.y, 1))
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX > minX, maxY > minY else { return nil }
        let pad = max(minimumMarginPixels, max(0, margin) * max(maxX - minX, maxY - minY))
        let r = NRect(x: (minX - pad) / fs.x, y: (minY - pad) / fs.y,
                      w: (maxX - minX + 2 * pad) / fs.x, h: (maxY - minY + 2 * pad) / fs.y).clamped()
        guard r.w > 0.01, r.h > 0.01 else { return nil }
        return r
    }

    /// Region for a run with these settings and this calibration (nil = whole frame).
    static func region(for settings: InferenceSettings, calibration: ArenaCalibration, frameSize: V2) -> NRect? {
        guard settings.region == .arena else { return nil }
        return rect(calibration, frameSize: frameSize, margin: settings.arenaMargin)
    }

    /// Keypoints found in a crop of the frame, moved back into whole-frame pixels.
    static func uncrop(_ poses: [AnimalPose], originX: Double, originY: Double) -> [AnimalPose] {
        guard originX != 0 || originY != 0 else { return poses }
        let dx = Float(originX), dy = Float(originY)
        return poses.map { p in
            guard p.detected else { return p }
            var q = p
            q.x = p.x.map { $0 + dx }
            q.y = p.y.map { $0 + dy }
            return q
        }
    }
}
