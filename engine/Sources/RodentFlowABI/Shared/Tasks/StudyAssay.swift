// StudyAssay.swift — one behavioural task, identified the same way on iPhone / iPad and Mac.
//
// The raw values are stored in Mac workspaces, phone → Mac sync packages and exports. They name the
// method as well as the test: "rodentpose.open_field" (6-keypoint pose model) and
// "rodentflow.open_field" (RodentFlow's classic centroid tracker, the 1.x method) are different tasks
// with different measures, so they are never pooled. Never reuse an id for another method.
//
// Three ways of tracking (TrackingMethod):
//   • classic centroid (RodentFlow 1.x, no model) — rodentflow.*
//   • pose, one animal (MousePose6; WhiteMousePose6 for a white mouse) — most rodentpose.* tasks
//   • pose, two animals (MousePose6Dyad; MousePose6DyadBW for one dark and one white mouse; + identity
//     tracking) — dyadic social, resident–intruder
// The model within a method follows the coat colour chosen for each video (PoseModels.swift); it does not
// change the task.
// plus the multi-chamber tail suspension test (one recording, several animals).

import Foundation

enum TaskModule: String, Codable {
    case pose, flow
}

/// How a task's videos are tracked.
enum TrackingMethod: String, Codable {
    case centroid
    case pose
    case poseTwoAnimals
    case poseGroup
    case multiChamber

    var title: String {
        switch self {
        case .centroid: return L("Classic centroid", "质心法")
        case .pose: return L("Pose · one animal", "单鼠姿态")
        case .poseTwoAnimals: return L("Pose · two animals", "双鼠姿态")
        case .poseGroup: return L("Pose · group", "多鼠姿态")
        case .multiChamber: return L("Multi-chamber", "多格同步")
        }
    }

    var detail: String {
        switch self {
        case .centroid: return L("Background subtraction, body centroid at 10 Hz (RodentFlow 1.x method, no model)",
                                 "背景差分，10 Hz 身体质心（RodentFlow 1.x 方法，不用模型）")
        case .pose: return L("6 keypoints per frame (MousePose6; WhiteMousePose6 for a white mouse)",
                             "逐帧 6 个关键点（MousePose6；白鼠用 WhiteMousePose6）")
        case .poseTwoAnimals: return L("Two-animal model (MousePose6Dyad; MousePose6DyadBW for one dark and one white mouse) with A / B identity tracking",
                                       "双鼠模型（MousePose6Dyad；一黑一白用 MousePose6DyadBW）+ A / B 身份追踪")
        case .poseGroup: return L("Group model (GroupPose6, 3–10 dark mice) with known-count identity tracking", "多鼠模型（GroupPose6，3–10 只深色小鼠）+ 已知只数的身份追踪")
        case .multiChamber: return L("Chambers found automatically, silhouette motion per chamber",
                                     "自动识别格子，逐格轮廓运动评分")
        }
    }

    var symbol: String {
        switch self {
        case .centroid: return "scope"
        case .pose: return "figure.walk"
        case .poseTwoAnimals: return "person.2.fill"
        case .poseGroup: return "person.3.fill"
        case .multiChamber: return "square.grid.3x2"
        }
    }
}

enum StudyAssay: String, Codable, CaseIterable, Identifiable {
    // Pose (RodentPose method)
    case threeChamber = "rodentpose.three_chamber"
    case poseSocialInteraction = "rodentpose.social_interaction"
    case poseDyadicSocial = "rodentpose.dyadic_social"
    case poseResidentIntruder = "rodentpose.resident_intruder"
    case poseGroupBehavior = "rodentpose.group_behavior"
    case poseHeadDirection = "rodentpose.head_direction"
    case poseSpatialExploration = "rodentpose.spatial_exploration"
    case openField = "rodentpose.open_field"
    case elevatedPlusMaze = "rodentpose.epm"
    case poseElevatedZeroMaze = "rodentpose.elevated_zero_maze"
    case poseLightDarkBox = "rodentpose.light_dark_box"
    case poseNoveltySuppressedFeeding = "rodentpose.novelty_suppressed_feeding"
    case poseVisualCliff = "rodentpose.visual_cliff"
    case poseMarbleBurying = "rodentpose.marble_burying"
    case novelObject = "rodentpose.nor"
    case poseBarnesMaze = "rodentpose.barnes_maze"
    case poseMorrisWaterMaze = "rodentpose.morris_water_maze"
    case posePassiveAvoidance = "rodentpose.passive_avoidance"
    case poseStepDown = "rodentpose.step_down"
    case posePlacePreference = "rodentpose.place_preference"
    case poseYMaze = "rodentpose.y_maze"
    case poseTMazeVte = "rodentpose.t_maze_vte"
    case poseFearConditioning = "rodentpose.fear_conditioning"
    case poseLoomingEscape = "rodentpose.looming_escape"
    case posePlatformAvoidance = "rodentpose.platform_avoidance"
    case poseRotation = "rodentpose.rotation"
    case poseOnly = "rodentpose.pose_only"
    // Multi-chamber tail suspension
    case tstMultiChamber = "tstscorer.multi_chamber"
    // Classic centroid (RodentFlow method)
    case flowOpenField = "rodentflow.open_field"
    case flowElevatedPlusMaze = "rodentflow.elevated_plus_maze"
    case flowLightDarkBox = "rodentflow.light_dark_box"
    case flowYMaze = "rodentflow.y_maze"
    case flowTMaze = "rodentflow.t_maze"
    case flowNovelObjectRecognition = "rodentflow.novel_object_recognition"
    case flowMorrisWaterMaze = "rodentflow.morris_water_maze"
    case flowBarnesMaze = "rodentflow.barnes_maze"
    case flowFearConditioning = "rodentflow.fear_conditioning"
    case flowConditionedPlacePreference = "rodentflow.conditioned_place_preference"
    // RodentFlow 1.x results entered by hand or imported from tables (no video). Kept so that
    // results made with RodentFlow 1.x stay usable in group comparisons.
    case flowMarbleBurying = "rodentflow.marble_burying"
    case flowSucrosePreference = "rodentflow.sucrose_preference"
    case flowBeamWalking = "rodentflow.beam_walking"
    case flowGaitAnalysis = "rodentflow.gait_analysis"
    case flowTwoArmedBandit = "rodentflow.two_armed_bandit"
    case flowCustom = "rodentflow.custom"

    var id: String { rawValue }

    // MARK: Identity

    var module: TaskModule? {
        if rawValue.hasPrefix("rodentpose.") { return .pose }
        if rawValue.hasPrefix("rodentflow.") { return .flow }
        return nil
    }

    var paradigm: Paradigm? {
        switch self {
        case .threeChamber: return .threeChamber
        case .poseSocialInteraction: return .socialInteraction
        case .poseDyadicSocial: return .dyadicSocial
        case .poseResidentIntruder: return .residentIntruder
        case .poseGroupBehavior: return .groupBehavior
        case .poseHeadDirection: return .headDirection
        case .poseSpatialExploration: return .spatialExploration
        case .openField: return .openField
        case .elevatedPlusMaze: return .elevatedPlusMaze
        case .poseElevatedZeroMaze: return .elevatedZeroMaze
        case .poseLightDarkBox: return .lightDark
        case .poseNoveltySuppressedFeeding: return .noveltySuppressedFeeding
        case .poseVisualCliff: return .visualCliff
        case .poseMarbleBurying: return .marbleBurying
        case .poseStepDown: return .stepDown
        case .posePlatformAvoidance: return .platformAvoidance
        case .novelObject: return .novelObject
        case .poseBarnesMaze: return .barnesMaze
        case .poseMorrisWaterMaze: return .waterMaze
        case .posePassiveAvoidance: return .passiveAvoidance
        case .posePlacePreference: return .placePreference
        case .poseYMaze: return .yMaze
        case .poseTMazeVte: return .tMaze
        case .poseFearConditioning: return .fearConditioning
        case .poseLoomingEscape: return .looming
        case .poseRotation: return .rotation
        case .poseOnly: return .poseOnly
        default: return nil
        }
    }

    /// The pose task of a paradigm.
    init?(paradigm p: Paradigm) {
        guard let match = StudyAssay.allCases.first(where: { $0.paradigm == p }) else { return nil }
        self = match
    }

    /// RodentFlow assay of a classic-centroid video task (the ten assays that RodentFlow tracks).
    var flowAssay: FlowAssay? {
        switch self {
        case .flowOpenField: return .openField
        case .flowElevatedPlusMaze: return .elevatedPlusMaze
        case .flowLightDarkBox: return .lightDark
        case .flowYMaze: return .yMaze
        case .flowTMaze: return .tMaze
        case .flowNovelObjectRecognition: return .novelObject
        case .flowMorrisWaterMaze: return .morrisWaterMaze
        case .flowBarnesMaze: return .barnesMaze
        case .flowFearConditioning: return .fearConditioning
        case .flowConditionedPlacePreference: return .placePreference
        default: return nil
        }
    }

    /// The classic-centroid task of a RodentFlow assay id ("open_field" → .flowOpenField).
    init?(flowAssayID raw: String) {
        guard let match = StudyAssay(rawValue: "rodentflow." + raw) else { return nil }
        self = match
    }

    var trackingMethod: TrackingMethod? {
        if self == .tstMultiChamber { return .multiChamber }
        if let p = paradigm { return p.isGroup ? .poseGroup : (p.animalCount > 1 ? .poseTwoAnimals : .pose) }
        if flowAssay != nil { return .centroid }
        return nil
    }

    var isVideoTask: Bool { trackingMethod != nil }

    /// Pose task and classic task of the same test (for "the same test, the other method").
    var counterpart: StudyAssay? {
        switch self {
        case .openField: return .flowOpenField
        case .flowOpenField: return .openField
        case .elevatedPlusMaze: return .flowElevatedPlusMaze
        case .flowElevatedPlusMaze: return .elevatedPlusMaze
        case .poseLightDarkBox: return .flowLightDarkBox
        case .flowLightDarkBox: return .poseLightDarkBox
        case .poseYMaze: return .flowYMaze
        case .flowYMaze: return .poseYMaze
        case .poseTMazeVte: return .flowTMaze
        case .flowTMaze: return .poseTMazeVte
        case .novelObject: return .flowNovelObjectRecognition
        case .flowNovelObjectRecognition: return .novelObject
        case .poseBarnesMaze: return .flowBarnesMaze
        case .flowBarnesMaze: return .poseBarnesMaze
        case .poseMorrisWaterMaze: return .flowMorrisWaterMaze
        case .flowMorrisWaterMaze: return .poseMorrisWaterMaze
        case .posePlacePreference: return .flowConditionedPlacePreference
        case .flowConditionedPlacePreference: return .posePlacePreference
        case .poseFearConditioning: return .flowFearConditioning
        case .flowFearConditioning: return .poseFearConditioning
        default: return nil
        }
    }

    // MARK: Names

    /// English name (stable; exports and sync files).
    var name: String {
        switch self {
        case .threeChamber: return "Three-Chamber Social Test"
        case .poseSocialInteraction: return "Social Interaction"
        case .poseDyadicSocial: return "Dyadic Social"
        case .poseResidentIntruder: return "Resident–Intruder (Aggression)"
        case .poseGroupBehavior: return "Group Behavior"
        case .poseHeadDirection: return "Head Direction"
        case .poseSpatialExploration: return "Spatial Exploration"
        case .openField: return "Open Field"
        case .elevatedPlusMaze: return "Elevated Plus Maze"
        case .poseElevatedZeroMaze: return "Elevated Zero Maze"
        case .poseLightDarkBox: return "Light–Dark Box"
        case .poseNoveltySuppressedFeeding: return "Novelty-Suppressed Feeding"
        case .poseVisualCliff: return "Visual Cliff"
        case .poseMarbleBurying: return "Marble Burying (video)"
        case .poseStepDown: return "Step-Down Inhibitory Avoidance"
        case .posePlatformAvoidance: return "Platform-Mediated Avoidance"
        case .novelObject: return "Novel Object Recognition"
        case .poseBarnesMaze: return "Barnes Maze"
        case .poseMorrisWaterMaze: return "Morris Water Maze"
        case .posePassiveAvoidance: return "Passive Avoidance"
        case .posePlacePreference: return "Place Preference (RTPP / CPP)"
        case .poseYMaze: return "Y-Maze"
        case .poseTMazeVte: return "T-Maze with VTE"
        case .poseFearConditioning: return "Fear Conditioning"
        case .poseLoomingEscape: return "Looming Escape"
        case .poseRotation: return "Rotation"
        case .poseOnly: return "Pose Tracking Only"
        case .tstMultiChamber: return "Tail Suspension Test — Multi-Chamber"
        case .flowOpenField: return "Open Field / Center"
        case .flowElevatedPlusMaze: return "Elevated Plus Maze"
        case .flowLightDarkBox: return "Light–Dark Box"
        case .flowYMaze: return "Y-Maze"
        case .flowTMaze: return "T-Maze"
        case .flowNovelObjectRecognition: return "Novel Object Recognition"
        case .flowMorrisWaterMaze: return "Morris Water Maze"
        case .flowBarnesMaze: return "Barnes Maze"
        case .flowFearConditioning: return "Fear Conditioning"
        case .flowConditionedPlacePreference: return "Conditioned Place Preference"
        case .flowMarbleBurying: return "Marble Burying"
        case .flowSucrosePreference: return "Sucrose Preference"
        case .flowBeamWalking: return "Beam Walking"
        case .flowGaitAnalysis: return "Gait Analysis"
        case .flowTwoArmedBandit: return "Two-Armed Bandit"
        case .flowCustom: return "Other / custom table"
        }
    }

    /// Interface name in the current language.
    var displayName: String {
        if self == .tstMultiChamber { return L("TST · Multi-Chamber", "悬尾实验 · 多格同步评分") }
        if let p = paradigm { return p.title }
        switch self {
        case .flowOpenField: return L("Open Field", "旷场")
        case .flowElevatedPlusMaze: return L("Elevated Plus Maze", "高架十字迷宫")
        case .flowLightDarkBox: return L("Light–Dark Box", "明暗箱")
        case .flowYMaze: return L("Y-Maze", "Y 迷宫")
        case .flowTMaze: return L("T-Maze", "T 迷宫")
        case .flowNovelObjectRecognition: return L("Novel Object Recognition", "新物体识别")
        case .flowMorrisWaterMaze: return L("Morris Water Maze", "Morris 水迷宫")
        case .flowBarnesMaze: return L("Barnes Maze", "Barnes 迷宫")
        case .flowFearConditioning: return L("Fear Conditioning", "恐惧条件化")
        case .flowConditionedPlacePreference: return L("Conditioned Place Preference", "条件性位置偏好")
        case .flowMarbleBurying: return L("Marble Burying", "埋珠实验")
        case .flowSucrosePreference: return L("Sucrose Preference", "糖水偏好")
        case .flowBeamWalking: return L("Beam Walking", "平衡木")
        case .flowGaitAnalysis: return L("Gait Analysis", "步态分析")
        case .flowTwoArmedBandit: return L("Two-Armed Bandit", "双臂老虎机任务")
        case .flowCustom: return L("Other / custom table", "其他 / 自定义表格")
        default: return name
        }
    }

    /// Name with the method, for lists that mix methods ("旷场 · 质心法").
    var displayNameWithMethod: String {
        guard let m = trackingMethod else { return displayName }
        return displayName + " · " + m.title
    }

    var symbol: String {
        if self == .tstMultiChamber { return "figure.stand" }
        if let p = paradigm { return p.symbol }
        switch self {
        case .flowOpenField: return "square.dashed"
        case .flowElevatedPlusMaze: return "plus"
        case .flowLightDarkBox: return "lightbulb.min"
        case .flowYMaze, .flowTMaze: return "arrow.triangle.branch"
        case .flowNovelObjectRecognition: return "cube"
        case .flowMorrisWaterMaze: return "drop"
        case .flowBarnesMaze: return "circle.grid.cross"
        case .flowFearConditioning: return "bolt.heart"
        case .flowConditionedPlacePreference: return "rectangle.split.2x1"
        default: return "tablecells"
        }
    }

    /// One-line description of how this task is measured.
    var methodCaption: String { trackingMethod?.detail ?? L("Values entered or imported (no video)", "手动录入或导入的数值（无视频）") }

    // MARK: Phases, days, trials (follow the original app of each method)

    var phaseOptions: [PhaseOption] {
        if let p = paradigm { return p.phases }
        if let f = flowAssay { return f.phases.map { PhaseOption(key: $0, title: FlowAssay.phaseTitle($0)) } }
        return []
    }

    /// Pose tasks accept the researcher's own phase labels when the paradigm has no fixed phases.
    var allowsFreePhase: Bool { paradigm != nil && phaseOptions.isEmpty }

    var defaultPhase: String {
        if let p = paradigm { return p.phases.first?.key ?? "" }
        if let f = flowAssay { return f.defaultPhase }
        return ""
    }

    var usesDay: Bool { paradigm != nil || (flowAssay?.usesDays ?? false) }
    var usesTrial: Bool { paradigm != nil || (flowAssay?.usesTrials ?? false) }
    var usesSex: Bool { true }
    var usesNotes: Bool { module == .pose || self == .tstMultiChamber }

    func phaseTitle(_ key: String) -> String {
        if let p = paradigm { return p.phaseTitle(key) }
        if flowAssay != nil || module == .flow { return FlowAssay.phaseTitle(key) }
        return key
    }

    /// Animals per video (two for the dyadic social tasks; TST counts chambers separately).
    var animalsPerVideo: Int { paradigm?.animalCount ?? 1 }
}
