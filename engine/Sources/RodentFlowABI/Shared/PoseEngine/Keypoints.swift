// Keypoints.swift — the six keypoints predicted by the pose models and the skeleton.

import Foundation

/// Single-animal model (unchanged).
let kModelName = "MousePose6_960_int8"
/// Two-animal model: same input, output and keypoints as `kModelName` (YOLO26s pose, 960 × 960,
/// end-to-end [1, 300, 24]), trained with every mouse in a frame labelled and close contacts
/// oversampled. Used for two dark mice. The white-mouse and dark–white models: PoseModels.swift.
let kDyadModelName = "MousePose6Dyad_960_int8"

/// Model a run uses for this many animals of this coat colour (PoseModels.swift).
func preferredModelName(animalCount: Int, coat: CoatColor = .dark) -> String {
    PoseModels.name(animalCount: animalCount, coat: coat)
}
let kKeypointNames = ["nose", "left_ear", "right_ear", "neck", "body_center", "tail_base"]
let kKeypointCount = 6
let kBones: [(Int, Int)] = [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 5)]

enum KP: Int, CaseIterable, Identifiable {
    case nose = 0, leftEar, rightEar, neck, bodyCenter, tailBase

    var id: Int { rawValue }
    var key: String { kKeypointNames[rawValue] }

    var title: String {
        switch self {
        case .nose: return L10n.tr("鼻尖")
        case .leftEar: return L10n.tr("左耳")
        case .rightEar: return L10n.tr("右耳")
        case .neck: return L10n.tr("颈部")
        case .bodyCenter: return L10n.tr("身体中心")
        case .tailBase: return L10n.tr("尾根")
        }
    }

    /// Short label drawn next to keypoints in the legend.
    var short: String {
        switch self {
        case .nose: return "N"
        case .leftEar: return "LE"
        case .rightEar: return "RE"
        case .neck: return "Nk"
        case .bodyCenter: return "B"
        case .tailBase: return "T"
        }
    }
}
