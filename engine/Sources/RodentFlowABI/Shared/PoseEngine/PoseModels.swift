// PoseModels.swift — the four pose models and which one a run uses (the same on iPhone / iPad and Mac).
//
// All four take the same input (960 × 960 image) and give the same output (end-to-end YOLO26 pose,
// [1, 300, 24]) with the same six keypoints (Keypoints.swift). A run goes through exactly the same frame
// pipeline whichever model it uses (arena crop, grayscale, letterbox, decoding, cleaning, analysis); only
// the model file differs. The model follows from the number of animals (fixed by the task) and the coat
// colour of the animals (chosen per video; a task remembers its default).
//
// A model that is missing or fails to load is never replaced by another one: the run cannot start and
// the reason is shown (RodentFlow 2.0 iOS build 19 / Mac build 15).

import Foundation

/// Coat colour of the animals in a pose video. Chooses the pose model.
enum CoatColor: String, Codable, CaseIterable, Identifiable {
    /// One dark mouse, or two dark mice (the default; the original models).
    case dark
    /// One white (albino) mouse.
    case white
    /// Two mice: one dark, one white.
    case darkWhite

    var id: String { rawValue }

    /// Colours offered for this many animals. Two white mice are not offered yet.
    static func choices(animalCount: Int) -> [CoatColor] {
        animalCount > 2 ? [.dark] : (animalCount > 1 ? [.dark, .darkWhite] : [.dark, .white])
    }

    /// This colour if it exists for this many animals, otherwise dark.
    func valid(for animalCount: Int) -> CoatColor {
        CoatColor.choices(animalCount: animalCount).contains(self) ? self : .dark
    }

    /// Interface label.
    func title(animalCount: Int) -> String {
        switch self {
        case .dark: return animalCount > 2 ? L10n.tr("全部深色") : (animalCount > 1 ? L10n.tr("两只都是深色") : L10n.tr("深色"))
        case .white: return L10n.tr("白色")
        case .darkWhite: return L10n.tr("一黑一白")
        }
    }

    /// English label for exports and Methods.
    func englishTitle(animalCount: Int) -> String {
        switch self {
        case .dark: return animalCount > 2 ? "dark mice" : (animalCount > 1 ? "two dark mice" : "dark mouse")
        case .white: return "white mouse"
        case .darkWhite: return "one dark and one white mouse"
        }
    }
}

/// White-mouse model: YOLO26n pose, 960 × 960, one white mouse (DooM white-mouse labs; neck and body
/// center derived by rule). Same input, output and keypoints as `kModelName`.
let kWhiteModelName = "WhiteMousePose6_960_int8"
/// Dark–white pair model: YOLO26s pose, 960 × 960, two mice (one dark and one white; also trained on
/// pairs of dark mice). Same input, output and keypoints as `kDyadModelName`.
let kDyadBWModelName = "MousePose6DyadBW_960_int8"
/// Group model: YOLO26s pose, 960 × 960, 2–10 dark mice per frame. Same input, output and keypoints as `kDyadModelName`.
let kGroupModelName = "GroupPose6_960_int8"

enum PoseModels {
    /// Every pose model the apps carry, in the order shown in Settings.
    static let all = [kModelName, kWhiteModelName, kDyadModelName, kDyadBWModelName, kGroupModelName]

    /// Model for this many animals of this colour.
    static func name(animalCount: Int, coat: CoatColor) -> String {
        if animalCount > 2 { return kGroupModelName }
        switch coat.valid(for: animalCount) {
        case .dark: return animalCount > 1 ? kDyadModelName : kModelName
        case .white: return kWhiteModelName
        case .darkWhite: return kDyadBWModelName
        }
    }

    /// Model a run with these settings uses.
    static func name(for s: InferenceSettings) -> String { name(animalCount: s.animalCount, coat: s.coat) }

    /// Animals per frame a model is made for (the group model: the default number; its sessions set their own).
    static func animalCount(of model: String) -> Int {
        if model == kGroupModelName { return kGroupDefaultAnimals }
        return model == kDyadModelName || model == kDyadBWModelName ? 2 : 1
    }

    /// Coat colour a model is made for (nil for an unknown name).
    static func coat(of model: String) -> CoatColor? {
        switch model {
        case kModelName, kDyadModelName, kGroupModelName: return .dark
        case kWhiteModelName: return .white
        case kDyadBWModelName: return .darkWhite
        default: return nil
        }
    }

    /// Short interface name, e.g. "MousePose6 · 白鼠".
    static func title(_ model: String) -> String {
        switch model {
        case kModelName: return L10n.tr("MousePose6 · 单鼠")
        case kWhiteModelName: return L10n.tr("WhiteMousePose6 · 白鼠")
        case kDyadModelName: return L10n.tr("MousePose6Dyad · 双鼠")
        case kDyadBWModelName: return L10n.tr("MousePose6DyadBW · 一黑一白")
        case kGroupModelName: return L10n.tr("GroupPose6 · 多鼠")
        default: return model
        }
    }

    /// What the model is for (interface).
    static func detail(_ model: String) -> String {
        switch model {
        case kModelName: return L10n.tr("一只深色小鼠（YOLO26n，960）")
        case kWhiteModelName: return L10n.tr("一只白色小鼠（YOLO26n，960）")
        case kDyadModelName: return L10n.tr("两只深色小鼠（YOLO26s，960）")
        case kDyadBWModelName: return L10n.tr("一黑一白两只小鼠（YOLO26s，960）")
        case kGroupModelName: return L10n.tr("3–10 只深色小鼠（YOLO26s，960）")
        default: return ""
        }
    }
}

// MARK: - Which animal is the dark one (dark–white pairs)

enum CoatOrder {
    /// Index of the darker animal of a two-animal track, from the fur-colour descriptor recorded on each
    /// animal's back (median luminance over the frames where it was detected). nil when the track has no
    /// descriptor or the two animals do not differ clearly in brightness.
    static func darkAnimal(_ track: PoseTrack, minDifference: Float = 0.12) -> Int? {
        guard track.animalCount == 2, track.appearanceDims > 0,
              track.appearance.count >= track.count * 2 * track.appearanceDims else { return nil }
        let d = track.appearanceDims
        var lum: [[Float]] = [[], []]
        for i in 0..<track.count {
            for a in 0..<2 where track.conf(i, a) > kAnalysisMinScore {
                let v = track.appearance[(2 * i + a) * d]
                if v.isFinite { lum[a].append(v) }
            }
        }
        guard lum[0].count >= 10, lum[1].count >= 10 else { return nil }
        func median(_ x: [Float]) -> Float {
            let s = x.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
        let m0 = median(lum[0]), m1 = median(lum[1])
        guard abs(m0 - m1) >= minDifference else { return nil }
        return m0 < m1 ? 0 : 1
    }
}
