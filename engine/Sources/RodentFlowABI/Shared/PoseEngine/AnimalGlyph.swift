// AnimalGlyph.swift — how each animal of a two-animal run is marked on the video, identical on the
// iPhone / iPad and the Mac (review, live preview, annotated MP4 and PNG frames). RodentFlow 2.0 (build 9).
//
//   • head triangle — nose, left ear, right ear — outlined and lightly filled in the animal's colour;
//   • nose extension — a line from the nose straight ahead (ear midpoint → nose): where the animal points;
//   • tail base — a dot of the same colour, on its own (not joined to the head).
//
// Animal A is blue, animal B is red. One-animal runs keep the six-keypoint skeleton.
// Foundation only: the geometry is unit-tested on its own (tools/tests/AnimalGlyphTest.swift); the
// drawing (SwiftUI and Core Graphics) is in Shared/PoseUI/AnimalGlyphDrawing.swift.

import Foundation

enum AnimalColors {
    /// sRGB of animal A (blue, #1E88E5) and animal B (red, #E53935). Far apart in hue and in lightness
    /// for the common colour-vision deficiencies; always drawn with a dark halo, so both read on dark
    /// and on white arenas.
    static let blue = (r: 0.118, g: 0.533, b: 0.898)
    static let red = (r: 0.898, g: 0.224, b: 0.208)

    /// A pair is blue and red; a group goes on through eight more colours (Okabe–Ito hues, plus brown, gray and pink).
    private static let group: [(r: Double, g: Double, b: Double)] = [
        blue, red, (0.00, 0.62, 0.45), (0.90, 0.62, 0.00), (0.80, 0.47, 0.65), (0.34, 0.71, 0.91), (0.55, 0.38, 0.12),
        (0.94, 0.84, 0.26), (0.45, 0.45, 0.48), (0.91, 0.30, 0.56)
    ]

    static func rgb(_ animal: Int) -> (r: Double, g: Double, b: Double) { group[abs(animal) % group.count] }
    /// Label of an animal on the video: A / B for a pair, a number in a group.
    static func letter(_ animal: Int, animals: Int = 2) -> String { animals > 2 ? String(animal + 1) : (animal % 2 == 0 ? "A" : "B") }
}

struct AnimalGlyph: Equatable {
    /// Nose, left ear, right ear (nil when one of them is missing).
    var triangle: [V2]?
    /// Start (the nose) and end of the nose extension (nil when the head direction is unknown).
    var noseLine: [V2]?
    /// Head keypoints drawn as small dots when the triangle is incomplete.
    var headDots: [V2] = []
    /// The tail base, drawn on its own.
    var tailBase: V2?
    /// Where the animal's letter goes: the body centre, else the neck, else the head, else the tail base.
    var anchor: V2?

    var isEmpty: Bool { triangle == nil && noseLine == nil && headDots.isEmpty && tailBase == nil }

    /// The marks of one animal. `point(k)` is keypoint `k` (`KP` raw value) in drawing coordinates, or
    /// nil when it is missing or below the confidence threshold. The nose extension is one head length
    /// (ear midpoint → nose) long, but at least `minimumExtension`.
    static func make(minimumExtension: Double = 0, _ point: (Int) -> V2?) -> AnimalGlyph {
        func at(_ k: KP) -> V2? { point(k.rawValue).flatMap { $0.isFinite ? $0 : nil } }
        let nose = at(.nose), left = at(.leftEar), right = at(.rightEar)
        let neck = at(.neck), body = at(.bodyCenter), tail = at(.tailBase)
        var glyph = AnimalGlyph(tailBase: tail)
        if let nose, let left, let right {
            glyph.triangle = [nose, left, right]
            glyph.noseLine = extend(from: V2.mid(left, right), through: nose, factor: 1, minimum: minimumExtension)
        } else {
            glyph.headDots = [nose, left, right].compactMap { $0 }
            // Without both ears the direction comes from the neck (neck → nose is about 1.6 head lengths).
            if let nose, let neck {
                glyph.noseLine = extend(from: neck, through: nose, factor: 0.6, minimum: minimumExtension)
            }
        }
        let head = glyph.triangle.map(centroid) ?? (glyph.headDots.isEmpty ? nil : centroid(glyph.headDots))
        glyph.anchor = body ?? neck ?? head ?? tail
        return glyph
    }

    /// The segment from `nose` onwards along `base` → `nose`, `factor` × that distance long (at least
    /// `minimum`); nil when the two points coincide.
    static func extend(from base: V2, through nose: V2, factor: Double, minimum: Double) -> [V2]? {
        let d = nose - base
        let length = d.length
        guard length.isFinite, length > 1e-6 else { return nil }
        let reach = max(length * factor, minimum)
        return [nose, nose + d / length * reach]
    }

    private static func centroid(_ points: [V2]) -> V2 {
        points.reduce(V2.zero, +) / Double(max(points.count, 1))
    }
}
