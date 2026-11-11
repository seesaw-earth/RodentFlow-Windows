// Paradigms.swift — catalog of behavioral paradigms that benefit from keypoint (pose) data.
// One place defines, for every paradigm: names, category, what is measured and why pose helps,
// setup hints, arena types, phases, markers to place, defaults and literature.

import Foundation

// MARK: - Arena kinds

enum ArenaKind: String, Codable, CaseIterable, Identifiable {
    case none, rectangle, circle, plusMaze, yMaze, tMaze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L10n.tr("不标定（像素）")
        case .rectangle: return L10n.tr("矩形场地")
        case .circle: return L10n.tr("圆形场地")
        case .plusMaze: return L10n.tr("十字迷宫")
        case .yMaze: return L10n.tr("Y 迷宫")
        case .tMaze: return L10n.tr("T 迷宫")
        }
    }

    var symbol: String {
        switch self {
        case .none: return "viewfinder"
        case .rectangle: return "square.dashed"
        case .circle: return "circle.dashed"
        case .plusMaze: return "plus"
        case .yMaze: return "arrow.triangle.branch"
        case .tMaze: return "arrow.triangle.turn.up.right.diamond"
        }
    }

    /// Labels of the calibration handles for maze arenas.
    var mazeLabels: [String] {
        switch self {
        case .plusMaze: return ["C", "N", "E", "S", "W"]
        case .yMaze: return ["J", "A", "B", "C"]
        case .tMaze: return ["J", "S", "L", "R"]
        default: return []
        }
    }
}

// MARK: - Category

enum ParadigmCategory: String, CaseIterable, Codable, Identifiable {
    case social, navigation, anxiety, memory, motor, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .social: return L10n.tr("社交行为")
        case .navigation: return L10n.tr("空间导航 · 神经记录")
        case .anxiety: return L10n.tr("焦虑与风险评估")
        case .memory: return L10n.tr("学习、记忆与恐惧")
        case .motor: return L10n.tr("运动功能")
        case .general: return L10n.tr("通用")
        }
    }

    var english: String {
        switch self {
        case .social: return "Social behavior"
        case .navigation: return "Navigation & neural recording"
        case .anxiety: return "Anxiety & risk assessment"
        case .memory: return "Learning, memory & fear"
        case .motor: return "Motor function"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .social: return "person.2.fill"
        case .navigation: return "location.north.circle.fill"
        case .anxiety: return "exclamationmark.shield.fill"
        case .memory: return "brain.head.profile"
        case .motor: return "arrow.clockwise.circle.fill"
        case .general: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Supporting types

struct MeasureInfo: Hashable {
    let name: String
    let definition: String
}

struct PaperRef: Hashable {
    let citation: String
    let doi: String?

    var url: URL? { doi.flatMap { URL(string: "https://doi.org/\($0)") } }
}

struct PhaseOption: Hashable, Identifiable {
    let key: String     // stored / exported (English for presets, verbatim for the user's own labels)
    let title: String   // shown
    var id: String { key }
}

/// The researcher's own phase / condition labels per paradigm (e.g. "Day 1", "Baseline", or any
/// experimental condition), offered next to the presets. Stored on this device only.
enum PhaseLibrary {
    static let maxCount = 24
    static let maxLength = 40

    private static func key(_ p: Paradigm) -> String { "customPhases." + p.rawValue }

    static func labels(for p: Paradigm) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(p)) ?? []
    }

    /// Cleans a typed label; nil when nothing usable is left.
    static func clean(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty else { return nil }
        return String(t.prefix(maxLength))
    }

    static func add(_ label: String, for p: Paradigm) {
        var list = labels(for: p)
        guard !list.contains(label), !p.isPresetPhase(label) else { return }
        list.append(label)
        UserDefaults.standard.set(Array(list.suffix(maxCount)), forKey: key(p))
    }

    static func remove(_ label: String, for p: Paradigm) {
        let list = labels(for: p).filter { $0 != label }
        UserDefaults.standard.set(list, forKey: key(p))
    }
}

struct MarkerSpec: Hashable, Identifiable {
    let key: String
    let label: String
    let title: String
    var id: String { key }
}

// MARK: - Paradigm

enum Paradigm: String, CaseIterable, Codable, Identifiable {
    case threeChamber = "three_chamber"
    case socialInteraction = "social_interaction"
    case dyadicSocial = "dyadic_social"
    case residentIntruder = "resident_intruder"
    case groupBehavior = "group_behavior"
    case headDirection = "head_direction"
    case spatialExploration = "spatial_exploration"
    case openField = "open_field"
    case elevatedPlusMaze = "elevated_plus_maze"
    case elevatedZeroMaze = "elevated_zero_maze"
    case lightDark = "light_dark_box"
    case noveltySuppressedFeeding = "novelty_suppressed_feeding"
    case visualCliff = "visual_cliff"
    case marbleBurying = "marble_burying"
    case novelObject = "novel_object_recognition"
    case barnesMaze = "barnes_maze"
    case waterMaze = "morris_water_maze"
    case passiveAvoidance = "passive_avoidance"
    case stepDown = "step_down"
    case placePreference = "place_preference"
    case yMaze = "y_maze"
    case tMaze = "t_maze_vte"
    case fearConditioning = "fear_conditioning"
    case looming = "looming_escape"
    case platformAvoidance = "platform_avoidance"
    case rotation = "rotation"
    case poseOnly = "pose_only"

    var id: String { rawValue }

    /// Robust decoding: unknown ids from a newer build fall back to `.poseOnly`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Paradigm(rawValue: raw) ?? .poseOnly
    }

    static func inCategory(_ c: ParadigmCategory) -> [Paradigm] { allCases.filter { $0.category == c } }

    var category: ParadigmCategory {
        switch self {
        case .threeChamber, .socialInteraction, .dyadicSocial, .residentIntruder, .groupBehavior: return .social
        case .headDirection, .spatialExploration: return .navigation
        case .openField, .elevatedPlusMaze, .elevatedZeroMaze, .lightDark, .noveltySuppressedFeeding, .visualCliff, .marbleBurying: return .anxiety
        case .novelObject, .barnesMaze, .waterMaze, .passiveAvoidance, .stepDown, .placePreference, .yMaze, .tMaze, .fearConditioning, .looming,
             .platformAvoidance: return .memory
        case .rotation: return .motor
        case .poseOnly: return .general
        }
    }

    var title: String {
        switch self {
        case .threeChamber: return L10n.tr("三箱社交")
        case .socialInteraction: return L10n.tr("社交回避测试")
        case .dyadicSocial: return L10n.tr("双鼠社交互动")
        case .groupBehavior: return L10n.tr("群体行为")
        case .residentIntruder: return L10n.tr("居住者–入侵者（攻击）")
        case .headDirection: return L10n.tr("头朝向")
        case .spatialExploration: return L10n.tr("空间探索 · 位置细胞")
        case .openField: return L10n.tr("旷场")
        case .elevatedPlusMaze: return L10n.tr("高架十字迷宫")
        case .elevatedZeroMaze: return L10n.tr("高架零迷宫")
        case .lightDark: return L10n.tr("明暗箱")
        case .noveltySuppressedFeeding: return L10n.tr("新奇抑制摄食")
        case .visualCliff: return L10n.tr("视觉悬崖")
        case .marbleBurying: return L10n.tr("埋珠实验")
        case .stepDown: return L10n.tr("Step-down 抑制性回避")
        case .platformAvoidance: return L10n.tr("平台介导回避")
        case .novelObject: return L10n.tr("新物体识别")
        case .barnesMaze: return L10n.tr("Barnes 迷宫")
        case .waterMaze: return L10n.tr("Morris 水迷宫")
        case .passiveAvoidance: return L10n.tr("被动回避（穿梭箱）")
        case .placePreference: return L10n.tr("位置偏好（RTPP / CPP）")
        case .yMaze: return L10n.tr("Y 迷宫自发交替")
        case .tMaze: return L10n.tr("T 迷宫 · VTE")
        case .fearConditioning: return L10n.tr("恐惧条件化")
        case .looming: return L10n.tr("Looming 逃跑")
        case .rotation: return L10n.tr("旋转行为")
        case .poseOnly: return L10n.tr("仅导出姿态")
        }
    }

    var englishName: String {
        switch self {
        case .threeChamber: return "Three-Chamber Sociability"
        case .socialInteraction: return "Social Interaction Test (CSDS)"
        case .dyadicSocial: return "Dyadic Social Interaction"
        case .groupBehavior: return "Group Behavior"
        case .residentIntruder: return "Resident–Intruder (Aggression)"
        case .headDirection: return "Head Direction"
        case .spatialExploration: return "Spatial Exploration (Place / Grid Cells)"
        case .openField: return "Open Field"
        case .elevatedPlusMaze: return "Elevated Plus Maze"
        case .elevatedZeroMaze: return "Elevated Zero Maze"
        case .lightDark: return "Light–Dark Box"
        case .noveltySuppressedFeeding: return "Novelty-Suppressed Feeding"
        case .visualCliff: return "Visual Cliff"
        case .marbleBurying: return "Marble Burying"
        case .stepDown: return "Step-Down Inhibitory Avoidance"
        case .platformAvoidance: return "Platform-Mediated Avoidance"
        case .novelObject: return "Novel Object Recognition"
        case .barnesMaze: return "Barnes Maze"
        case .waterMaze: return "Morris Water Maze"
        case .passiveAvoidance: return "Passive Avoidance (Step-Through)"
        case .placePreference: return "Place Preference (RTPP / CPP)"
        case .yMaze: return "Y-Maze Spontaneous Alternation"
        case .tMaze: return "T-Maze Choice & VTE"
        case .fearConditioning: return "Fear Conditioning (Freezing)"
        case .looming: return "Looming Threat Escape"
        case .rotation: return "Rotation (unilateral lesion)"
        case .poseOnly: return "Pose Only"
        }
    }

    /// Short English label, also used in exported file names.
    var shortName: String {
        switch self {
        case .threeChamber: return "3CH"
        case .socialInteraction: return "SI"
        case .dyadicSocial: return "Dyad"
        case .groupBehavior: return "Group"
        case .residentIntruder: return "RI"
        case .headDirection: return "HD"
        case .spatialExploration: return "Place"
        case .openField: return "OF"
        case .elevatedPlusMaze: return "EPM"
        case .elevatedZeroMaze: return "EZM"
        case .lightDark: return "LDB"
        case .noveltySuppressedFeeding: return "NSF"
        case .visualCliff: return "VC"
        case .marbleBurying: return "MB"
        case .stepDown: return "SD"
        case .platformAvoidance: return "PMA"
        case .novelObject: return "NOR"
        case .barnesMaze: return "Barnes"
        case .waterMaze: return "MWM"
        case .passiveAvoidance: return "PA"
        case .placePreference: return "PlacePref"
        case .yMaze: return "YMaze"
        case .tMaze: return "VTE"
        case .fearConditioning: return "Fear"
        case .looming: return "Loom"
        case .rotation: return "Rotation"
        case .poseOnly: return "Pose"
        }
    }

    var symbol: String {
        switch self {
        case .threeChamber: return "rectangle.split.3x1"
        case .socialInteraction: return "person.fill.viewfinder"
        case .dyadicSocial: return "person.2"
        case .groupBehavior: return "person.3"
        case .residentIntruder: return "flame"
        case .headDirection: return "location.north.circle"
        case .spatialExploration: return "map"
        case .openField: return "square.dashed"
        case .elevatedPlusMaze: return "plus"
        case .elevatedZeroMaze: return "circle.circle"
        case .lightDark: return "circle.lefthalf.filled"
        case .noveltySuppressedFeeding: return "fork.knife"
        case .visualCliff: return "square.split.2x1"
        case .marbleBurying: return "circle.grid.3x3.fill"
        case .stepDown: return "arrow.down.to.line"
        case .platformAvoidance: return "square.bottomhalf.filled"
        case .novelObject: return "cube"
        case .barnesMaze: return "circle.dotted"
        case .waterMaze: return "water.waves"
        case .passiveAvoidance: return "door.left.hand.closed"
        case .placePreference: return "rectangle.split.2x1"
        case .yMaze: return "arrow.triangle.branch"
        case .tMaze: return "arrow.triangle.turn.up.right.diamond"
        case .fearConditioning: return "bolt.heart"
        case .looming: return "bird"
        case .rotation: return "arrow.clockwise.circle"
        case .poseOnly: return "point.3.connected.trianglepath.dotted"
        }
    }

    var tagline: String {
        switch self {
        case .threeChamber: return L10n.tr("社交偏好与社交新颖性 · 鼻尖嗅探判定")
        case .socialInteraction: return L10n.tr("慢性社会挫败后的社交回避 · SI ratio")
        case .dyadicSocial: return L10n.tr("两只自由活动小鼠 · 鼻对鼻、肛殖区嗅探、跟随")
        case .groupBehavior: return L10n.tr("3–10 只深色小鼠 · 接触、聚集、最近邻距离、等级（预览）")
        case .residentIntruder: return L10n.tr("攻击潜伏期、次数、时长 · 追逐、压制、威胁、骑跨")
        case .headDirection: return L10n.tr("HD 细胞记录配套 · 头朝向占据与角速度")
        case .spatialExploration: return L10n.tr("占据图、覆盖度与速度 · 神经记录同步")
        case .openField: return L10n.tr("运动与焦虑样行为 · 中央区、四角区、转圈、静止")
        case .elevatedPlusMaze: return L10n.tr("开放臂探索 + 探头 + 伸展评估姿势")
        case .elevatedZeroMaze: return L10n.tr("开放段时间 + 内外缘头探 + 闭合段探出与伸展评估")
        case .lightDark: return L10n.tr("明箱时间、穿梭 + 探头风险评估")
        case .noveltySuppressedFeeding: return L10n.tr("进食潜伏期（人工确认、截尾）· 接近食物 · 家笼摄食对照")
        case .visualCliff: return L10n.tr("首次选择 · 深侧时间 · 边缘探头")
        case .marbleBurying: return L10n.tr("埋住的珠子数（按每颗珠子被盖住的程度）· 埋珠事件 · 接近珠子")
        case .stepDown: return L10n.tr("下台潜伏期（截尾）· 平台上僵直 · 边缘探头")
        case .platformAvoidance: return L10n.tr("平台时间 · 上平台潜伏期 · 平台上 / 外僵直")
        case .novelObject: return L10n.tr("鼻尖距离 + 朝向判定探索 · 辨别指数")
        case .barnesMaze: return L10n.tr("以鼻尖探洞计错误数 · 潜伏期与路径")
        case .waterMaze: return L10n.tr("逃避潜伏期、路径与搜索策略 · 探索测试看平均距离与象限")
        case .passiveAvoidance: return L10n.tr("进入暗室潜伏期（截尾）· 反向探头风险评估")
        case .placePreference: return L10n.tr("配对侧时间与偏好分数 · 前后测自动配对")
        case .yMaze: return L10n.tr("工作记忆 · 交替率与探头未进入")
        case .tMaze: return L10n.tr("选择点头部扫视（替代性试错）")
        case .fearConditioning: return L10n.tr("关键点僵直检测 · 按 CS 分段")
        case .looming: return L10n.tr("头顶扩张黑影 → 逃回巢穴或僵直")
        case .rotation: return L10n.tr("单侧损伤模型 · 同侧 / 对侧整圈数")
        case .poseOnly: return L10n.tr("逐帧 6 个关键点 + 运动学 · 自定义分析")
        }
    }

    var summary: String {
        switch self {
        case .threeChamber:
            return L10n.tr("实验鼠在三个相连的箱室中自由探索，两侧各放一个铁丝杯。社交偏好阶段一侧杯内是陌生鼠，另一侧为空杯或物体；社交新颖性阶段一侧是熟悉鼠，另一侧换成新的陌生鼠。经典读数是各箱室的停留时间和对两个杯子的嗅探时间。")
        case .socialInteraction:
            return L10n.tr("慢性社会挫败应激（CSDS）模型的标准读数。实验鼠在旷场中探索两次，每次 150 s：第一次网罩内为空（无目标），第二次放入陌生的攻击鼠（有目标）。比较两次在网罩周围互动区的停留时间，SI ratio < 1 通常归为易感。")
        case .dyadicSocial:
            return L10n.tr("两只小鼠在同一场地自由互动，例如青少年社交、居住者-入侵者测试中的非攻击部分、雌雄互动。读数是各类嗅探与跟随行为的时间和次数。")
        case .groupBehavior:
            return L10n.tr("3–10 只小鼠在同一场地自由活动，不需要标记。读数是群体层面的接触比例、最近邻距离、聚集团大小和活动量，以及接近–回避事件和由它们算出的等级。")
        case .residentIntruder:
            return L10n.tr("把一只陌生的 intruder 放进 resident 的饲养笼，通常观察 10 min。读数是攻击潜伏期、攻击次数和时长，以及追逐、压制、威胁姿势和骑跨等攻击相关行为；嗅探和跟随作为非攻击性社交一并给出。")
        case .headDirection:
            return L10n.tr("记录头朝向细胞（ADN、后下托、压后皮层等）时，需要每一帧动物头部在环境中的朝向，以及每个方向上的停留时间（占据），用来归一化调谐曲线；角速度（AHV）用于分析 AHV 细胞和调谐的速度依赖性。")
        case .spatialExploration:
            return L10n.tr("位置细胞、网格细胞记录通常让动物在开放场地中觅食数十分钟。分析放电野之前要先看占据是否均匀、覆盖度是否足够，并按速度阈值（如 > 2 cm/s）去掉静止时段。")
        case .openField:
            return L10n.tr("最常用的自发活动与焦虑样行为测试：动物在方形或圆形场地中自由探索 5–30 min，读数包括总路程、中央区时间和进入次数，方形场地还有四角区时间。")
        case .elevatedPlusMaze:
            return L10n.tr("两条开放臂与两条闭合臂交叉的高架迷宫，通常测 5 min。开放臂时间和进入次数比例越低，焦虑样行为越强。")
        case .lightDark:
            return L10n.tr("明亮的大箱与黑暗的小箱通过小门相连，测 5–10 min。明箱时间和穿梭次数反映焦虑样行为。")
        case .elevatedZeroMaze:
            return L10n.tr("环形高架平台分成四段等长的区段：两段相对的闭合段有墙，两段开放段没有墙。没有高架十字迷宫的中央区，动物可以不间断地绕圈探索，常测 5 min。开放段时间比例和头探越少、闭合段内的伸展评估越多，焦虑样行为越强；重复测试时比高架十字迷宫更稳定。")
        case .noveltySuppressedFeeding:
            return L10n.tr("禁食（常为 24 h）后的小鼠被放进明亮的新环境，中央放一粒食物。新环境抑制进食，首次咬食的潜伏期反映焦虑样行为，慢性（而非急性）抗抑郁药会缩短它。截止时间常为 10 min；测试后立即测家笼 5 min 摄食量和体重下降，排除食欲差异。")
        case .visualCliff:
            return L10n.tr("透明玻璃（或透明底）盖住整个场地：一侧图案紧贴玻璃下方（浅侧），另一侧图案远在下方（深侧），看起来像一个落差。小鼠从中间的平台或中性区出发，有深度知觉的小鼠多选浅侧、少去深侧。表型筛查版（JAX）在透明底的旷场里录 20 min，另报前 4 min。读数为首次选择、深 / 浅侧时间、进入深侧的潜伏期和边缘探头。")
        case .marbleBurying:
            return L10n.tr("约 5 cm 厚的平整垫料上排列 20 颗玻璃珠，小鼠单独待 30 min（也有 15 或 20 min），结束时数被垫料盖住（常用标准：2/3 以上）的珠子。常用于强迫样、重复性挖掘行为和抗焦虑药筛选，但它到底测什么仍有争议。RodentFlow 在视频里逐颗读取珠子被盖住的程度，结合追踪只在小鼠离开后取样，得到每颗珠子何时被埋，并给出接近珠子的次数和时间。")
                + L(" RodentFlow counts a marble as buried when ≥ 67 % of its top-view visible area is covered (adjustable), which is stricter than the by-eye 2/3 rule (about 90 % burial by depth).",
                    "RodentFlow 默认在可见面积被盖住 ≥ 67% 时记为埋住（可调），比肉眼按表面 2/3 判断更严格（约相当于按深度埋住 90%）。")
        case .stepDown:
            return L10n.tr("小鼠被放在电网中央的小平台上。训练时四爪都踏到电网即给足底电击；间隔一段时间（常为 24 h）后再放回平台，测下台潜伏期，截止时间常为 180 或 300 s。潜伏期越长，表示越记得下台与电击的关联；测试 / 训练潜伏期之比可作为记忆保持指数。")
        case .platformAvoidance:
            return L10n.tr("小鼠先学会声音预示足底电击，再学会走到场地一角的安全平台上躲开电击（电击在声音的最后 2 s）；在电击前上平台并待到电击结束即成功回避，代价是离开奖励口。声音、电击和奖励由各自的设备控制和记录；RodentFlow 给出追踪能算的部分：平台时间、上平台次数和潜伏期、平台上和平台外的僵直，以及逐帧的“在平台上”标记，可按设备记录的声音时间自行切分每个试次。")
        case .novelObject:
            return L10n.tr("训练期探索两个相同物体，间隔一段时间后把其中一个换成新物体。啮齿类天生偏好新物体，辨别指数 DI 反映识别记忆。移动物体位置即为物体位置记忆（OLM）。")
        case .barnesMaze:
            return L10n.tr("圆形平台边缘有一圈洞，只有目标洞下有逃逸箱。动物借助墙上的空间线索学习目标位置。读数为找到目标洞的潜伏期、错误数和路径长度；探索测试中看目标象限时间。")
        case .waterMaze:
            return L10n.tr("小鼠在注满不透明水的圆形水池中游泳，借助池外的空间线索寻找水面下的隐藏平台。学习期看逃避潜伏期、路径长度和搜索策略的进步；探索测试撤去平台，看小鼠是否集中在原平台附近搜索（平均距原平台距离、目标象限时间、穿越次数）。可见平台试次用来排除视觉和运动问题。")
        case .passiveAvoidance:
            return L10n.tr("明暗两室之间有门。训练时小鼠一进入暗室就给足底电击；间隔一段时间（常为 24 h）后再放回明室，测进入暗室的潜伏期，截止时间常为 300 s。潜伏期越长，表示越记得暗室与电击的关联。")
        case .placePreference:
            return L10n.tr("实时位置偏好（RTPP）：动物在两侧之间自由活动，进入其中一侧即给予刺激（如光遗传），测对该侧的偏好或回避。条件性位置偏好（CPP）：前测 → 一侧与药物或奖赏配对的条件化 → 后测，比较后测与前测在配对侧的时间。")
        case .yMaze:
            return L10n.tr("三条臂互成 120°，动物自由探索约 8 min。连续三次进入三条不同的臂记为一次交替，交替率 = 交替次数 ÷（总进入次数 − 2）。")
        case .tMaze:
            return L10n.tr("动物在选择点停下，头部在两侧之间来回摆动，称为替代性试错（VTE），反映决策时的权衡。经典量化方法是通过选择点时朝向的累计绝对变化 IdPhi，并在每次会话内做 z 标准化。")
        case .fearConditioning:
            return L10n.tr("声音（CS）与足底电击配对后，在相同情境或新情境中重放 CS，测量僵直（除呼吸外完全不动）所占的百分比。")
        case .looming:
            return L10n.tr("动物头顶的屏幕呈现快速扩大的黑色圆盘（模拟俯冲的捕食者），小鼠通常在一秒内逃回庇护所或原地僵直。读数是反应潜伏期、是否逃回巢穴、逃跑速度和僵直。")
        case .rotation:
            return L10n.tr("单侧损伤或其他单侧操作后，动物常表现出偏向一侧的旋转。按身体轴向统计同侧与对侧整圈数，净旋转数用于量化左右不对称的程度，或比较不同实验条件。")
        case .poseOnly:
            return L10n.tr("不做范式分析，只输出逐帧关键点和派生运动学（速度、头朝向、身体轴向等），用于自己的分析流程（如 Keypoint-MoSeq、B-SOiD、SimBA）。")
        }
    }

    var whyPose: String {
        switch self {
        case .threeChamber:
            return L10n.tr("质心追踪只能判断动物在哪个箱室。真正的社交接触是鼻尖贴近杯子并朝向它。RodentFlow 用鼻尖到杯子的距离加头朝向判定嗅探，并排除爬到杯子上的帧，更接近人工计分。")
        case .socialInteraction:
            return L10n.tr("除了身体中心在互动区的时间，RodentFlow 还给出鼻尖在网罩附近的嗅探时间，帮助区分主动探索和路过；同一只鼠的两个阶段会自动配对，计算 SI ratio。")
        case .dyadicSocial:
            return L10n.tr("社交接触由身体部位之间的距离定义：鼻尖–鼻尖、鼻尖–尾根（肛殖区）、鼻尖–身体。这需要每只鼠的多个关键点，用质心无法区分。")
        case .groupBehavior:
            return L10n.tr("接触和聚集由身体各部位之间的距离定义；接近–回避事件需要每只鼠的位置和运动方向。这些都来自 6 个关键点，贴身时比质心稳定。")
        case .residentIntruder:
            return L10n.tr("攻击的特征在运动学里：resident 突然加速扑向对方（接近速度骤升），接触后两鼠高速、方向混乱地翻滚，随后 intruder 逃离或被追逐。RodentFlow 用每只鼠的颈到尾根距离作为体长，以体长为单位计算距离和相对速度，判定攻击、扭打、追逐、压制、侧身威胁、直立和骑跨；不需要标定场地。")
        case .headDirection:
            return L10n.tr("传统方法要在头上装两个 LED。RodentFlow 用两耳中点 → 鼻尖的向量估计头朝向（鼻尖缺失时用颈部 → 鼻尖），不需要标记物，并输出带时间戳的逐帧 HD 和 AHV，可直接与电生理或钙成像数据对齐。")
        case .spatialExploration:
            return L10n.tr("身体中心比质心更稳定（不受尾巴影响），同时还能得到头朝向，便于做位置 × 方向的联合分析。逐帧导出位置、速度和 HD。")
        case .openField:
            return L10n.tr("用身体中心代替质心（不受尾巴影响），另外还能得到按身体轴向计的转圈数、静止时间和身体伸展程度。")
        case .elevatedPlusMaze:
            return L10n.tr("风险评估行为——探头（头伸出开放臂边缘向下看）和伸展评估姿势（身体拉长、后肢不动地向前探）——能提供开放臂时间之外的信息，但只能靠鼻尖位置和身体长度来判断。")
        case .lightDark:
            return L10n.tr("身体留在暗箱、只把头伸进明箱的“探头”是典型的风险评估行为，需要把鼻尖和身体分开判断。")
        case .elevatedZeroMaze:
            return L10n.tr("所在段按身体中心的方位角判断，可要求尾根也进入（近似四爪进入）。头探要求鼻尖越出跑道内缘或外缘而身体留在开放段；闭合段探出是身体和尾根留在闭合段、只把鼻尖伸进开放段；伸展评估姿势用鼻尖–尾根长度。这些都要把鼻尖和身体分开判断，质心法做不到。")
        case .noveltySuppressedFeeding:
            return L10n.tr("标准视频追踪只知道动物在哪里，分不出“到了食物旁”和“开始吃”。RodentFlow 用鼻尖到食物的距离自动给出接近潜伏期和次数，把“鼻尖在食物区、身体几乎不动、持续数秒”标为候选进食放到回看时间轴上；首次进食由你在回看中确认，未确认的结果不进入组间统计。")
        case .visualCliff:
            return L10n.tr("所在侧按身体中心判断，可要求尾根也越过分界（卡在中间板边上时不会来回误计）。身体还在中央或浅侧、只把鼻尖伸向深侧的“边缘探头”是典型的风险评估，只有把鼻尖和身体分开判断才能计数。")
        case .marbleBurying:
            return L10n.tr("珠子是否被盖住要在小鼠不挡住它时才看得清。RodentFlow 用小鼠的关键点（含沿身体轴推算的尾巴位置）判断哪颗珠子此刻没被挡住、小鼠已经离开至少 1 s，只用这些时刻的画面读取珠子的遮盖程度；同一组关键点还给出鼻尖接近每颗珠子的次数和时间。")
        case .stepDown:
            return L10n.tr("“下台”要四爪落到电网上，RodentFlow 默认用身体中心和尾根都离开平台来近似；身体还在平台上、只把鼻尖伸出边缘的探头单独计数，作为下台前的风险评估。")
        case .platformAvoidance:
            return L10n.tr("文献中“在平台上”常按至少两爪在平台上计。RodentFlow 可按身体中心、鼻尖 + 颈部（近似两前爪）或身体中心 + 尾根（近似四爪）判断；僵直用多个关键点的运动指数，头部的小动作不会被当成运动。")
        case .novelObject:
            return L10n.tr("公认的“探索”定义是鼻尖距物体 ≤ 2 cm 且头朝向物体，爬到物体上或背对物体坐着都不算。质心半径法会把路过和坐在旁边也算进去。")
        case .barnesMaze:
            return L10n.tr("Barnes 迷宫的“错误”定义是把鼻子探进非目标洞，这是鼻尖行为，质心追踪无法计数。")
        case .waterMaze:
            return L10n.tr("与旷场相同的逐帧关键点识别，数据处理换成水迷宫的指标。身体中心比质心更稳定（不受尾巴和水花影响）；头朝向可以直接给出入水时是否朝向平台。游泳时尾根常在水下，RodentFlow 用身体中心，缺失时退回到两耳中点或鼻尖；每个试次按 Pathfinder 的规则判定搜索策略。")
        case .passiveAvoidance:
            return L10n.tr("身体留在明室、只把鼻尖伸进暗室再退回，是测试期典型的风险评估，只有把鼻尖和身体分开判断才能计数。进入暗室可按身体中心、身体中心 + 尾根（近似四爪进入）或鼻尖判定。")
        case .placePreference:
            return L10n.tr("所在侧按身体中心判断，可要求尾根也越过分界线，卡在门口时不会来回误计穿越；后测自动与同一只动物的前测配对，直接给出 CPP 分数。")
        case .yMaze:
            return L10n.tr("标准规定四爪都进入臂才算一次进入。RodentFlow 默认要求身体中心和尾根都在臂内（近似四爪进入），并单独统计“只探头、未进入”。")
        case .tMaze:
            return L10n.tr("VTE 本质是头部扫视。RodentFlow 直接用头朝向计算 IdPhi，同时给出基于运动轨迹方向的 IdPhi 作为对照，并统计左右选择与交替。")
        case .fearConditioning:
            return L10n.tr("运动像素法会把呼吸、光照闪烁和相机噪声也算进去。RodentFlow 用鼻尖、两耳中点、身体中心和尾根在 0.5 s 窗口内的位移速度判断僵直，头部的小动作（嗅探、扫视）不会被误判为僵直。")
        case .looming:
            return L10n.tr("刺激出现时的头朝向和到巢穴的方向决定了逃跑路径，是这个范式的重要协变量。RodentFlow 给出每次刺激时头部与巢穴方向的夹角。")
        case .rotation:
            return L10n.tr("旋转计数需要身体轴向（尾根 → 颈部）。RodentFlow 对轴向角度累计计数完整的 360° 转圈，原地小转也能计入，不需要旋转计。")
        case .poseOnly:
            return L10n.tr("保留原始逐帧关键点（像素坐标、置信度），同时附带标定后的厘米坐标和派生特征。")
        }
    }

    var setupTips: [String] {
        var tips = [L10n.tr("摄像头尽量正上方俯拍，画面包含整个场地，光照均匀")]
        switch self {
        case .threeChamber:
            tips += [L10n.tr("标定四个角点并输入三箱内部尺寸"), L10n.tr("把 L / R 手柄拖到两个铁丝杯的中心"), L10n.tr("在参数里选择陌生鼠（或新陌生鼠）所在的一侧")]
        case .socialInteraction:
            tips += [L10n.tr("标定旷场四角，选择网罩靠在哪面墙"), L10n.tr("无目标、有目标两个阶段分别建立分析，编号相同即可自动配对")]
        case .groupBehavior:
            tips += [L10n.tr("俯拍，整个场地在画面内，所有鼠都看得见；这一版只支持深色小鼠"), L10n.tr("建议逐帧识别，帧率 ≥ 25 fps"), L10n.tr("等级需要足够多的事件：每只鼠至少 10 次，最好 20 次，所以录像不要太短"), L10n.tr("编号可能在贴身时互换，也不对应具体动物：要把等级对应到具体动物，需要物理标记或 RFID")]
        case .dyadicSocial:
            tips += [L10n.tr("两只鼠毛色、体型或标记不同时，身份判定最可靠；体色相同时，行走时体长和活动量的稳定差异也会被利用，但最可靠的仍是做标记（尾部记号笔条纹或背部染色）"), L10n.tr("识别时会自动开启双鼠模式，建议逐帧识别"), L10n.tr("在回看中先看“疑似交换”，再按“身份待核对”逐个检查，A / B 不对时点“从这里交换 A / B”")]
        case .residentIntruder:
            tips += [L10n.tr("开始录像后再放入 intruder：放入前只有 resident 的画面用来自动确定谁是 resident 和放入时间"), L10n.tr("必须逐帧识别（一次扑击只有 100–200 ms），帧率 ≥ 25 fps"), L10n.tr("两只鼠毛色或体型不同、或给 intruder 做标记时，身份最可靠"), L10n.tr("回看中核对“攻击”时间轴，必要时在参数中调整阈值")]
        case .headDirection:
            tips += [L10n.tr("可选：把 Q 手柄拖到墙上的提示卡，作为参考方向"), L10n.tr("记录系统与视频的同步偏移需自行对齐（导出 CSV 含逐帧时间戳）")]
        case .spatialExploration:
            tips += [L10n.tr("长时间记录可在设置中选择每 2–3 帧识别一次，以节省时间")]
        case .openField:
            tips += [L10n.tr("中央区默认为场地边长的 50%，可在参数中调整"), L10n.tr("四角区默认为短边的 25%（4 × 4 分格的四个角格），可在参数中调整；圆形场地没有四角区")]
        case .elevatedPlusMaze:
            tips += [L10n.tr("依次拖动 C（中心）和 N / E / S / W 四个臂末端"), L10n.tr("选择开放臂方向（南北或东西）"), L10n.tr("四周留出空间，让探头时鼻尖仍在画面内")]
        case .lightDark:
            tips += [L10n.tr("标定整个箱体，再设置明箱所在侧和所占比例")]
        case .elevatedZeroMaze:
            tips += [L10n.tr("拖动 C（中心）和 R（外缘）标定圆环，输入外径和跑道宽度"), L10n.tr("把 O 手柄拖到任一开放段的中点，确定四段的方向"), L10n.tr("放入时把小鼠放在开闭段交界处、面朝闭合段；“分析时长”常用 300 s"), L10n.tr("四周留出空间，让头探时鼻尖仍在画面内")]
        case .noveltySuppressedFeeding:
            tips += [L10n.tr("标定整个场地，把 F 手柄拖到食物中心"), L10n.tr("“分析起点”设为放入场地的时刻，“分析时长”设为截止时间（常用 600 s）"), L10n.tr("分析后在回看中按“设为首次进食”确认第一口，或“确认截止前未进食”"), L10n.tr("在参数里填写家笼 5 min 摄食量和禁食前、测试前体重，作为饥饿对照")]
        case .visualCliff:
            tips += [L10n.tr("标定玻璃面（或透明底）四角，输入内部尺寸"), L10n.tr("在参数里选择深侧，设置中间板（中性区）的位置和宽度"), L10n.tr("把小鼠放在中间板上；“分析起点”设为放下的时刻"), L10n.tr("棋盘格背景和玻璃反光可能影响识别：先看检出率和回看")]
        case .marbleBurying:
            tips += [L10n.tr("相机固定在笼子正上方，整个测试期间不要移动，光照保持不变"), L10n.tr("把 1–4 号手柄拖到四个角上珠子的中心，在参数里输入行列数和珠子直径；各珠子的圆圈应落在珠子上"), L10n.tr("“分析起点”设为放入小鼠的时刻；放入前的画面最适合做参照，若没有，会用分析起点时的画面"), L10n.tr("珠子和垫料颜色反差越大越好")]
        case .stepDown:
            tips += [L10n.tr("标定整个箱底，把 P 手柄拖到平台中心，在参数里输入平台的宽和高"), L10n.tr("“分析起点”设为把小鼠放上平台的时刻，“分析时长”设为截止时间（常用 180 或 300 s）"), L10n.tr("训练和测试分别建立分析，编号相同时测试会自动和训练配对")]
        case .platformAvoidance:
            tips += [L10n.tr("标定场地四角，输入内部尺寸"), L10n.tr("把 P 手柄拖到平台中心，在参数里输入平台的宽和高"), L10n.tr("需要奖励口区时在参数里打开，再把 R 手柄拖到奖励口"), L10n.tr("逐帧 CSV 的 on_platform、freezing 列用视频时间，可按设备记录的声音时间自行切分每个试次")]
        case .novelObject:
            tips += [L10n.tr("把 A / B 手柄拖到两个物体中心，设置物体半径"), L10n.tr("测试阶段选择哪个是新物体")]
        case .barnesMaze:
            tips += [L10n.tr("拖动 C（中心）和 R（边缘）标定平台"), L10n.tr("把 T 手柄拖到目标洞中心；其余洞按数量均匀排列")]
        case .waterMaze:
            tips += [L10n.tr("拖动 C（中心）和 R（池壁）标定水池，输入水池内径"), L10n.tr("把 P 手柄拖到平台中心；探索测试时放在原平台位置"), L10n.tr("在参数里把“分析起点”设为小鼠入水的时刻，“分析时长”设为最长试次时间（如 60 s）"), L10n.tr("水面反光、池边的实验者等固定干扰，可先用“视频遮挡”盖住再分析")]
        case .passiveAvoidance:
            tips += [L10n.tr("标定整个箱体，再设置明室所在侧和所占比例"), L10n.tr("把“分析起点”设为放入明室（或开门）的时刻，“分析时长”设为截止时间（常用 300 s）"), L10n.tr("训练和测试分别建立分析；组间页对潜伏期自动给出生存分析")]
        case .placePreference:
            tips += [L10n.tr("标定整个装置，在参数里选择配对 / 刺激侧和分界位置"), L10n.tr("两侧之间有中间区时，在参数里打开“中间区”并设置宽度"), L10n.tr("CPP：前测和后测分别建立分析，动物编号相同即自动配对")]
        case .yMaze:
            tips += [L10n.tr("J 为三臂交汇中心，A / B / C 为三个臂末端"), L10n.tr("输入臂长和臂宽（cm）")]
        case .tMaze:
            tips += [L10n.tr("J 为选择点，S 为起始臂末端，L / R 为左右臂末端")]
        case .fearConditioning:
            tips += [L10n.tr("在参数里输入 CS 开始时间（相对于视频开头）和时长"), L10n.tr("红外或灰度视频效果最好")]
        case .looming:
            tips += [L10n.tr("把 S 手柄拖到巢穴（庇护所）中心"), L10n.tr("输入每次刺激出现的时间（相对于视频开头）"), L10n.tr("需要威胁区（刺激下方的区域）时在参数里打开，再把 T 手柄拖到区域中心")]
        case .rotation:
            tips += [L10n.tr("选择损伤侧别；从透明底部仰拍时请打开“从下方拍摄”"), L10n.tr("每 5 min 分段统计"), L10n.tr("实验条件可在“信息”页用 + 添加为自定义标签")]
        case .poseOnly:
            tips += [L10n.tr("不标定时坐标为像素；标定后额外输出厘米坐标")]
        }
        return tips
    }

    /// Definitions with the default parameters (catalog, before a session exists).
    var measures: [MeasureInfo] { measures(AnalysisParams.defaults(for: self)) }

    /// Definitions of the measures; the thresholds that are parameters are taken from `p` (the session's own
    /// parameters on its result guide).
    func measures(_ p: AnalysisParams) -> [MeasureInfo] {
        let n = AnalysisContext.num
        switch self {
        case .threeChamber:
            return [
                MeasureInfo(name: L10n.tr("箱室停留时间"), definition: L10n.tr("身体中心所在箱室（左 / 中 / 右）的累计时间与进入次数。")),
                MeasureInfo(name: L10n.tr("嗅探时间"), definition: L("Nose within \(n(p.exploreMargin)) cm of the cup perimeter, oriented toward it (±\(n(p.headTolerance))°), with the body center off the cup.",
                                                                    "鼻尖在杯子外缘 \(n(p.exploreMargin)) cm 以内、头朝向杯子（±\(n(p.headTolerance))°），且身体中心不在杯子上。")),
                MeasureInfo(name: L10n.tr("社交指数"), definition: L10n.tr("(社交 − 物体) ÷ (社交 + 物体)，按嗅探时间计算；新颖性阶段为 (新 − 熟悉) ÷ (新 + 熟悉)。")),
                MeasureInfo(name: L10n.tr("潜伏期与次数"), definition: L10n.tr("首次嗅探每个杯子的时间、嗅探回合数。"))
            ]
        case .socialInteraction:
            return [
                MeasureInfo(name: L10n.tr("互动区时间"), definition: L("Time the body center spends in the interaction zone around the enclosure (\(n(p.izWidth)) × \(n(p.izDepth)) cm).",
                                                                     "身体中心在网罩周围互动区（\(n(p.izWidth)) × \(n(p.izDepth)) cm）内的时间。")),
                MeasureInfo(name: L10n.tr("角落区时间"), definition: L("Time spent in the two corner zones opposite the enclosure (\(n(p.cornerSize)) × \(n(p.cornerSize)) cm each).",
                                                                     "身体中心在网罩对侧两个角落区（\(n(p.cornerSize)) × \(n(p.cornerSize)) cm）内的时间。")),
                MeasureInfo(name: "SI ratio", definition: L10n.tr("有目标阶段互动区时间 ÷ 无目标阶段互动区时间（同一编号自动配对）。")),
                MeasureInfo(name: L10n.tr("嗅探网罩"), definition: L("Time with the nose within \(n(p.exploreMargin)) cm of the enclosure edge and facing it.",
                                                                    "鼻尖在网罩外缘 \(n(p.exploreMargin)) cm 以内并朝向网罩的时间。"))
            ]
        case .groupBehavior:
            return [
                MeasureInfo(name: L10n.tr("接触比例"), definition: L("Fraction of time a mouse’s body is within \(n(p.groupContactBL)) body lengths of another mouse’s body (mean of all mice).", "一只鼠的身体与其他鼠的身体距离 < \(n(p.groupContactBL)) 体长的时间比例（各鼠平均）。")),
                MeasureInfo(name: L10n.tr("最近邻距离"), definition: L("Mean distance from each mouse to the nearest other mouse (body centers).", "每只鼠到最近一只鼠的身体中心距离的平均。")),
                MeasureInfo(name: L10n.tr("接近–回避事件"), definition: L("One mouse moves toward its nearest neighbour while that neighbour moves away along the same line, lasting ≥ \(n(p.groupApproachMin)) s.", "一只鼠朝最近的鼠移动，对方沿同一方向离开，持续 ≥ \(n(p.groupApproachMin)) s。")),
                MeasureInfo(name: L10n.tr("等级（预览）"), definition: L("David’s score and Elo from approach–avoid events (the approacher wins). Identities can swap when mice touch and do not refer to specific animals.", "由接近–回避事件（接近者为胜）计算 David’s score 和 Elo。贴身时编号可能互换，编号也不对应具体动物。"))
            ]
        case .dyadicSocial:
            return [
                MeasureInfo(name: L10n.tr("鼻–鼻接触"), definition: L("Distance between noses < \(n(p.noseNoseDist)) cm.", "两只鼠鼻尖距离 < \(n(p.noseNoseDist)) cm。")),
                MeasureInfo(name: L10n.tr("肛殖区嗅探"), definition: L("Nose-to-tail-base distance < \(n(p.anogenitalDist)) cm, reported separately for A→B and B→A.",
                                                                     "一只鼠的鼻尖到另一只鼠尾根 < \(n(p.anogenitalDist)) cm（A→B、B→A 分开统计）。")),
                MeasureInfo(name: L10n.tr("身体嗅探"), definition: L("Nose-to-partner body center < \(n(p.bodySniffDist)) cm, excluding the two categories above.",
                                                                   "鼻尖到对方身体中心 < \(n(p.bodySniffDist)) cm，且不属于上面两类。")),
                MeasureInfo(name: L10n.tr("跟随"), definition: L("Distance < \(n(p.followDist)) cm; both speeds > \(n(p.followSpeed)) cm/s; follower oriented toward partner (±\(n(p.followAngle))°) for ≥ \(n(p.followMin)) s.",
                                                               "间距 < \(n(p.followDist)) cm，两鼠速度都 > \(n(p.followSpeed)) cm/s，跟随者朝向对方（±\(n(p.followAngle))°）且持续 ≥ \(n(p.followMin)) s。")),
                MeasureInfo(name: L10n.tr("间距"), definition: L("Mean body-center distance and time spent within \(n(p.proximityDist)) cm.", "身体中心距离的平均值，以及 < \(n(p.proximityDist)) cm 的近距离时间。"))
            ]
        case .residentIntruder:
            return [
                MeasureInfo(name: L10n.tr("攻击潜伏期"), definition: L10n.tr("从 intruder 放入到首次攻击的时间（s）；没有攻击时记为测试时长。")),
                MeasureInfo(name: L10n.tr("攻击次数与时长"), definition: L10n.tr("两鼠贴近、高速且方向混乱的打斗片段（不区分发起者）：次数、总时长、平均时长；扭打（原地翻滚）单独给出。")),
                MeasureInfo(name: L10n.tr("其他攻击性行为"), definition: L10n.tr("追逐、压制、侧身威胁、攻击性直立的总时长，与攻击本身分开。")),
                MeasureInfo(name: L10n.tr("攻击鼠百分比"), definition: L10n.tr("每次测试给出“发生攻击”（0 / 1）；汇总表中一组的平均值 × 100。")),
                MeasureInfo(name: L10n.tr("社交探索"), definition: L10n.tr("肛殖区嗅探、鼻–鼻接触、跟随（不能单独算作攻击）；骑跨单独统计。"))
            ]
        case .headDirection:
            return [
                MeasureInfo(name: L10n.tr("头朝向 HD"), definition: L10n.tr("两耳中点 → 鼻尖向量的方向；0° = 画面右方（或提示卡方向），逆时针为正。")),
                MeasureInfo(name: L10n.tr("HD 占据"), definition: L("Dwell time in \(n(p.hdBinDeg))° direction bins for tuning-curve normalization.", "每 \(n(p.hdBinDeg))° 一格的停留时间，用于归一化调谐曲线。")),
                MeasureInfo(name: L10n.tr("方向覆盖度"), definition: L("Fraction of direction bins with dwell time ≥ \(n(p.hdMinBinTime)) s.", "停留时间 ≥ \(n(p.hdMinBinTime)) s 的方向格所占比例。")),
                MeasureInfo(name: L10n.tr("占据平均向量长度"), definition: L10n.tr("HD 占据分布的平均向量长度，越接近 0 越均匀；偏大时调谐曲线容易受采样偏差影响。")),
                MeasureInfo(name: L10n.tr("角速度 AHV"), definition: L10n.tr("头朝向对时间的导数（°/s），以及顺 / 逆时针转头时间。"))
            ]
        case .spatialExploration:
            return [
                MeasureInfo(name: L10n.tr("占据图"), definition: L("Body-center dwell time in each \(n(p.spatialBin)) cm spatial bin.", "身体中心在每个 \(n(p.spatialBin)) cm 方格中的停留时间。")),
                MeasureInfo(name: L10n.tr("覆盖度"), definition: L("Fraction of spatial bins with ≥ \(n(p.coverageMinTime)) s occupancy, plus its growth over time.",
                                                                 "停留 ≥ \(n(p.coverageMinTime)) s 的方格占场地方格的比例，以及随时间的增长曲线。")),
                MeasureInfo(name: L10n.tr("运动时间"), definition: L("Fraction of time at > \(n(p.moveSpeed)) cm/s (a common velocity filter for place-field analysis).",
                                                                   "速度 > \(n(p.moveSpeed)) cm/s 的时间比例（放电野分析常用的速度筛选）。")),
                MeasureInfo(name: L10n.tr("路程与速度"), definition: L10n.tr("总路程、平均运动速度、速度分布。"))
            ]
        case .openField:
            return [
                MeasureInfo(name: L10n.tr("总路程与速度"), definition: L10n.tr("身体中心的移动距离（m）和平均速度。")),
                MeasureInfo(name: L10n.tr("中央区"), definition: L10n.tr("中央区时间 %、进入次数、首次进入潜伏期。")),
                MeasureInfo(name: L10n.tr("四角区"), definition: L("Time (% and s), entries, first-entry latency and share of the distance in the four corner squares (side \(n((ZoneBuilder.openFieldCornerFraction(p).fraction * 1000).rounded() / 10))% of the shorter side; rectangular arenas only).",
                                                                 "身体中心在四个角上的正方形内（边长为短边的 \(n((ZoneBuilder.openFieldCornerFraction(p).fraction * 1000).rounded() / 10))%，仅方形 / 矩形场地）的时间 %、时间、进入次数、首次进入潜伏期和路程占比。")),
                MeasureInfo(name: L10n.tr("静止"), definition: L("Duration of keypoint movement < \(n(p.freezeSpeed)) cm/s sustained for ≥ \(n(p.freezeMin)) s.",
                                                               "关键点运动 < \(n(p.freezeSpeed)) cm/s 持续 ≥ \(n(p.freezeMin)) s 的时间。")),
                MeasureInfo(name: L10n.tr("转圈"), definition: L10n.tr("按身体轴向累计的完整顺时针 / 逆时针转圈数。"))
            ]
        case .elevatedPlusMaze:
            return [
                MeasureInfo(name: L10n.tr("开放臂时间 %"), definition: L10n.tr("开放臂时间 ÷（开放臂 + 闭合臂时间）。")),
                MeasureInfo(name: L10n.tr("开放臂进入 %"), definition: L10n.tr("开放臂进入 ÷ 总进入；默认身体中心和尾根都进入臂才算。")),
                MeasureInfo(name: L10n.tr("探头"), definition: L10n.tr("鼻尖伸出开放臂边缘且身体仍在迷宫上（≥ 0.2 s）；身体在中央区或闭合臂时为受保护探头。")),
                MeasureInfo(name: L10n.tr("伸展评估姿势 SAP"), definition: L10n.tr("身体长度 ≥ 中位数的 1.2 倍且身体中心速度 < 5 cm/s，持续 ≥ 0.5 s。"))
            ]
        case .lightDark:
            return [
                MeasureInfo(name: L10n.tr("明箱时间 %"), definition: L10n.tr("身体中心在明箱内的时间比例。")),
                MeasureInfo(name: L10n.tr("穿梭次数"), definition: L10n.tr("身体中心在明暗箱之间的穿越次数。")),
                MeasureInfo(name: L10n.tr("潜伏期"), definition: L10n.tr("首次进入明箱、首次进入暗箱的时间。")),
                MeasureInfo(name: L10n.tr("探头"), definition: L10n.tr("鼻尖进入明箱而身体中心和尾根仍在暗箱，持续 ≥ 0.2 s。"))
            ]
        case .elevatedZeroMaze:
            return [
                MeasureInfo(name: L10n.tr("开放段时间 %"), definition: L10n.tr("开放段时间占分析时间的比例；进入按身体中心（默认加尾根）判断。")),
                MeasureInfo(name: L10n.tr("进入与转换"), definition: L10n.tr("开放段 / 闭合段进入次数、开放段进入比例、首次进入开放段潜伏期、开闭段转换次数。")),
                MeasureInfo(name: L10n.tr("头探"), definition: L10n.tr("身体中心在开放段，鼻尖越出跑道内缘或外缘 ≥ 1 cm，持续 ≥ 0.2 s；内缘、外缘分别计数。")),
                MeasureInfo(name: L10n.tr("闭合段探出"), definition: L10n.tr("身体中心和尾根在闭合段，鼻尖越过边界进入开放段，持续 ≥ 0.2 s，随后退回（紧接着进入开放段的不计）。")),
                MeasureInfo(name: L10n.tr("伸展评估姿势 SAP"), definition: L10n.tr("身体长度 ≥ 中位数的 1.2 倍且身体中心速度 < 5 cm/s，持续 ≥ 0.5 s；另给在闭合段朝向开放段的次数。"))
            ]
        case .noveltySuppressedFeeding:
            return [
                MeasureInfo(name: L10n.tr("进食潜伏期"), definition: L10n.tr("放入到首次咬食的时间，在回看中人工确认；截止前没吃记为截止时间并标为未进食（右删失），组间页用生存分析。未确认时不进入组间统计。")),
                MeasureInfo(name: L10n.tr("接近食物"), definition: L10n.tr("鼻尖首次进入食物区（默认半径 3 cm）的潜伏期、进入次数和停留时间。")),
                MeasureInfo(name: L10n.tr("候选进食"), definition: L10n.tr("鼻尖在食物区、身体中心速度 < 2 cm/s，持续 ≥ 3 s；标在回看时间轴上，供确认第一口。")),
                MeasureInfo(name: L10n.tr("饥饿对照"), definition: L10n.tr("家笼 5 min 摄食量（g）与禁食引起的体重下降 %，可作为协变量。"))
            ]
        case .visualCliff:
            return [
                MeasureInfo(name: L10n.tr("首次选择"), definition: L10n.tr("离开中性区后先进入的一侧（深侧 = 100，浅侧 = 0；组平均即先选深侧的比例，组间页另给 Fisher 精确检验），以及离开中性区的潜伏期。")),
                MeasureInfo(name: L10n.tr("各侧时间"), definition: L10n.tr("深侧、浅侧和中性区的时间（%）与路程；前一段时间（默认 4 min）另算。")),
                MeasureInfo(name: L10n.tr("进入深侧"), definition: L10n.tr("进入次数和首次进入潜伏期；没有进入时记为截止时间并标为未进入（右删失），组间页给生存分析。")),
                MeasureInfo(name: L10n.tr("边缘探头"), definition: L10n.tr("鼻尖伸进深侧，而身体中心和尾根仍在中性区或浅侧，持续 ≥ 设定时长：次数、时间、首次潜伏期。"))
            ]
        case .marbleBurying:
            return [
                MeasureInfo(name: L10n.tr("埋住的珠子"), definition: L("Marbles with ≥ \(n((p.mbThreshold * 100).rounded())) % of their top-view visible area covered at the end of the analysis window, out of the scored marbles (stricter than the by-eye “2/3 covered” rule: 67 % of the visible area is about 90 % burial by depth); the numbers ≥ 1/2 covered and almost fully buried (≥ 95 %) are shown next to it.",
                                                                     "分析时间段结束时，可见面积被盖住 ≥ \(n((p.mbThreshold * 100).rounded()))% 的珠子数（分母为可评分的珠子）；比肉眼按表面“2/3 以上”的规则更严格（可见面积 67% 约相当于按深度埋住 90%）。旁边同时给出 ≥ 1/2 和几乎全埋（≥ 95%）的数目。")),
                MeasureInfo(name: L10n.tr("遮盖程度"), definition: L10n.tr("每颗珠子 c = (m − m0) ÷ (b − m0)：m 为珠子圆内平均亮度，m0 为参照帧中的值，b 为珠子外一圈垫料此刻的亮度。0 = 和开始时一样，1 = 看起来已和垫料相同。只在小鼠离开该珠子 ≥ 1 s 且没有挡住它时取样。")),
                MeasureInfo(name: L10n.tr("埋珠事件"), definition: L10n.tr("小鼠离开某颗珠子后，它的遮盖程度比上一次上升 ≥ 0.2：次数、首次埋珠潜伏期、每 5 min 的埋住数曲线。")),
                MeasureInfo(name: L10n.tr("接近珠子"), definition: L10n.tr("鼻尖距珠子边缘 ≤ 设定距离（默认 1 cm）的次数、时间、首次潜伏期和接近过的珠子数。"))
            ]
        case .novelObject:
            return [
                MeasureInfo(name: L10n.tr("探索时间"), definition: L("Nose within \(n(p.exploreMargin)) cm of the object edge, oriented toward it (±\(n(p.headTolerance))°), with body center off the object.",
                                                                    "鼻尖在物体外缘 \(n(p.exploreMargin)) cm 以内、头朝向物体（±\(n(p.headTolerance))°），且身体中心不在物体上。")),
                MeasureInfo(name: L10n.tr("辨别指数 DI"), definition: L10n.tr("(新 − 旧) ÷ (新 + 旧)；训练阶段为 (B − A) ÷ (B + A)，用来检查位置偏好。")),
                MeasureInfo(name: L10n.tr("识别指数 RI"), definition: L10n.tr("新 ÷ (新 + 旧) × 100%。")),
                MeasureInfo(name: L10n.tr("20 s 标准"), definition: L10n.tr("累计探索达到 20 s 的时间，以及达到时的 DI。"))
            ]
        case .barnesMaze:
            return [
                MeasureInfo(name: L10n.tr("首次潜伏期"), definition: L("Time until the nose first enters the target hole. The cut-off is the analysis length: without a target poke before it the latency is the cut-off, flagged as not found (right-censored; found_target = 0), and the group page uses a survival analysis.",
                                                                     "鼻尖首次探入目标洞的时间。截止时间为分析时长：截止前没有探入目标洞时记为截止时间并标为未找到（右删失，found_target = 0），组间页对它做生存分析。")),
                MeasureInfo(name: L10n.tr("错误数"), definition: L10n.tr("鼻尖探入非目标洞的次数：首次找到目标前的为首次错误，全程的为总错误。")),
                MeasureInfo(name: L10n.tr("路径长度"), definition: L10n.tr("首次找到目标洞之前身体中心的移动距离。")),
                MeasureInfo(name: L10n.tr("目标象限"), definition: L10n.tr("以目标洞为中心 ±45° 扇区内的时间比例（探索测试）。"))
            ]
        case .waterMaze:
            return [
                MeasureInfo(name: L10n.tr("逃避潜伏期"), definition: L10n.tr("身体中心进入平台（半径 + 余量）并停留 ≥ 设定时长的时刻；没找到时记为试次时长。")),
                MeasureInfo(name: L10n.tr("路径与游速"), definition: L10n.tr("入水到找到平台之间身体中心的路程、平均游速和路径效率（直线距离 ÷ 实际路程）。")),
                MeasureInfo(name: L10n.tr("平均距离与累计搜索误差"), definition: L10n.tr("到平台中心的平均距离（Gallagher）；按 1 s 分段累加的距离减去以同样速度直线游向平台的理想值（CIPL）。")),
                MeasureInfo(name: L10n.tr("象限与平台区"), definition: L10n.tr("目标、对侧和两个相邻象限的时间比例，平台区时间；探索测试另给穿越原平台次数、前 30 s 和分段的目标象限时间、搜索熵。")),
                MeasureInfo(name: L10n.tr("搜索策略"), definition: L10n.tr("Pathfinder 规则：直线路径、聚焦、定向、间接、链式、扫描、贴壁、随机；附认知评分（0–6）。")),
                MeasureInfo(name: L10n.tr("贴壁与漂浮"), definition: L10n.tr("距池壁不超过贴壁区宽度的时间；速度 < 2 cm/s 持续 ≥ 1 s 的漂浮时间。两者都是非认知因素。"))
            ]
        case .passiveAvoidance:
            return [
                MeasureInfo(name: L10n.tr("进入暗室潜伏期"), definition: L10n.tr("按进入规则首次进入暗室的时间；截止前没有进入时记为截止时间并标为未进入（右删失），组间页对它做生存分析。")),
                MeasureInfo(name: L10n.tr("进入暗室"), definition: L10n.tr("截止前是否进入（0 / 100），组平均即进入的比例。")),
                MeasureInfo(name: L10n.tr("暗室时间与进入次数"), definition: L10n.tr("按同一进入规则统计。")),
                MeasureInfo(name: L10n.tr("反向探头"), definition: L10n.tr("鼻尖伸进暗室而身体中心和尾根仍在明室，持续 ≥ 设定时长：次数、进入前次数、首次探头潜伏期。"))
            ]
        case .stepDown:
            return [
                MeasureInfo(name: L10n.tr("下台潜伏期"), definition: L10n.tr("按下台规则首次离开平台的时间；截止前没有下台时记为截止时间并标为未下台（右删失），组间页对它做生存分析。测试阶段另给测试 / 训练潜伏期之比（同一编号自动配对）。")),
                MeasureInfo(name: L10n.tr("下台"), definition: L10n.tr("截止前是否下台（0 / 100），以及下台次数和平台上的时间。")),
                MeasureInfo(name: L10n.tr("平台上僵直"), definition: L10n.tr("在平台上时的僵直比例（同恐惧条件化的定义）。")),
                MeasureInfo(name: L10n.tr("边缘探头"), definition: L10n.tr("身体中心和尾根仍在平台上、鼻尖伸出平台边缘，持续 ≥ 设定时长：次数、下台前次数、首次探头潜伏期。"))
            ]
        case .platformAvoidance:
            return [
                MeasureInfo(name: L10n.tr("平台时间"), definition: L10n.tr("按上平台规则在平台上的时间（s、%），上平台次数、首次上平台潜伏期、平均每次停留时长。")),
                MeasureInfo(name: L10n.tr("僵直"), definition: L10n.tr("运动指数低于阈值并持续 ≥ 最短时长（同恐惧条件化）；另给平台上和平台外各自的僵直比例。")),
                MeasureInfo(name: L10n.tr("奖励口区"), definition: L10n.tr("鼻尖在奖励口半径内的时间和次数（可选）。")),
                MeasureInfo(name: L10n.tr("分段曲线"), definition: L10n.tr("每段时间的平台时间 % 和僵直 %，组间页可做时间进程。"))
            ]
        case .placePreference:
            return [
                MeasureInfo(name: L10n.tr("配对侧时间"), definition: L10n.tr("身体中心在配对 / 刺激侧的时间（s、%），以及非配对侧和中间区的时间。")),
                MeasureInfo(name: L10n.tr("偏好分数与指数"), definition: L10n.tr("配对侧 − 非配对侧（s）；偏好指数 = (配对 − 非配对) ÷ (配对 + 非配对)。")),
                MeasureInfo(name: L10n.tr("CPP 分数"), definition: L10n.tr("后测配对侧时间 − 前测配对侧时间（同一编号自动配对）。")),
                MeasureInfo(name: L10n.tr("穿越与时间曲线"), definition: L10n.tr("两侧之间的穿越次数、首次进入配对侧潜伏期、分段配对侧时间。"))
            ]
        case .yMaze:
            return [
                MeasureInfo(name: L10n.tr("交替率"), definition: L("Number of three-entry sequences visiting distinct arms / (total entries − 2), with re-entries counted as entries. Chance for this formula is 22.2 % (6/27); the often quoted 50 % holds only if an arm is never re-entered immediately.",
                                                                 "连续三次进入三条不同臂的次数 ÷（总进入次数 − 2），重复进入也计入总进入次数。按此公式随机水平为 22.2%（6/27）；常说的 50% 只在从不立即重复进入同一臂时成立。")),
                MeasureInfo(name: L("Same-arm and alternate-arm returns", "重复进入与隔一次返回"), definition: L("SAR: entry k into the arm of entry k − 1 (A-A); AAR: entry k into the arm of entry k − 2 but not that of entry k − 1 (A-B-A). Shown next to the alternation rate to tell a low rate due to perseveration apart from one due to random choices.",
                                                                                                         "SAR：第 k 次进入与第 k − 1 次同一条臂（A-A）；AAR：第 k 次进入与第 k − 2 次同一条臂、但与第 k − 1 次不同（A-B-A）。与交替率一并给出，用来区分交替率低是因为反复进入（固着）还是随机选择。")),
                MeasureInfo(name: L10n.tr("进入次数"), definition: L10n.tr("默认身体中心和尾根都在臂内才算一次进入。")),
                MeasureInfo(name: L10n.tr("探头未进入"), definition: L10n.tr("鼻尖进入某臂但身体没有进入就退回。"))
            ]
        case .tMaze:
            return [
                MeasureInfo(name: "IdPhi", definition: L10n.tr("每次从起始臂经过选择点进入左 / 右臂期间，头朝向变化绝对值的累计（°）。")),
                MeasureInfo(name: L10n.tr("zIdPhi 与 VTE"), definition: L("Within-session z-scoring; zIdPhi ≥ \(n(p.vteZ)) is classified as VTE (adjustable). VTE % is given from 10 choices on. zIdPhi is relative to the session, so compare groups with the mean IdPhi (°) rather than VTE %.",
                                                                          "会话内 z 标准化；zIdPhi ≥ \(n(p.vteZ)) 记为 VTE（阈值可调）。至少 10 次选择才给出 VTE 比例。zIdPhi 是相对本次会话的值，组间比较请优先用 IdPhi 均值（°）。")),
                MeasureInfo(name: L10n.tr("选择"), definition: L10n.tr("左 / 右选择、连续选择的交替率、选择点停留时间。"))
            ]
        case .fearConditioning:
            return [
                MeasureInfo(name: L10n.tr("僵直"), definition: L("Core keypoint displacement speed < \(n(p.freezeSpeed)) cm/s in a 0.5 s window for ≥ \(n(p.freezeMin)) s.",
                                                               "核心关键点 0.5 s 窗口位移速度 < \(n(p.freezeSpeed)) cm/s，持续 ≥ \(n(p.freezeMin)) s。")),
                MeasureInfo(name: L10n.tr("按 CS 分段"), definition: L10n.tr("基线（首个 CS 前）、每个 CS 期间、CS 间隔的僵直百分比。")),
                MeasureInfo(name: L10n.tr("时间曲线"), definition: L("Freezing fraction per \(AnalysisContext.durationText(max(p.timeBin, 1))) bin, plotted at the bin centre; a last bin with < 90 % of its length analysed is left out.",
                                                                   "每 \(AnalysisContext.durationText(max(p.timeBin, 1))) 一段的僵直百分比，画在每段中点；分析时间不足一段 90% 的最后一段不画。"))
            ]
        case .looming:
            return [
                MeasureInfo(name: L10n.tr("反应潜伏期"), definition: L("Time until speed first exceeds max(\(n(p.flightFactor))× the speed in the \(n(p.baselineWindow)) s before the stimulus, \(n(p.flightMinSpeed)) cm/s) after the stimulus.",
                                                                     "刺激后速度首次超过 max(\(n(p.flightFactor)) × 刺激前 \(n(p.baselineWindow)) s 的基线速度, \(n(p.flightMinSpeed)) cm/s) 的时间。")),
                MeasureInfo(name: L10n.tr("逃跑"), definition: L("Behavioral response followed by return to shelter within \(n(p.escapeWindow)) s.", "有反应且在 \(n(p.escapeWindow)) s 内回到巢穴区。")),
                MeasureInfo(name: L10n.tr("僵直"), definition: L("Freezing duration during the \(n(p.escapeWindow)) s after the stimulus.", "刺激后 \(n(p.escapeWindow)) s 内的僵直时长。")),
                MeasureInfo(name: L10n.tr("朝向与距离"), definition: L10n.tr("刺激时头朝向与巢穴方向的夹角、到巢穴的距离。")),
                MeasureInfo(name: L10n.tr("僵直定义与威胁区"), definition: L10n.tr("僵直可用运动指数（同恐惧条件化），或按 De Franceschi 等（2016）用身体速度 < 2 cm/s 持续 ≥ 0.5 s；可选的威胁区给出区内时间，并在逐帧数据中标记。"))
            ]
        case .rotation:
            return [
                MeasureInfo(name: L10n.tr("整圈数"), definition: L10n.tr("身体轴向（尾根 → 颈部）累计转过 360° 记一圈，顺 / 逆时针分开；反向回转超过 90° 时重新计数。")),
                MeasureInfo(name: L10n.tr("同侧 / 对侧"), definition: L10n.tr("根据损伤侧别换算；俯拍时画面逆时针 = 动物向左转。")),
                MeasureInfo(name: L10n.tr("净旋转"), definition: L10n.tr("同侧 − 对侧，及每分钟净旋转数和分段曲线。"))
            ]
        case .poseOnly:
            return [
                MeasureInfo(name: L10n.tr("逐帧关键点"), definition: L10n.tr("6 个关键点的像素坐标与置信度（与旧版 CSV 格式一致）。")),
                MeasureInfo(name: L10n.tr("运动学"), definition: L10n.tr("平滑后的坐标、速度、头朝向、身体轴向、头–身夹角、身体长度。")),
                MeasureInfo(name: L10n.tr("质量"), definition: L10n.tr("检出率、各关键点平均置信度。"))
            ]
        }
    }

    var references: [PaperRef] {
        switch self {
        case .threeChamber:
            return [
                PaperRef(citation: "Moy SS et al. (2004) Sociability and preference for social novelty in five inbred strains: an approach to assess autistic-like behavior in mice. Genes Brain Behav 3:287–302.", doi: "10.1111/j.1601-1848.2004.00076.x"),
                PaperRef(citation: "Yang M, Silverman JL, Crawley JN (2011) Automated three-chambered social approach task for mice. Curr Protoc Neurosci 8.26.", doi: "10.1002/0471142301.ns0826s56")
            ]
        case .socialInteraction:
            return [
                PaperRef(citation: "Golden SA, Covington HE, Berton O, Russo SJ (2011) A standardized protocol for repeated social defeat stress in mice. Nat Protoc 6:1183–1191.", doi: "10.1038/nprot.2011.361"),
                PaperRef(citation: "Krishnan V et al. (2007) Molecular adaptations underlying susceptibility and resistance to social defeat in brain reward regions. Cell 131:391–404.", doi: "10.1016/j.cell.2007.09.018")
            ]
        case .groupBehavior:
            return [
                PaperRef(citation: "de Chaumont F et al. (2019) Real-time analysis of the behaviour of groups of mice via a depth-sensing camera and machine learning. Nat Biomed Eng 3:930–942.", doi: "10.1038/s41551-019-0396-1"),
                PaperRef(citation: "Reinwald JR et al. Individual differences drive social hierarchies in male mouse societies. eLife 109354.", doi: "10.7554/eLife.109354"),
                PaperRef(citation: "Gammell MP et al. (2003) David’s score: a more appropriate dominance ranking method than Clutton-Brock et al.’s index. Anim Behav 66:601–605.", doi: "10.1006/anbe.2003.2226"),
                PaperRef(citation: "Sánchez-Tójar A, Schroeder J, Farine DR (2018) A practical guide for inferring reliable dominance hierarchies and estimating their uncertainty. J Anim Ecol 87:594–608.", doi: "10.1111/1365-2656.12776")
            ]
        case .dyadicSocial:
            return [
                PaperRef(citation: "Segalin C et al. (2021) The Mouse Action Recognition System (MARS) software pipeline for automated analysis of social behaviors in mice. eLife 10:e63720.", doi: "10.7554/eLife.63720"),
                PaperRef(citation: "Hong W et al. (2015) Automated measurement of mouse social behaviors using depth sensing, video tracking, and machine learning. PNAS 112:E5351–E5360.", doi: "10.1073/pnas.1515982112")
            ]
        case .residentIntruder:
            return [
                PaperRef(citation: "Koolhaas JM, Coppens CM, de Boer SF, Buwalda B, Meerlo P, Timmermans PJA (2013) The resident-intruder paradigm: a standardized test for aggression, violence and social stress. J Vis Exp 77:e4367.", doi: "10.3791/4367"),
                PaperRef(citation: "Segalin C et al. (2021) The Mouse Action Recognition System (MARS) software pipeline for automated analysis of social behaviors in mice. eLife 10:e63720.", doi: "10.7554/eLife.63720"),
                PaperRef(citation: "Hong W et al. (2015) Automated measurement of mouse social behaviors using depth sensing, video tracking, and machine learning. PNAS 112:E5351–E5360.", doi: "10.1073/pnas.1515982112")
            ]
        case .headDirection:
            return [
                PaperRef(citation: "Taube JS, Muller RU, Ranck JB (1990) Head-direction cells recorded from the postsubiculum in freely moving rats. I. J Neurosci 10:420–435.", doi: "10.1523/JNEUROSCI.10-02-00420.1990"),
                PaperRef(citation: "Peyrache A, Lacroix MM, Petersen PC, Buzsáki G (2015) Internally organized mechanisms of the head direction sense. Nat Neurosci 18:569–575.", doi: "10.1038/nn.3968"),
                PaperRef(citation: "Mathis A et al. (2018) DeepLabCut: markerless pose estimation of user-defined body parts with deep learning. Nat Neurosci 21:1281–1289.", doi: "10.1038/s41593-018-0209-y")
            ]
        case .spatialExploration:
            return [
                PaperRef(citation: "O'Keefe J, Dostrovsky J (1971) The hippocampus as a spatial map. Brain Res 34:171–175.", doi: "10.1016/0006-8993(71)90358-1"),
                PaperRef(citation: "Hafting T, Fyhn M, Molden S, Moser MB, Moser EI (2005) Microstructure of a spatial map in the entorhinal cortex. Nature 436:801–806.", doi: "10.1038/nature03721")
            ]
        case .openField:
            return [
                PaperRef(citation: "Prut L, Belzung C (2003) The open field as a paradigm to measure the effects of drugs on anxiety-like behaviors: a review. Eur J Pharmacol 463:3–33.", doi: "10.1016/S0014-2999(03)01272-X"),
                PaperRef(citation: "Seibenhener ML, Wooten MC (2015) Use of the open field maze to measure locomotor and anxiety-like behavior in mice. J Vis Exp 96:e52434.", doi: "10.3791/52434")
            ]
        case .elevatedPlusMaze:
            return [
                PaperRef(citation: "Pellow S, Chopin P, File SE, Briley M (1985) Validation of open:closed arm entries in an elevated plus-maze as a measure of anxiety in the rat. J Neurosci Methods 14:149–167.", doi: "10.1016/0165-0270(85)90031-7"),
                PaperRef(citation: "Walf AA, Frye CA (2007) The use of the elevated plus maze as an assay of anxiety-related behavior in rodents. Nat Protoc 2:322–328.", doi: "10.1038/nprot.2007.44"),
                PaperRef(citation: "Holly KS, Orndorff CO, Murray TA (2016) MATSAP: an automated analysis of stretch-attend posture in rodent behavioral experiments. Sci Rep 6:31286.", doi: "10.1038/srep31286")
            ]
        case .lightDark:
            return [
                PaperRef(citation: "Bourin M, Hascoët M (2003) The mouse light/dark box test. Eur J Pharmacol 463:55–65.", doi: "10.1016/S0014-2999(03)01274-3"),
                PaperRef(citation: "Takao K, Miyakawa T (2006) Light/dark transition test for mice. J Vis Exp (1):e104.", doi: "10.3791/104")
            ]
        case .elevatedZeroMaze:
            return [
                PaperRef(citation: "Shepherd JK, Grewal SS, Fletcher A, Bill DJ, Dourish CT (1994) Behavioural and pharmacological characterisation of the elevated \u{201C}zero-maze\u{201D} as an animal model of anxiety. Psychopharmacology 116:56–64.", doi: "10.1007/BF02244871"),
                PaperRef(citation: "Braun AA, Skelton MR, Vorhees CV, Williams MT (2011) Comparison of the elevated plus and elevated zero mazes in treated and untreated male Sprague-Dawley rats: effects of anxiolytic and anxiogenic agents. Pharmacol Biochem Behav 97:406–415.", doi: "10.1016/j.pbb.2010.09.013"),
                PaperRef(citation: "Tucker LB, McCabe JT (2017) Behavior of male and female C57BL/6J mice is more consistent with repeated trials in the elevated zero maze than in the elevated plus maze. Front Behav Neurosci 11:13.", doi: "10.3389/fnbeh.2017.00013"),
                PaperRef(citation: "Holly KS, Orndorff CO, Murray TA (2016) MATSAP: an automated analysis of stretch-attend posture in rodent behavioral experiments. Sci Rep 6:31286.", doi: "10.1038/srep31286")
            ]
        case .noveltySuppressedFeeding:
            return [
                PaperRef(citation: "Samuels BA, Hen R (2011) Novelty-suppressed feeding in the mouse. In: Gould TD (ed) Mood and Anxiety Related Phenotypes in Mice II. Neuromethods 63:107–121.", doi: "10.1007/978-1-61779-313-4_7"),
                PaperRef(citation: "Santarelli L et al. (2003) Requirement of hippocampal neurogenesis for the behavioral effects of antidepressants. Science 301:805–809.", doi: "10.1126/science.1083328"),
                PaperRef(citation: "Dulawa SC, Hen R (2005) Recent advances in animal models of chronic antidepressant effects: the novelty-induced hypophagia test. Neurosci Biobehav Rev 29:771–783.", doi: "10.1016/j.neubiorev.2005.03.017"),
                PaperRef(citation: "Kaplan EL, Meier P (1958) Nonparametric estimation from incomplete observations. J Am Stat Assoc 53:457–481.", doi: "10.1080/01621459.1958.10501452")
            ]
        case .visualCliff:
            return [
                PaperRef(citation: "Fox MW (1965) The visual cliff test for the study of visual depth perception in the mouse. Anim Behav 13:232–233.", doi: "10.1016/0003-3472(65)90040-0"),
                PaperRef(citation: "Gibson EJ, Walk RD (1960) The \u{201C}visual cliff\u{201D}. Sci Am 202:64–71.", doi: "10.1038/scientificamerican0460-64"),
                PaperRef(citation: "Kaplan EL, Meier P (1958) Nonparametric estimation from incomplete observations. J Am Stat Assoc 53:457–481.", doi: "10.1080/01621459.1958.10501452")
            ]
        case .marbleBurying:
            return [
                PaperRef(citation: "Deacon RMJ (2006) Digging and marble burying in mice: simple methods for in vivo identification of biological impacts. Nat Protoc 1:122–124.", doi: "10.1038/nprot.2006.20"),
                PaperRef(citation: "Thomas A, Burant A, Bui N, Graham D, Yuva-Paylor LA, Paylor R (2009) Marble burying reflects a repetitive and perseverative behavior more than novelty-induced anxiety. Psychopharmacology 204:361–373.", doi: "10.1007/s00213-009-1466-y"),
                PaperRef(citation: "Angoa-Pérez M, Kane MJ, Briggs DI, Francescutti DM, Kuhn DM (2013) Marble burying and nestlet shredding as tests of repetitive, compulsive-like behaviors in mice. J Vis Exp 82:50978.", doi: "10.3791/50978"),
                PaperRef(citation: "Wahl L, Punt AM, Arbab T, Willuhn I, Elgersma Y, Badura A (2022) A novel automated approach for improving standardization of the marble burying test enables quantification of burying bouts and activity characteristics. eNeuro 9:ENEURO.0446-21.2022.", doi: "10.1523/ENEURO.0446-21.2022")
            ]
        case .novelObject:
            return [
                PaperRef(citation: "Ennaceur A, Delacour J (1988) A new one-trial test for neurobiological studies of memory in rats. 1: Behavioral data. Behav Brain Res 31:47–59.", doi: "10.1016/0166-4328(88)90157-X"),
                PaperRef(citation: "Leger M et al. (2013) Object recognition test in mice. Nat Protoc 8:2531–2537.", doi: "10.1038/nprot.2013.155"),
                PaperRef(citation: "Gabriel CJ et al. (2022) BehaviorDEPOT is a simple, flexible tool for automated behavioral detection based on markerless pose tracking. eLife 11:e74314.", doi: "10.7554/eLife.74314")
            ]
        case .barnesMaze:
            return [
                PaperRef(citation: "Barnes CA (1979) Memory deficits associated with senescence: a neurophysiological and behavioral study in the rat. J Comp Physiol Psychol 93:74–104.", doi: "10.1037/h0077579"),
                PaperRef(citation: "Pitts MW (2018) Barnes maze procedure for spatial learning and memory in mice. Bio-protocol 8:e2744.", doi: "10.21769/BioProtoc.2744")
            ]
        case .waterMaze:
            return [
                PaperRef(citation: "Morris R (1984) Developments of a water-maze procedure for studying spatial learning in the rat. J Neurosci Methods 11:47–60.", doi: "10.1016/0165-0270(84)90007-4"),
                PaperRef(citation: "Vorhees CV, Williams MT (2006) Morris water maze: procedures for assessing spatial and related forms of learning and memory. Nat Protoc 1:848–858.", doi: "10.1038/nprot.2006.116"),
                PaperRef(citation: "Gallagher M, Burwell R, Burchinal M (1993) Severity of spatial learning impairment in aging: development of a learning index for performance in the Morris water maze. Behav Neurosci 107:618–626.", doi: "10.1037/0735-7044.107.4.618"),
                PaperRef(citation: "Maei HR, Zaslavsky K, Teixeira CM, Frankland PW (2009) What is the most sensitive measure of water maze probe test performance? Front Integr Neurosci 3:4.", doi: "10.3389/neuro.07.004.2009"),
                PaperRef(citation: "Maei HR et al. (2009) Development and validation of a sensitive entropy-based measure for the water maze. Front Integr Neurosci 3:33.", doi: "10.3389/neuro.07.033.2009"),
                PaperRef(citation: "Cooke MB, O'Leary TP, Harris P, Ma R, Brown RE, Snyder JS (2019) Pathfinder: open source software for analyzing spatial navigation search strategies. F1000Research 8:1521.", doi: "10.12688/f1000research.20352.2"),
                PaperRef(citation: "Garthe A, Behr J, Kempermann G (2009) Adult-generated hippocampal neurons allow the flexible use of spatially precise learning strategies. PLoS One 4:e5464.", doi: "10.1371/journal.pone.0005464"),
                PaperRef(citation: "Wolfer DP, Stagljar-Bozicevic M, Errington ML, Lipp HP (1998) Spatial memory and learning in transgenic mice: fact or artifact? News Physiol Sci 13:118–123.", doi: "10.1152/physiologyonline.1998.13.3.118")
            ]
        case .passiveAvoidance:
            return [
                PaperRef(citation: "Jarvik ME, Kopp R (1967) An improved one-trial passive avoidance learning situation. Psychol Rep 21:221–224.", doi: nil),
                PaperRef(citation: "Kaplan EL, Meier P (1958) Nonparametric estimation from incomplete observations. J Am Stat Assoc 53:457–481.", doi: "10.1080/01621459.1958.10501452")
            ]
        case .stepDown:
            return [
                PaperRef(citation: "Kameyama T, Nabeshima T, Kozawa T (1986) Step-down-type passive avoidance- and escape-learning method: suitability for experimental amnesia models. J Pharmacol Methods 16:39–52.", doi: nil),
                PaperRef(citation: "Kaplan EL, Meier P (1958) Nonparametric estimation from incomplete observations. J Am Stat Assoc 53:457–481.", doi: "10.1080/01621459.1958.10501452")
            ]
        case .platformAvoidance:
            return [
                PaperRef(citation: "Bravo-Rivera C, Roman-Ortiz C, Brignoni-Perez E, Sotres-Bayon F, Quirk GJ (2014) Neural structures mediating expression and extinction of platform-mediated avoidance. J Neurosci 34:9736–9742.", doi: "10.1523/JNEUROSCI.0191-14.2014"),
                PaperRef(citation: "Diehl MM, Iravedra-Garcia JM, Morán-Sierra J, Rojas-Bowe G, Gonzalez-Diaz FN, Valentín-Valentín VP, Quirk GJ (2020) Divergent projections of the prelimbic cortex bidirectionally regulate active avoidance. eLife 9:e59281.", doi: "10.7554/eLife.59281")
            ]
        case .placePreference:
            return [
                PaperRef(citation: "Tzschentke TM (2007) Measuring reward with the conditioned place preference (CPP) paradigm: update of the last decade. Addict Biol 12:227–462.", doi: "10.1111/j.1369-1600.2007.00070.x"),
                PaperRef(citation: "Stamatakis AM, Stuber GD (2012) Activation of lateral habenula inputs to the ventral midbrain promotes behavioral avoidance. Nat Neurosci 15:1105–1107.", doi: "10.1038/nn.3145")
            ]
        case .yMaze:
            return [
                PaperRef(citation: "Hughes RN (2004) The value of spontaneous alternation behavior (SAB) as a test of retention in pharmacological investigations of memory. Neurosci Biobehav Rev 28:497–505.", doi: "10.1016/j.neubiorev.2004.06.006"),
                PaperRef(citation: "Kraeuter AK, Guest PC, Sarnyai Z (2019) The Y-maze for assessment of spatial working and reference memory in mice. Methods Mol Biol 1916:105–111.", doi: "10.1007/978-1-4939-8994-2_10")
            ]
        case .tMaze:
            return [
                PaperRef(citation: "Redish AD (2016) Vicarious trial and error. Nat Rev Neurosci 17:147–159.", doi: "10.1038/nrn.2015.30"),
                PaperRef(citation: "Deacon RMJ, Rawlins JNP (2006) T-maze alternation in the rodent. Nat Protoc 1:7–12.", doi: "10.1038/nprot.2006.2"),
                PaperRef(citation: "Gabriel CJ et al. (2022) BehaviorDEPOT (VTE module). eLife 11:e74314.", doi: "10.7554/eLife.74314")
            ]
        case .fearConditioning:
            return [
                PaperRef(citation: "Phillips RG, LeDoux JE (1992) Differential contribution of amygdala and hippocampus to cued and contextual fear conditioning. Behav Neurosci 106:274–285.", doi: "10.1037/0735-7044.106.2.274"),
                PaperRef(citation: "Anagnostaras SG et al. (2010) Automated assessment of Pavlovian conditioned freezing and shock reactivity in mice using the Video Freeze system. Front Behav Neurosci 4:158.", doi: "10.3389/fnbeh.2010.00158"),
                PaperRef(citation: "Gabriel CJ et al. (2022) BehaviorDEPOT (freezing from keypoints). eLife 11:e74314.", doi: "10.7554/eLife.74314")
            ]
        case .looming:
            return [
                PaperRef(citation: "Yilmaz M, Meister M (2013) Rapid innate defensive responses of mice to looming visual stimuli. Curr Biol 23:2011–2015.", doi: "10.1016/j.cub.2013.08.015"),
                PaperRef(citation: "Vale R, Evans DA, Branco T (2017) Rapid spatial learning controls instinctive defensive behavior in mice. Curr Biol 27:1342–1349.", doi: "10.1016/j.cub.2017.03.031"),
                PaperRef(citation: "De Franceschi G, Vivattanasarn T, Saleem AB, Solomon SG (2016) Vision guides selection of freeze or flight defense strategies in mice. Curr Biol 26:2150–2154.", doi: "10.1016/j.cub.2016.06.006")
            ]
        case .rotation:
            return [
                PaperRef(citation: "Pycock CJ (1980) Turning behaviour in animals. Neuroscience 5:461–514.", doi: nil)
            ]
        case .poseOnly:
            return [
                PaperRef(citation: "Mathis A et al. (2018) DeepLabCut. Nat Neurosci 21:1281–1289.", doi: "10.1038/s41593-018-0209-y"),
                PaperRef(citation: "Pereira TD et al. (2022) SLEAP: a deep learning system for multi-animal pose tracking. Nat Methods 19:486–495.", doi: "10.1038/s41592-022-01426-1"),
                PaperRef(citation: "Weinreb C et al. (2024) Keypoint-MoSeq: parsing behavior by linking point tracking to pose dynamics. Nat Methods 21:1329–1339.", doi: "10.1038/s41592-024-02318-2")
            ]
        }
    }

    /// Keypoints the paradigm relies on (shown in the catalog).
    var keypointsUsed: [KP] {
        switch self {
        case .threeChamber, .novelObject, .lightDark: return [.nose, .leftEar, .rightEar, .bodyCenter, .tailBase]
        case .socialInteraction, .openField, .spatialExploration: return [.nose, .bodyCenter, .tailBase]
        case .dyadicSocial, .residentIntruder, .groupBehavior, .poseOnly, .fearConditioning: return KP.allCases
        case .headDirection: return [.nose, .leftEar, .rightEar, .neck, .bodyCenter]
        case .elevatedPlusMaze, .elevatedZeroMaze, .noveltySuppressedFeeding: return [.nose, .bodyCenter, .tailBase]
        case .barnesMaze: return [.nose, .leftEar, .rightEar, .bodyCenter, .tailBase]
        case .waterMaze: return [.nose, .leftEar, .rightEar, .neck, .bodyCenter]
        case .passiveAvoidance, .placePreference, .stepDown, .visualCliff: return [.nose, .bodyCenter, .tailBase]
        case .platformAvoidance: return [.nose, .neck, .bodyCenter, .tailBase]
        case .marbleBurying: return KP.allCases
        case .yMaze: return [.nose, .bodyCenter, .tailBase]
        case .tMaze, .looming: return [.nose, .leftEar, .rightEar, .neck, .bodyCenter]
        case .rotation: return [.neck, .bodyCenter, .tailBase]
        }
    }

    var arenaKinds: [ArenaKind] {
        switch self {
        case .threeChamber, .socialInteraction, .lightDark, .fearConditioning, .passiveAvoidance, .placePreference: return [.rectangle]
        case .visualCliff, .marbleBurying, .platformAvoidance: return [.rectangle]
        case .stepDown: return [.rectangle, .circle]
        case .dyadicSocial, .headDirection, .spatialExploration, .openField, .novelObject, .looming: return [.rectangle, .circle]
        case .groupBehavior: return [.rectangle, .circle, .none]
        case .elevatedPlusMaze: return [.plusMaze]
        case .elevatedZeroMaze: return [.circle]
        case .noveltySuppressedFeeding: return [.rectangle, .circle]
        case .barnesMaze, .waterMaze: return [.circle]
        case .yMaze: return [.yMaze]
        case .tMaze: return [.tMaze]
        case .rotation: return [.circle, .rectangle, .none]
        case .residentIntruder: return [.rectangle, .none, .circle]
        case .poseOnly: return [.none, .rectangle, .circle]
        }
    }

    var defaultArena: ArenaKind { arenaKinds[0] }

    var phases: [PhaseOption] {
        switch self {
        case .threeChamber:
            return [PhaseOption(key: "Sociability", title: L10n.tr("社交偏好")), PhaseOption(key: "Social novelty", title: L10n.tr("社交新颖性")), PhaseOption(key: "Habituation", title: L10n.tr("适应"))]
        case .socialInteraction:
            return [PhaseOption(key: "No target", title: L10n.tr("无目标")), PhaseOption(key: "Target", title: L10n.tr("有目标"))]
        case .novelObject:
            return [PhaseOption(key: "Test", title: L10n.tr("测试")), PhaseOption(key: "Training", title: L10n.tr("训练"))]
        case .barnesMaze:
            return [PhaseOption(key: "Acquisition", title: L10n.tr("学习期")), PhaseOption(key: "Probe", title: L10n.tr("探索测试"))]
        case .passiveAvoidance, .stepDown:
            return [PhaseOption(key: "Test", title: L10n.tr("测试")), PhaseOption(key: "Training", title: L10n.tr("训练"))]
        case .placePreference:
            return [PhaseOption(key: "RTPP", title: L10n.tr("实时位置偏好")), PhaseOption(key: "Pre-test", title: L10n.tr("前测")), PhaseOption(key: "Post-test", title: L10n.tr("后测")), PhaseOption(key: "Conditioning", title: L10n.tr("条件化"))]
        case .waterMaze:
            return [PhaseOption(key: "Acquisition", title: L10n.tr("学习期")), PhaseOption(key: "Probe", title: L10n.tr("探索测试")), PhaseOption(key: "Visible platform", title: L10n.tr("可见平台")), PhaseOption(key: "Reversal", title: L10n.tr("反转学习"))]
        case .fearConditioning:
            return [PhaseOption(key: "Cue test", title: L10n.tr("线索测试")), PhaseOption(key: "Context test", title: L10n.tr("情境测试")), PhaseOption(key: "Training", title: L10n.tr("训练"))]
        default:
            // No presets: the researcher adds their own labels (or leaves it empty).
            return []
        }
    }

    func phaseTitle(_ key: String) -> String {
        phases.first { $0.key == key }?.title ?? key
    }

    /// Phase whose measures are paired with this one for the same animal (the companion run).
    func companionPhase(of phase: String) -> String? {
        switch self {
        case .placePreference: return phase == "Post-test" ? "Pre-test" : nil
        case .stepDown: return phase == "Test" ? "Training" : nil
        default: return nil
        }
    }

    func isPresetPhase(_ key: String) -> Bool {
        phases.contains { $0.key == key }
    }

    /// Draggable markers placed on the calibration frame.
    var markers: [MarkerSpec] {
        switch self {
        case .threeChamber: return [MarkerSpec(key: "cupL", label: "L", title: L10n.tr("左杯")), MarkerSpec(key: "cupR", label: "R", title: L10n.tr("右杯"))]
        case .novelObject: return [MarkerSpec(key: "objA", label: "A", title: L10n.tr("物体 A")), MarkerSpec(key: "objB", label: "B", title: L10n.tr("物体 B"))]
        case .barnesMaze: return [MarkerSpec(key: "target", label: "T", title: L10n.tr("目标洞"))]
        case .waterMaze: return [MarkerSpec(key: "platform", label: "P", title: L10n.tr("平台"))]
        case .looming: return [MarkerSpec(key: "shelter", label: "S", title: L10n.tr("巢穴")), MarkerSpec(key: "threat", label: "T", title: L10n.tr("威胁区"))]
        case .platformAvoidance: return [MarkerSpec(key: "platform", label: "P", title: L10n.tr("平台中心")), MarkerSpec(key: "reward", label: "R", title: L10n.tr("奖励口"))]
        case .stepDown: return [MarkerSpec(key: "platform", label: "P", title: L10n.tr("平台中心"))]
        case .marbleBurying:
            return [MarkerSpec(key: "g1", label: "1", title: L10n.tr("左上角的珠子")), MarkerSpec(key: "g2", label: "2", title: L10n.tr("右上角的珠子")),
                    MarkerSpec(key: "g3", label: "3", title: L10n.tr("右下角的珠子")), MarkerSpec(key: "g4", label: "4", title: L10n.tr("左下角的珠子"))]
        case .headDirection: return [MarkerSpec(key: "cue", label: "Q", title: L10n.tr("提示卡"))]
        case .elevatedZeroMaze: return [MarkerSpec(key: "open", label: "O", title: L10n.tr("开放段中点"))]
        case .noveltySuppressedFeeding: return [MarkerSpec(key: "food", label: "F", title: L10n.tr("食物"))]
        default: return []
        }
    }

    /// Markers in use with these parameters (optional zones only when turned on: the reward port of platform-mediated
    /// avoidance, the threat zone of looming). The calibration editors show and drag these.
    func markers(_ p: AnalysisParams) -> [MarkerSpec] {
        markers.filter { m in
            switch (self, m.key) {
            case (.platformAvoidance, "reward"): return p.pmaReward
            case (.looming, "threat"): return p.loomThreat
            default: return true
            }
        }
    }

    /// Number of animals tracked per frame.
    /// Animals of a task; a group task's default (its sessions keep their own number, `InferenceSettings.animalCount`).
    var animalCount: Int { isGroup ? kGroupDefaultAnimals : (self == .dyadicSocial || self == .residentIntruder ? 2 : 1) }
    /// Tasks with more than two animals, where the number is set for each session.
    var isGroup: Bool { self == .groupBehavior }
    /// The animal count of a session of this task: the task fixes it, except a group task, where it is set per session.
    func animalCount(requested n: Int) -> Int { isGroup ? (n < kGroupMinAnimals ? kGroupDefaultAnimals : min(kGroupMaxAnimals, n)) : animalCount }

    /// Metric shown in lists and highlighted on the result screen.
    var primaryMetricKey: String {
        switch self {
        case .threeChamber: return "sniff_index"
        case .socialInteraction: return "iz_time"
        case .dyadicSocial: return "social_total"
        case .groupBehavior: return "contact_pct"
        case .residentIntruder: return "attack_latency"
        case .headDirection: return "hd_coverage"
        case .spatialExploration: return "coverage"
        case .openField: return "center_pct"
        case .elevatedPlusMaze: return "open_time_pct"
        case .elevatedZeroMaze: return "open_time_pct"
        case .lightDark: return "light_pct"
        case .noveltySuppressedFeeding: return "feeding_latency"
        case .visualCliff: return "deep_pct"
        case .marbleBurying: return "buried_count"
        case .stepDown: return "step_down_latency"
        case .platformAvoidance: return "platform_pct"
        case .novelObject: return "di"
        case .barnesMaze: return "primary_latency"
        case .waterMaze: return "escape_latency"
        case .passiveAvoidance: return "entry_latency"
        case .placePreference: return "paired_pct"
        case .yMaze: return "alternation_pct"
        case .tMaze: return "vte_pct"
        case .fearConditioning: return "freeze_cs_mean"
        case .looming: return "escape_pct"
        case .rotation: return "net_per_min"
        case .poseOnly: return "detection_rate"
        }
    }

    /// Default arena size (cm) for a new session.
    var defaultArenaSize: (width: Double, height: Double) {
        switch self {
        case .threeChamber: return (60, 40)
        case .socialInteraction: return (42, 42)
        case .dyadicSocial: return (40, 40)
        case .groupBehavior: return (40, 40)
        case .residentIntruder: return (30, 18)   // standard mouse home cage floor
        case .headDirection, .spatialExploration: return (50, 50)
        case .openField, .novelObject: return (40, 40)
        case .lightDark: return (45, 30)
        case .elevatedZeroMaze: return (60, 5)   // outer diameter × track width
        case .noveltySuppressedFeeding: return (40, 40)
        case .visualCliff: return (60, 40)
        case .marbleBurying: return (40, 25)
        case .stepDown: return (25, 25)
        case .platformAvoidance: return (30, 25)
        case .fearConditioning: return (30, 24)
        case .looming: return (48, 48)
        case .barnesMaze: return (92, 92)
        case .waterMaze: return (120, 120)
        case .passiveAvoidance: return (40, 20)
        case .placePreference: return (50, 25)
        case .rotation: return (30, 30)
        case .elevatedPlusMaze: return (30, 5)   // arm length × arm width
        case .yMaze: return (35, 5)
        case .tMaze: return (30, 8)
        case .poseOnly: return (40, 40)
        }
    }
}
