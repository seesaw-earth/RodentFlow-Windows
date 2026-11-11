using System.Text.Json.Nodes;

namespace RodentFlow.Core.Setup;

/// <summary>
/// The parameter form of every task, transcribed from the Mac app:
/// RodentStudio/Views/PoseCalibrationEditor.swift — PoseParamsEditor (one section per task) and
/// PoseCommonParamsEditor (the rows every task has). Titles, units, ranges and the conditions under
/// which a row appears are copied from there; English for the rows the Mac writes in Chinese only
/// (resident–intruder) comes from the engine's EnglishTranslations.json.
/// </summary>
/// <remarks>
/// check/check_forms.py compares the keys of each task here with that Swift file and with the
/// engine's AnalysisParams.CodingKeys. Run it after changing either side.
/// The arena dimensions (width, diameter, arm length …) are calibration fields, not parameters; the
/// window shows those beside the picture.
/// </remarks>
public static class AssayForms
{
    // ---------------------------------------------------------------- building blocks

    private static FormRow N(string key, string en, string zh, string unit, double min, double max,
                             string helpEn = "", string helpZh = "", bool integer = false) =>
        new() { Kind = RowKind.Number, Key = key, En = en, Zh = zh, Unit = unit, Min = min, Max = max,
                HelpEn = helpEn, HelpZh = helpZh, Integer = integer };

    private static FormRow P(string key, string en, string zh, double min, double max) =>
        new() { Kind = RowKind.Percent, Key = key, En = en, Zh = zh, Min = min, Max = max, Step = 0.01 };

    private static FormRow C(string key, string en, string zh, params ChoiceOption[] options) =>
        new() { Kind = RowKind.Choice, Key = key, En = en, Zh = zh, Options = options };

    private static ChoiceOption O(object value, string en, string zh) => new(value, en, zh);

    private static FormRow T(string key, string en, string zh) =>
        new() { Kind = RowKind.Toggle, Key = key, En = en, Zh = zh };

    private static FormRow Onsets(string key, string en, string zh, string hintEn, string hintZh) =>
        new() { Kind = RowKind.Onsets, Key = key, En = en, Zh = zh, HelpEn = hintEn, HelpZh = hintZh };

    private static FormRow Note(string en, string zh) => new() { Kind = RowKind.Note, En = en, Zh = zh };

    private static FormGroup Rows(params FormRow[] rows) => new() { Rows = rows };

    private static FormGroup Heading(string en, string zh, params FormRow[] rows) =>
        new() { En = en, Zh = zh, Rows = rows };

    private static FormGroup Fold(string en, string zh, params FormRow[] rows) =>
        new() { En = en, Zh = zh, Rows = rows, Folded = true };

    private static bool Is(FormContext c, string key, string value) => ParamValues.Text(c.Params, key) == value;
    private static bool On(FormContext c, string key) => ParamValues.Flag(c.Params, key) == true;

    // ---------------------------------------------------------------- shared pieces

    /// <summary>freezeRows(title:), optionally shown only under a condition.</summary>
    private static FormGroup Freeze(string en, string zh, Func<FormContext, bool>? when = null)
    {
        FormRow[] rows =
        [
            N("freezeSpeed", "Movement threshold", "运动阈值", "cm/s", 0.1, 10,
              "Core keypoint displacement below this speed in a 0.5 s window counts as immobility.",
              "核心关键点 0.5 s 窗口位移速度低于此值视为不动"),
            N("freezeMin", "Minimum duration", "最短持续", "s", 0, 10),
        ];
        return Heading(en, zh, when is null ? rows : rows.Select(r => r with { When = when }).ToArray());
    }

    /// <summary>entryRule</summary>
    private static FormRow EntryRule() =>
        C("entryRule", "Arm-entry criterion", "进入臂的判定",
          O("full", "Body center + tail base", "身体+尾根"), O("body", "Body center", "身体中心"), O("nose", "Nose", "鼻尖"));

    /// <summary>The hunger control toggle of novelty-suppressed feeding (hungerControlOn).</summary>
    private static readonly string[] HungerKeys = ["nsfHomeCageFood", "nsfWeightBefore", "nsfWeightTest"];

    private static bool HungerOn(JsonObject p) =>
        (ParamValues.Number(p, "nsfHomeCageFood") ?? -1) >= 0
        || (ParamValues.Number(p, "nsfWeightBefore") ?? -1) > 0
        || (ParamValues.Number(p, "nsfWeightTest") ?? -1) > 0;

    private static void SetHunger(JsonObject p, bool on)
    {
        foreach (var key in HungerKeys)
        {
            double v = ParamValues.Number(p, key) ?? -1;
            if (on && v < 0) ParamValues.SetNumber(p, key, 0, integer: false);
            if (!on) ParamValues.SetNumber(p, key, -1, integer: false);
        }
    }

    // ---------------------------------------------------------------- the tasks (PoseParamsEditor)

    public static readonly IReadOnlyDictionary<string, FormGroup[]> Tasks = new Dictionary<string, FormGroup[]>
    {
        ["open_field"] =
        [
            Rows(
                P("centerFraction", "Center zone size (fraction of side)", "中央区大小（边长比例）", 0.2, 0.8),
                P("cornerFraction", "Corner zone size (fraction of shorter side)", "四角区大小（短边比例）", 0.1, 0.4)
                    with { Fallback = 0.25 },
                Note("Four squares in the corners, sized by the arena's shorter side; 25% (default) are the corner squares of a 4 × 4 grid. Rectangular arenas only.",
                     "四个角上的正方形，边长按场地短边计；默认 25%，即 4 × 4 分格的四个角格。只用于方形 / 矩形场地。")),
            Freeze("Immobility criterion", "静止判定"),
        ],

        ["spatial_exploration"] =
        [
            Rows(
                N("spatialBin", "Occupancy-map bin size", "占据图方格", "cm", 0.5, 20),
                N("coverageMinTime", "Minimum dwell time for coverage", "覆盖判定最短停留", "s", 0, 10),
                N("moveSpeed", "Movement speed threshold", "运动速度阈值", "cm/s", 0, 50)),
        ],

        ["head_direction"] =
        [
            Rows(
                C("hdReference", "0° reference", "0° 参考方向",
                  O("image", "Arena right", "场地右方"), O("cue", "Cue card Q", "提示卡 Q")),
                C("hdBinDeg", "Direction bin size", "方向分格",
                  O(3.0, "3°", "3°"), O(6.0, "6°", "6°"), O(10.0, "10°", "10°"), O(15.0, "15°", "15°")),
                N("hdMinBinTime", "Minimum dwell time for coverage", "覆盖判定最短停留", "s", 0, 30)),
        ],

        ["three_chamber"] =
        [
            Rows(
                C("stimSide", "Cup with stranger mouse", "陌生鼠所在杯",
                  O("L", "Left cup L", "左杯 L"), O("R", "Right cup R", "右杯 R"))
                    with
                    {
                        TitleFor = c => c.Phase switch
                        {
                            "Social novelty" => ("Cup with novel stranger", "新陌生鼠所在杯"),
                            "Habituation" => ("Reference cup (index numerator)", "参照杯（指数分子）"),
                            _ => ("Cup with stranger mouse", "陌生鼠所在杯"),
                        },
                    },
                N("cupRadius", "Cup radius", "杯子半径", "cm", 1, 20),
                N("exploreMargin", "Investigation distance (from cup edge)", "嗅探距离（杯外缘）", "cm", 0, 10),
                N("headTolerance", "Head-direction tolerance", "头朝向容差", "°", 5, 180),
                P("centerChamberFraction", "Center-chamber width (fraction of total)", "中箱宽度（占总长）", 0.1, 0.8),
                Note("You can also drag the two center-chamber boundaries (purple L/R handles) independently to adjust their positions and the chamber width.",
                     "也可直接拖动视频上的两条中箱边界（紫色 L/R 控制点），分别调整位置和宽度。")),
        ],

        ["social_interaction"] =
        [
            Rows(
                C("enclosureWall", "Enclosure wall (image orientation)", "网罩靠哪面墙（画面方向）",
                  O("top", "Top", "上"), O("bottom", "Bottom", "下"), O("left", "Left", "左"), O("right", "Right", "右")),
                N("izWidth", "Interaction-zone width (along wall)", "互动区宽（沿墙）", "cm", 1, 100),
                N("izDepth", "Interaction-zone depth (from wall)", "互动区深（离墙）", "cm", 1, 100),
                N("enclosureWidth", "Enclosure width", "网罩宽", "cm", 1, 50),
                N("enclosureDepth", "Enclosure depth", "网罩深", "cm", 1, 50),
                N("cornerSize", "Corner-zone side length", "角落区边长", "cm", 1, 50)),
        ],

        ["resident_intruder"] =
        [
            Rows(
                C("riResident", "Resident", "resident（居住者）",
                  O("auto", "Auto", "自动"), O("A", "A", "A"), O("B", "B", "B")),
                N("riIntruderEntry", "Intruder introduction (0 = auto)", "intruder 放入时间（0 = 自动）", "s", 0, 36000),
                N("riDuration", "Test duration (0 = to the end)", "测试时长（0 = 到结尾）", "s", 0, 36000)),
            Fold("Thresholds (in body lengths, BL)", "判定阈值（体长 BL 为单位）",
                N("riCloseDist", "Close distance", "贴近距离", "BL", 0.3, 3),
                N("riFightSpeed", "Attack relative speed", "攻击相对速度", "BL/s", 0.3, 10),
                N("riFightTurn", "Attack body-axis rotation", "攻击体轴角速度", "°/s", 50, 2000),
                N("riFightMin", "Attack minimum duration", "攻击最短持续", "s", 0.1, 5),
                N("riClinchMin", "Clinch minimum duration", "扭打最短持续", "s", 0.2, 10),
                N("riChaseSpeed", "Chase speed", "追逐速度", "BL/s", 0.5, 15),
                N("riChaseMin", "Chase minimum duration", "追逐最短持续", "s", 0.1, 5),
                N("riKeepDownMin", "Keep-down minimum duration", "压制最短持续", "s", 0.2, 20),
                N("riMountMin", "Mounting minimum duration", "骑跨最短持续", "s", 0.2, 20),
                N("riThreatMin", "Lateral threat minimum duration", "侧身威胁最短持续", "s", 0.1, 5),
                N("riUprightRatio", "Upright: neck–tail shortened to", "直立：颈–尾根缩短到", "×", 0.3, 0.95),
                N("riSniffDist", "Sniffing distance", "嗅探距离", "BL", 0.1, 1)),
        ],

        ["group_behavior"] =
        [
            Rows(N("groupContactBL", "Contact distance", "接触距离", "BL", 0.1, 1)),
            Fold("Approach–avoid criteria (body lengths)", "接近–回避判定（体长 BL 为单位）",
                N("groupApproachSpeed", "Minimum speed", "最低速度", "BL/s", 0.1, 5),
                N("groupApproachDist", "Maximum distance", "最大间距", "BL", 0.5, 6),
                N("groupApproachMin", "Minimum duration", "最短持续", "s", 0.1, 3),
                N("groupChaseSpeed", "Chase speed", "追逐速度", "BL/s", 0.5, 10)),
        ],

        ["dyadic_social"] =
        [
            Rows(
                N("noseNoseDist", "Nose-to-nose distance", "鼻–鼻距离", "cm", 0.5, 10),
                N("anogenitalDist", "Nose-to-tail-base (anogenital) distance", "鼻–尾根（肛殖区）距离", "cm", 0.5, 10),
                N("bodySniffDist", "Nose-to-body distance", "鼻–身体距离", "cm", 0.5, 10),
                N("proximityDist", "Proximity (body center)", "近距离（身体中心）", "cm", 1, 50)),
            Fold("Following criteria", "跟随判定",
                N("followDist", "Maximum distance", "最大间距", "cm", 1, 60),
                N("followSpeed", "Minimum speed", "最低速度", "cm/s", 0, 50),
                N("followAngle", "Orientation tolerance", "朝向容差", "°", 5, 90),
                N("followMin", "Minimum duration", "最短持续", "s", 0, 10)),
        ],

        ["elevated_plus_maze"] =
        [
            Rows(
                C("openAxis", "Open-arm axis", "开放臂方向",
                  O("NS", "N–S (top/bottom)", "N–S（上下）"), O("EW", "E–W (left/right)", "E–W（左右）")),
                EntryRule()),
            Fold("Head dips and stretch-attend posture", "探头与伸展评估姿势",
                N("headDipReach", "Head-dip reach (past arm edge)", "探头范围（臂边缘外）", "cm", 1, 20),
                N("headDipMin", "Minimum head-dip duration", "探头最短持续", "s", 0, 3),
                N("sapElongation", "SAP body elongation factor", "SAP 身体伸长倍数", "×", 1.05, 2),
                N("sapSpeed", "Maximum SAP speed", "SAP 最高速度", "cm/s", 0, 30),
                N("sapMin", "Minimum SAP duration", "SAP 最短持续", "s", 0, 5)),
        ],

        ["elevated_zero_maze"] =
        [
            Rows(
                C("entryRule", "Segment-entry criterion", "进入某段的判定",
                  O("full", "Body center + tail base", "身体+尾根"), O("body", "Body center", "身体中心"))),
            Fold("Head dips, peeks and stretch-attend posture", "头探、探出与伸展评估姿势",
                N("ezmDipBeyond", "Head dip: nose past the edge by at least", "头探：鼻尖越出边缘至少", "cm", 0, 5),
                N("headDipMin", "Minimum head-dip duration", "头探最短持续", "s", 0, 3),
                N("pokeMin", "Minimum closed-segment peek", "闭合段探出最短持续", "s", 0, 3),
                N("sapElongation", "SAP body elongation factor", "SAP 身体伸长倍数", "×", 1.05, 2),
                N("sapSpeed", "Maximum SAP speed", "SAP 最高速度", "cm/s", 0, 30),
                N("sapMin", "Minimum SAP duration", "SAP 最短持续", "s", 0, 5)),
            Rows(Note("Enter the outer diameter and the track width under Arena dimensions; put the O handle on the middle of an open segment.",
                      "跑道外径和宽度在“场地尺寸”里填写；O 手柄放在一个开放段的中点。")),
        ],

        ["light_dark_box"] =
        [
            Rows(
                C("lightOnLeft", "Light compartment location", "明箱在画面",
                  O(true, "Left side", "左侧"), O(false, "Right side", "右侧")),
                P("lightFraction", "Light-side fraction of chamber length", "明箱占总长", 0.2, 0.8),
                N("pokeMin", "Minimum head-dip duration", "探头最短持续", "s", 0, 3)),
        ],

        ["novelty_suppressed_feeding"] =
        [
            Rows(
                // FeedingConfirmationStatus: the Mac confirms the first bite in its review panel, which
                // writes these two fields. Windows has no review panel yet, so they are entered here.
                Note("Confirm the first bite yourself: find it in the video and enter its time (video time), or tick “No feeding”. Until one of them is set the feeding latency stays empty and is not used in group statistics.",
                     "首次咬食需要人工确认：在视频里找到第一口，填入它的时刻（视频时间），或勾选“截止前未进食”。两者都未设置时，进食潜伏期为空，不进入组间统计。"),
                new FormRow
                {
                    Kind = RowKind.Toggle, En = "No feeding before the cut-off", Zh = "截止前未进食",
                    GetToggle = p => ParamValues.Flag(p, "nsfNoFeeding") == true,
                    // The engine takes a confirmed bite time over "no feeding", so clear the time.
                    SetToggle = (p, on) =>
                    {
                        p["nsfNoFeeding"] = on;
                        if (on) ParamValues.SetNumber(p, "nsfFeedingTime", -1, integer: false);
                    },
                    Keys = ["nsfNoFeeding", "nsfFeedingTime"],
                },
                N("nsfFeedingTime", "First bite at (video time; −1 = not confirmed)", "首次咬食时刻（视频时间；−1 = 未确认）", "s", -1, 360000)
                    with { When = c => !On(c, "nsfNoFeeding") },
                N("nsfFoodRadius", "Food zone radius", "食物区半径", "cm", 0.5, 15),
                P("centerFraction", "Center zone size (fraction of side)", "中央区大小（边长比例）", 0.2, 0.8)),
            Fold("Candidate feeding", "候选进食判定",
                N("nsfStillSpeed", "Maximum body-center speed", "身体中心最高速度", "cm/s", 0, 20),
                N("nsfStillMin", "Minimum duration", "最短持续", "s", 0, 30)),
            Rows(
                new FormRow
                {
                    Kind = RowKind.Toggle, En = "Hunger control", Zh = "录入饥饿对照",
                    GetToggle = HungerOn, SetToggle = SetHunger, Keys = HungerKeys,
                },
                N("nsfHomeCageFood", "Home-cage food in 5 min", "家笼 5 min 摄食量", "g", 0, 10) with { When = c => HungerOn(c.Params) },
                N("nsfWeightBefore", "Weight before the fast", "禁食前体重", "g", 0, 100) with { When = c => HungerOn(c.Params) },
                N("nsfWeightTest", "Weight on the test day", "测试前体重", "g", 0, 100) with { When = c => HungerOn(c.Params) },
                Note("Set the analysis start to the moment the mouse is placed in the arena, and the length to the cut-off (typically 600 s).",
                     "“分析起点”设为放入场地的时刻，“分析时长”设为截止时间（常用 600 s）。")),
        ],

        ["novel_object_recognition"] =
        [
            Rows(
                C("novelObject", "Novel object", "新物体", O("A", "A", "A"), O("B", "B", "B"))
                    with { When = c => c.Phase != "Training" },
                N("objectRadius", "Object radius", "物体半径", "cm", 0.5, 20),
                N("exploreMargin", "Investigation radius beyond object edge", "探索距离（物体外缘）", "cm", 0, 10),
                N("headTolerance", "Head-direction tolerance", "头朝向容差", "°", 5, 180)),
        ],

        ["barnes_maze"] =
        [
            Rows(
                N("holeCount", "Number of holes", "洞的数量", "items", 4, 60, integer: true),
                N("holeRadius", "Hole radius", "洞半径", "cm", 0.5, 10),
                N("pokeMargin", "Hole investigation margin", "探洞判定余量", "cm", 0, 5),
                N("holePokeMin", "Minimum hole-probe duration", "探洞最短持续", "s", 0, 2)),
        ],

        ["morris_water_maze"] =
        [
            Rows(
                N("mwmPlatformDiameter", "Platform diameter", "平台直径", "cm", 2, 40),
                N("mwmPlatformMargin", "Platform reach margin", "到达平台判定余量", "cm", 0, 10) with { When = c => c.Phase != "Probe" },
                N("mwmEscapeStay", "Time on the platform", "在平台上停留", "s", 0, 10) with { When = c => c.Phase != "Probe" },
                N("mwmCorridor", "Directed-search corridor", "定向通道宽度", "°", 10, 120) with { When = c => c.Phase != "Probe" },
                N("mwmZoneRadius", "Platform zone radius", "平台区半径", "cm", 2, 40),
                N("mwmWallZone", "Wall (thigmotaxis) zone width", "贴壁区宽度", "cm", 1, 30),
                N("mwmFloatSpeed", "Floating speed threshold", "漂浮速度阈值", "cm/s", 0, 10),
                N("mwmFloatMin", "Minimum floating duration", "漂浮最短持续", "s", 0, 10),
                Note("Set the analysis start to the moment the mouse enters the water, and the length to the maximum trial time (e.g. 60 s).",
                     "“分析起点”设为小鼠入水的时刻，“分析时长”设为最长试次时间（如 60 s）。")),
        ],

        ["passive_avoidance"] =
        [
            Rows(
                C("lightOnLeft", "Light compartment", "明室在", O(true, "Left", "左"), O(false, "Right", "右")),
                P("lightFraction", "Light compartment share", "明室所占比例", 0.2, 0.8),
                EntryRule(),
                N("pokeMin", "Minimum reverse probe", "反向探头最短持续", "s", 0, 3),
                Note("Set the analysis start to the moment the mouse is placed in the light side (or the door opens), and the length to the cut-off (typically 300 s).",
                     "“分析起点”设为放入明室（或开门）的时刻，“分析时长”设为截止时间（常用 300 s）。")),
        ],

        ["place_preference"] =
        [
            Rows(
                C("ppPairedSide", "Paired / stimulated side", "配对 / 刺激侧", O("L", "Left", "左"), O("R", "Right", "右")),
                P("ppSplit", "Divider position (from the left)", "分界位置（从左起）", 0.2, 0.8),
                T("ppMiddle", "Middle zone", "中间区"),
                P("ppMiddleFraction", "Middle zone width (of the length)", "中间区宽度（占总长）", 0.05, 0.6)
                    with { When = c => On(c, "ppMiddle") },
                C("ppRule", "Side change needs", "换边判定",
                  O("body", "Body center", "身体中心"), O("full", "Body center + tail base", "身体中心 + 尾根"))),
        ],

        ["y_maze"] =
        [
            Rows(EntryRule()),
        ],

        ["t_maze_vte"] =
        [
            Rows(
                N("choiceRadiusFactor", "Choice-point radius (× arm width)", "选择点半径（× 臂宽）", "×", 0.5, 3),
                N("vteZ", "VTE zIdPhi threshold", "VTE 阈值 zIdPhi", "", -2, 5)),
        ],

        ["fear_conditioning"] =
        [
            Rows(
                Onsets("csOnsets", "CS onset times", "CS 开始时间",
                       "Seconds since video start, comma-separated, e.g., 180, 260, 340",
                       "相对于视频开头的秒数，逗号分隔，如 180, 260, 340"),
                N("csDuration", "CS duration", "CS 时长", "s", 1, 600)),
            Freeze("Freezing detection", "僵直判定"),
            Rows(
                C("timeBin", "Plot bin size", "曲线分段",
                  O(20.0, "20 s", "20 s"), O(30.0, "30 s", "30 s"), O(60.0, "1 min", "1 min"), O(120.0, "2 min", "2 min"))),
        ],

        ["looming_escape"] =
        [
            Rows(
                Onsets("stimOnsets", "Stimulus onset times", "刺激出现时间",
                       "Seconds since video start, separated by commas", "相对于视频开头的秒数，逗号分隔"),
                N("shelterRadius", "Shelter radius", "巢穴半径", "cm", 1, 40)),
            Fold("Response detection", "反应判定",
                N("flightFactor", "Speed multiplier (× baseline)", "速度倍数（× 基线）", "×", 1, 20),
                N("flightMinSpeed", "Minimum escape speed", "最低逃跑速度", "cm/s", 1, 100),
                N("escapeWindow", "Response window", "反应窗口", "s", 1, 60),
                N("baselineWindow", "Baseline window", "基线窗口", "s", 1, 60)),
            // loomingFreezeAndThreatRows
            Rows(
                C("loomFreezeRule", "Freezing defined by", "僵直定义",
                  O("motion", "Motion index", "运动指数"), O("speed", "Body speed", "身体速度")),
                N("loomFreezeSpeed", "Speed below", "速度低于", "cm/s", 0.1, 20) with { When = c => Is(c, "loomFreezeRule", "speed") },
                N("loomFreezeMin", "Minimum duration", "最短持续", "s", 0, 10) with { When = c => Is(c, "loomFreezeRule", "speed") }),
            Freeze("Freezing detection", "僵直判定", c => !Is(c, "loomFreezeRule", "speed")),
            Rows(
                T("loomThreat", "Threat zone (T handle)", "威胁区（T 手柄）"),
                N("loomThreatRadius", "Threat-zone radius", "威胁区半径", "cm", 1, 40) with { When = c => On(c, "loomThreat") }),
        ],

        ["platform_avoidance"] =
        [
            Rows(
                N("pmaPlatformWidth", "Platform width", "平台宽", "cm", 2, 60),
                N("pmaPlatformHeight", "Platform height", "平台高", "cm", 2, 60),
                C("pmaRule", "On the platform when", "上平台的判定",
                  O("body", "Body center", "身体中心"), O("front", "Nose + neck", "鼻尖 + 颈"), O("full", "Body + tail base", "身体+尾根")),
                T("pmaReward", "Reward-port zone (R handle)", "奖励口区（R 手柄）"),
                N("pmaRewardRadius", "Reward-port radius", "奖励口区半径", "cm", 0.5, 15) with { When = c => On(c, "pmaReward") }),
            Freeze("Freezing detection", "僵直判定"),
            Rows(Note("Tones, shocks and rewards are logged by their own devices. The on_platform and freezing columns of rodentpose_frame_metrics.csv and the behaviour segments are in video time: cut each trial with the device's tone times.",
                      "声音、电击和奖励由各自的设备记录。rodentpose_frame_metrics.csv 中的 on_platform、freezing 列和行为片段 CSV 用视频时间，可按设备记录的声音时间切分每个试次。")),
        ],

        ["step_down"] =
        [
            Rows(
                N("sdPlatformWidth", "Platform width", "平台宽", "cm", 2, 40),
                N("sdPlatformHeight", "Platform height", "平台高", "cm", 2, 40),
                C("sdRule", "Stepped down when off", "下台的判定",
                  O("full", "Body + tail base", "身体+尾根"), O("body", "Body center", "身体中心")),
                N("sdDipMin", "Minimum edge head dip", "边缘探头最短持续", "s", 0, 3)),
            Freeze("Freezing on the platform", "平台上僵直判定"),
            Rows(Note("Set the analysis start to the moment the mouse is placed on the platform, and the length to the cut-off (typically 180 or 300 s).",
                      "“分析起点”设为把小鼠放上平台的时刻，“分析时长”设为截止时间（常用 180 或 300 s）。")),
        ],

        ["visual_cliff"] =
        [
            Rows(
                C("vcDeepSide", "Deep side", "深侧", O("L", "Left", "左"), O("R", "Right", "右")),
                P("vcSplit", "Center board position (from the left)", "中性区位置（从左起）", 0.2, 0.8),
                P("vcCenterFraction", "Center board width (of the length)", "中性区宽度（占总长）", 0.02, 0.6),
                C("vcRule", "Side change needs", "换边判定",
                  O("full", "Body + tail base", "身体+尾根"), O("body", "Body center", "身体中心")),
                N("vcEarly", "Early window", "前段时长", "s", 10, 3600),
                N("vcDipMin", "Minimum edge head dip", "边缘探头最短持续", "s", 0, 3),
                Note("Set the analysis start to the moment the mouse is placed on the center board.",
                     "“分析起点”设为把小鼠放到中间板上的时刻。")),
        ],

        ["marble_burying"] =
        [
            Rows(
                Note("Reading the marbles from the video is not in the Windows version yet, so the buried-marble count is not available; approaches to the marbles are.",
                     "Windows 版暂时还不能从视频读取珠子，所以没有埋珠数；接近珠子的次数和时间可以算。"),
                N("mbRows", "Rows of marbles", "珠子行数", "", 1, 12, integer: true),
                N("mbCols", "Columns of marbles", "珠子列数", "", 1, 12, integer: true),
                N("mbDiameter", "Marble diameter", "珠子直径", "cm", 0.5, 4),
                N("mbThreshold", "Buried when covered ≥", "埋住的阈值", "", 0.1, 1,
                  "Covered fraction of the marble's top-view visible area (0–1). The default 0.67 (67 % of the visible area, about 90 % burial by depth) is stricter than the by-eye “2/3 covered” rule.",
                  "珠子俯视可见面积被盖住的比例（0–1）。默认 0.67（可见面积的 67%，约相当于按深度埋住 90%），比肉眼按表面“2/3 以上”判断更严格。")),
            Fold("Reading the marbles", "读取珠子",
                N("mbSampleInterval", "Sampling interval", "取样间隔", "s", 0.2, 5),
                N("mbLeaveWait", "Wait after the mouse leaves", "小鼠离开后等待", "s", 0, 10),
                N("mbApproach", "Approach distance (from the edge)", "接近距离（珠子边缘）", "cm", 0, 5)),
            Rows(Note("Set the analysis start to the moment the mouse is put in, and the length to the test length (typically 30 min).",
                      "“分析起点”设为放入小鼠的时刻，“分析时长”设为测试时长（常用 30 min）。")),
        ],

        ["rotation"] =
        [
            Rows(
                C("lesionSide", "Lesion side", "损伤侧",
                  O("none", "Not set", "未设置"), O("left", "Left side", "左侧"), O("right", "Right side", "右侧")),
                T("cameraBelow", "Recorded from below (mirrored image)", "从下方拍摄（画面左右镜像）"),
                C("rotationBin", "Time bins", "分段",
                  O(60.0, "1 min", "1 min"), O(300.0, "5 min", "5 min"), O(600.0, "10 min", "10 min"))),
        ],

        ["pose_only"] =
        [
            Rows(Note("Pose-only export has no assay-specific parameters.", "仅导出姿态，没有范式参数。")),
        ],
    };

    // ---------------------------------------------------------------- every task (PoseCommonParamsEditor)

    /// <summary>The rows every task has: analysis window, keypoint confidence, smoothing, gap, time bins.</summary>
    public static FormGroup[] Common(string paradigm)
    {
        var (helpEn, helpZh) = WindowHelp(paradigm);
        var rows = new List<FormRow>
        {
            N("windowStart", "Analysis start", "分析起点", "s", 0, double.MaxValue),
            N("windowLength", "Analysis duration (0 = to end)", "分析时长（0 = 到结尾）", "s", 0, double.MaxValue, helpEn, helpZh),
            N("kpConf", "Keypoint confidence threshold", "关键点置信度阈值", "", 0.1, 0.9) with { Step = 0.05 },
            N("smoothing", "Smoothing window", "平滑窗口", "s", 0, 1, "Moving average; 0 = no smoothing", "滑动平均；0 = 不平滑"),
            N("maxGap", "Maximum interpolation gap", "最长插值缺口", "s", 0, 5),
        };
        if (paradigm != "fear_conditioning" && paradigm != "rotation")
        {
            rows.Add(paradigm == "morris_water_maze"
                ? C("timeBin", "Time binning", "时间分段",
                    O(10.0, "10 s", "10 s"), O(15.0, "15 s", "15 s"), O(20.0, "20 s", "20 s"), O(30.0, "30 s", "30 s"))
                : C("timeBin", "Time binning", "时间分段",
                    O(30.0, "30 s", "30 s"), O(60.0, "1 min", "1 min"), O(120.0, "2 min", "2 min"), O(300.0, "5 min", "5 min")));
        }
        return [Rows(rows.ToArray())];
    }

    private static (string En, string Zh) WindowHelp(string paradigm) => paradigm switch
    {
        "social_interaction" => ("Golden 2011 standard: 150 s", "Golden 2011 标准为 150 s"),
        "elevated_plus_maze" => ("Typical: 5 min (300 s)", "常用 5 min（300 s）"),
        "y_maze" => ("Typical: 8 min (480 s)", "常用 8 min（480 s）"),
        "morris_water_maze" => ("Start at the release into the water; length = maximum trial (typically 60 s)", "起点设为入水时刻；时长设为最长试次（常用 60 s）"),
        "step_down" => ("Start when the mouse is placed on the platform; length = cut-off (typically 180 or 300 s)", "起点设为放上平台的时刻；时长设为截止时间（常用 180 或 300 s）"),
        "visual_cliff" => ("Start when the mouse is placed on the center board; typical: 5 min (300 s)", "起点设为放到中间板上的时刻；常用 5 min（300 s）"),
        "marble_burying" => ("Start when the mouse is put in; typical length: 30 min (1800 s)", "起点设为放入小鼠的时刻；时长常用 30 min（1800 s）"),
        "platform_avoidance" => ("The whole training or test session; cut the trials with the tone times the device logged", "整段训练或测试；用设备记录的声音时间切分试次"),
        _ => ("Analyze only this period; saved detections are unchanged.", "只统计这段时间；不影响已识别的数据"),
    };

    /// <summary>The task's own rows; an unknown task has none.</summary>
    public static FormGroup[] For(string paradigm) => Tasks.TryGetValue(paradigm, out var g) ? g : [];

    /// <summary>
    /// Keys the forms use that are not in the engine's parameters for that task — a form typo or an
    /// engine change. Checked against the engine's own defaults when the window starts.
    /// </summary>
    public static List<string> UnknownKeys(string paradigm, JsonObject engineDefaults)
    {
        // Optional in the engine (encoded only when set).
        string[] optional = ["cornerFraction"];
        return For(paradigm).Concat(Common(paradigm))
            .SelectMany(g => g.Rows).SelectMany(r => r.AllKeys())
            .Distinct()
            .Where(k => !engineDefaults.ContainsKey(k) && !optional.Contains(k))
            .ToList();
    }
}
