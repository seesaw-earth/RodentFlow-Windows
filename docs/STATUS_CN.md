# 完成度、验证状况、已知差异

写于 2026-11-10。引擎源文件同步自 RodentFlow 2.1 的 `Shared/`
（63 个文件，23,617 行，SHA-256 见 `engine/Sources/RodentFlowABI/Shared/SYNC_STAMP.txt`）。

## 一、在 Windows 上实际验证到哪一步（2026-11-10 当天完成）

在一台 Windows 11（build 26200）、Swift 6.4.2、.NET 8.0.427、ffmpeg 9.0.2 上跑通：

| 检查点 | 结果 |
|---|---|
| 引擎编译（23,617 行 Swift） | ✅ 60 秒，0 错误，产出 9.25 MB 的 `RodentFlowABI.dll` |
| `@_cdecl` 符号在 Windows DLL 里导出 | ✅ 不需要 `.def` 文件，C# 直接 P/Invoke 成功 |
| C# → Swift 的 JSON 契约 | ✅ `rf_version`、`rf_catalogue`（27 个任务）、`rf_plan_run` 都对 |
| `corelibs-foundation` 的 `CGFloat` / `CGSize` / `FileHandle.truncate` | ✅ 都可用，一个 shim 都没加 |
| 整条链路 | ✅ 解码 → ONNX → `pose.mpt` → 分析 → 导出，全部产出 |
| 速度 | **23 ms/帧**（MousePose6，960 输入，CPU）——比按 Colab 估的 110 ms 快 5 倍 |
| 标注视频 | ✅ 骨架画在画面上，位置正确 |

### 当天发现并修掉的三个 bug

| bug | 为什么静态检查抓不到 |
|---|---|
| `rf_version` / `rf_catalogue` 的回复里缺 `"ok": true`，宿主把成功当成失败 | 符号全对，是契约语义。**已在 `check_abi.py` 里加了规则并用注入测试验证** |
| `info["handle"]` 塞 `Int32`，`JSONSerialization` 在 corelibs-foundation 上比 Apple 平台严格 | 同上，类型层面合法 |
| `-vsync 0` 在 ffmpeg 9.x 已被移除（改用 `-fps_mode passthrough`） | 外部工具的当前行为，不在代码里 |

第三个值得记：当初选 `-vsync 0` 的理由写的是"兼容性最广"，那是凭记忆的判断。**外部工具的当前行为要查，不能推断。**

### Windows 上的前置条件（文档原先缺这一条）

Swift 在 Windows 上编译需要 **Visual Studio 的 C++ 组件和 Windows SDK**（`stdlib.h` 来自 ucrt，微软不单独分发），并且要在 **x64 Native Tools Command Prompt** 里跑 `swift build`，否则 `INCLUDE` 没有指向 SDK，会报 `Invalid manifest` / `stdlib.h file not found`。

这只是**编译时**的要求。实验室电脑运行成品只需要 VC++ 运行库。

另外两点：
- Swift 6.4 的产物在 `.build/out/Products/Release-windows-x86_64/`，不是旧版的 `.build/release/`。
- 在 VS 开发者命令提示符里 `dotnet build` 会因为 `Platform=x64` 这个环境变量把输出放到 `bin/x64/Release/net8.0/`。

### 这个环境（写代码的机器）里能验证什么

装不上 Swift 工具链，也连不上 NuGet。所以：

| | 状况 |
|---|---|
| `RodentFlow.Engine`、`RodentFlow.Core`、自检 | ✅ 编译通过，0 警告（warnings-as-errors）；自检 7 组全部通过 |
| `RodentFlow.Cli` | ⚠️ 用 ONNX 替身类型编译通过 |
| `RodentFlow.App` 的 C#（窗口、视图模型） | ⚠️ 用 `check/winui_stub/` 的 WinUI 替身类型编译通过；XAML 的 37 个控件名、23 个事件处理器由脚本生成调用来核对签名 |
| `engine/`（Swift） | ❌ 这里编不了 → `check/check_abi.py` 静态核对（112 个调用 + 32 个属性读取，0 问题） |
| `RodentFlow.Onnx`（190 行） | ❌ 这里编不了，用到的 ONNX Runtime C# API 逐个查过文档 |
| 参数表单 vs Mac | ✅ `check/check_forms.py`：27 个范式逐个比对 Mac `PoseCalibrationEditor.swift` 绑定的参数键，以及引擎 `AnalysisParams.CodingKeys` |

**每个检查工具都做过注入测试**：
- `check_abi.py`：注入 5 处错误，5 处全部报出。
- `check_forms.py`：删掉一个参数、拼错一个、把一个挪到别的范式，3 处全部报出。
- WinUI 替身编译：XAML 里写一个不存在的处理器、改错一个处理器签名、代码里用一个 XAML 里没有的控件名，3 处全部报出。

**替身编译不等于真编译**：替身类型是照文档写的，它能抓 C# 本身的错（名字、类型、签名、XAML 和代码对不上），抓不到"真实 WinUI API 和我以为的不一样"。Swift 侧同理，`check_abi.py` 不检查实例成员的类型推断。这两类只有在 Windows 上真编译、真运行才会暴露。

## 三、已知和 Mac 不一样的地方

都是**故意**的选择，都还没有量过。要量的话：同一段视频在 Mac 和 Windows 各跑一次，
比对 `pose.mpt`（Mac 上本来就有"导入手机实验后重算比对"那套机制）。

| # | 这里 | Mac | 为什么这样选 |
|---|---|---|---|
| 1 | letterbox 填 114 | Vision `.scaleFit` 填黑 | 模型用 114 训出来的 |
| 2 | sRGB 空间 Rec.601 灰度 | `CIColorControls` 饱和度 0，线性空间 | 训练管线的做法；也和引擎 `AppearanceSampler` 的亮度权重一致 |
| 3 | 双线性，OpenCV `INTER_LINEAR` 的中心对齐约定 | Core Image 自己的重采样 | 训练时用的就是 `INTER_LINEAR` |
| 4 | 降采样时：先裁小图再缩到 960 | 先把小图放大回全帧尺寸，再裁，再缩 | 少一次重采样 |
| 5 | FP32 模型 | Core ML INT8 包 | 量化差本来就存在；定容差时要把这一项算进去 |
| 6 | 指纹算法和 Mac 不同值 | — | Mac 把 Swift 格式化的修改时间混进哈希，复现那个文本不值得冒错的风险。Windows 只和自己写的文件夹比，不需要一致 |

第 1–3 项加起来可能让关键点有亚像素到个别像素级的差别。第 5 项（INT8 vs FP32）很可能是最大的一项。

## 四、第一版没有包含的

| 内容 | 原因 |
|---|---|
| 多格悬尾（TST） | `MouseDetector` 只有 `.mlpackage`，没有 `.pt`，导不出 ONNX。规则代码（`TST/Core`，2,988 行）已经编进 DLL 了 |
| 视频遮挡 | 800 行，依赖 Mac 的硬件编码 |
| 手机 → 电脑同步 | `Sync/` 已经编进 DLL（纯 Foundation），只是没有界面 |
| 出版级图 | `Figures/`（2,052 行，含 SVG）已经编进 DLL；但组装一张场地图是 App 在自己的 UI 层做的（`PoseUI/PubFigureRender.swift`，没有同步进来） |
| 组间分析页 | `Groups/`（4,182 行）已经编进 DLL，没有界面也没有 ABI 入口 |
| 逐帧复核 / A-B 互换 | `rf_track_frames` 已经能读关键点，界面没做 |
| 圆筒 / PalmReader 模型 | README 写明 RodentLimb 已从 2.0 移除 |

## 五、范式设置（阶段 A，2026-11-10）

**原则**：每个范式要显示什么，全由引擎回答，C# 里没有任何"如果是 X 范式就……"的代码。

| ABI 入口 | 回答什么 | 引擎里的来源 |
|---|---|---|
| `rf_catalogue`（扩充） | 每个范式的场地类型、标记点、阶段、默认尺寸、配对阶段、简介 | `Paradigms.swift` |
| `rf_default_setup` | 某范式、某场地类型、某画面尺寸下的默认标定和默认参数 | `ArenaCalibration.makeDefault`、`AnalysisParams.defaults(for:)` |
| `rf_setup_view` | 当前设置下的区域（中央区、臂、杯、物体、象限……）、手柄、识别区域、比例尺；以及引擎读回的设置 | `ZoneBuilder.zones`（分析就用这些区域计数） |
| `rf_move_handle` | 拖一个手柄之后的新设置 | Mac `PoseCalibrationCanvas.move` 的规则，逐行抄进 `ABI/Setup.swift` |

参数面板由 `src/RodentFlow.Core/Setup/AssayForms.cs` 生成，逐项抄自 Mac 的 `PoseParamsEditor`（标题、单位、范围、显示条件）。

**引擎读回**：每次改动后，C# 保留的是引擎读回来的标定和参数，不是自己发出去的。引擎的解码是宽容的——读不懂的值会悄悄换成默认值——所以 C# 把发出去的和读回来的逐键比较，不一样就在状态栏报出来。

### 这一步顺带修掉的 bug（都会让结果出错，而且不报错）

| bug | 影响 |
|---|---|
| 阶段默认取范式阶段列表的**最后一项**，引擎把主测试阶段放在**第一项** | 新物体识别被当成 Training、三箱当成 Habituation、被动回避和 step-down 当成 Training、水迷宫当成 Reversal、位置偏好当成 Conditioning。GUI 和命令行都有这个问题 |
| 场地尺寸固定 40×40 cm、四角 0.1–0.9 | 除旷场外所有范式厘米换算错；命令行 `--task elevated_plus_maze` 不加 `--arena plus` 时变成矩形 |
| 命令行 `--param` 只发改动的参数 | 引擎对**不完整**的参数逐键用通用默认值补齐，不是该范式的默认值：十字迷宫丢掉 300 s 窗口、社交回避丢掉 150 s 窗口 |
| 命令行 `--param csOnsets=180,260` 被当成字符串 | 引擎读不懂，换成空列表，不报错 |

### 各范式状况

| 状况 | 范式 |
|---|---|
| 设置完整，可以分析 | 旷场、空间探索、头朝向、三箱社交、双鼠社交、居住者–入侵者、群体、高架十字迷宫、高架零迷宫、明暗箱、新物体识别、Barnes 迷宫、水迷宫、被动回避、Y 迷宫、T 迷宫、恐惧条件化、looming、平台回避、视觉悬崖、旋转、仅导出姿态 |
| 单阶段指标都有；**配对指标**要同一只鼠另一阶段的结果（阶段 B） | 社交回避（SI ratio、角落 ratio）、位置偏好后测（CPP 分数）、step-down 测试（测试 / 训练潜伏期比）。没有配对时引擎会在警告里说明 |
| 可以分析，首次进食需手填时刻 | 新奇抑制摄食（Mac 在回看面板里确认；Windows 暂时在参数里填视频时间） |
| 缺珠子读取 | 埋珠：没有埋珠数（`MarbleSampler` 还没移植，168 行），接近珠子的次数和时间有（阶段 B） |
| 多鼠能跑，缺身份复查 | 双鼠社交、居住者–入侵者、群体：没有 A/B 互换复查界面（阶段 C） |

配对用的是 `rf_analyze` 的 `companion` 字段（键名如 `iz_time`、`paired_time`、`step_down_latency`）。引擎的 `Paradigm.companionPhase(of:)` 只列了位置偏好和 step-down；社交回避的两个阶段是 Mac 应用层配对的，阶段 B 要照那边的规则补上。

## 五之二、结果页（阶段 R，2026-11-10 晚）

**目标**：Windows 的结果页和 Mac 的一样——同样的卡片、同样的图、同样的菜单、同样的措辞——而且结果
出自同一份报告。做法见 `docs/MAC_PARITY_CN.md`。

| 部分 | 文件 | 来源（Mac） |
|---|---|---|
| 报告整份交给宿主 | `engine/…/ABI/ReportView.swift`，`rf_analyze` 的 `includeReport` / `reportLanguage` | `AnalysisReport`；图层列表抄自 `FigureLayersSheet.layers` |
| 界面文字 | `rf_translate` → `L10n.tr`；C# `Core/Text/Tr.cs` | Mac 结果页的 L10n 键（60 余个，引擎词典里都有） |
| 契约 | `src/RodentFlow.Engine/ReportModels.cs`；`LenientDoubleConverter`（null → NaN） | — |
| 画法 | `Core/Figures/ReportFigures.cs`、`FigureKit.cs`、`Palette.cs`、`FigureStyle.cs` | `ReportFigures.swift`、`ReportPalette.swift`、`FigureOptions.swift` |
| 导出 | `FigureCards.cs`（420 / 640 宽卡片）、`SvgCanvas.cs`、`PdfCanvas.cs`、`PngEncoder.cs` | `FigureExport`、`RPReportBlockView` 菜单 |
| 屏幕 | `App/Figures/Win2DCanvas.cs`、`FigureView.cs` | SwiftUI `Canvas` |
| 页面 | `App/Results/ReportPresenter.cs`、`LayersDialog.cs`、`AdaptiveGridPanel.cs` | `PoseReportView`、`RPKeyResultCard`、`RPQualityCard`、`RPNoticeList` |
| 窗口 | `MainWindow.xaml`：SelectorBar「Calibrate / Results」；底栏「Update results」；左栏「Open an analysed folder…」；结果页上方语言切换 | Mac 实验页的步骤 |
| 状态 | `MainViewModel`：保存报告；设置改了就标为过期，切到结果页时自动重算；英文报告按需算一次；`rodentflow_session.json` / `rodentflow_run.json`；标定超出已识别区域的提示 | `TaskResultsView` |

**依赖**：新增 NuGet `Microsoft.Graphics.Win2D` 1.4.0（只在 App 项目）。

**验证到哪**：
- Swift：`check_abi.py` 0 问题（注入 3/3）。没有真编译。
- 契约：`check_report_contract.py` 159 个键、26 个对象两边一致（注入 5/5）。
- XAML ↔ 代码：`check_xaml.py` 48 个控件名、27 个处理器（注入 3/3）。
- C#：**这一轮的开发环境没有 .NET SDK，一行都没编译过。** 只做了括号配平检查（28 个文件）和逐行审阅。
  自检新增第 8–13 组，第一次 `dotnet run` 才会真正跑。
- `check/winui_stub` 替身编译没有更新，现在会失败（不认识 Win2D、SelectorBar 等），以 Windows 真编译为准。

**和 Mac 有意不同的地方**：
- 卡片圆角 12（Mac 20，Windows 卡片一般 8，取中间）；字号比 Mac 的文字样式大一号（Windows 同号字显小）。
- 柱图 / 折线是自己画的，坐标轴照 Swift Charts 的默认样子（y 轴刻度在右、细网格线），刻度取 1 / 2 / 2.5 / 5 的整数倍，
  不保证和 Swift Charts 选的刻度完全相同。
- 导出的卡片没有标题前的小图标（SF Symbols 没有对应字体）；矢量文件用 Helvetica / Arial，Mac 用系统字体。
- 多了「存为 SVG」；300 / 600 dpi 是菜单里两项，不读组间页的设置（Windows 还没有组间页）。
- printf 的半数（如 97.25 → `%.1f`）：Mac 四舍六入五成双，.NET 远离零。只影响窗口自己格式化的数（检出率等），
  卡片上的指标值是引擎格式化好的，两边一样。

## 五之三、工作区（阶段 W，2026-11-10 夜）

**目标**：和 Mac 一样按"任务 → 组 → 动物 → 实验"管理数据，不再一次只处理一个视频。

| 部分 | 文件 | 来源（Mac） |
|---|---|---|
| 数据与规则 | `Core/Workspace/Workspace.cs`：`WorkspaceStore`、`WorkspaceTask`、`WorkspaceSession`、`SessionSetup`、`SessionDates`、`NaturalComparer` | `WorkspaceStore.swift`、`SessionModel.swift`、`Shared/Tasks/SessionDate.swift`、`GroupAnalysisEngine.isLikelyControl` |
| 窗口 | `MainWindow.xaml`：`NavigationView` 侧栏 + 实验列表 + 任务页 / 实验页；实验页多了「Session info」一步 | `AnalysisWorkflowView.swift`、`WorkflowStep` |
| 窗口代码 | `MainWindow.Workspace.cs`（侧栏、列表、任务页、新建任务、添加视频、队列、实验信息） | 同上 |
| 添加视频 | `Workspace/ImportDialog.cs` | `ImportVideosSheet.swift` |
| 编辑一个实验 | `MainViewModel.OpenSession / PersistSetup / RunAsync / CopySetupToTask / ImportRunFolder` | `TaskSetup`、`NativeRunSession` |
| 不休眠 | `KeepAwake.cs` | `MacKeepAwake.swift` |

**行为**：
- 每个实验保存自己的设置（标定、参数、毛色、抽帧、时间范围）。拖手柄、改参数、改尺寸、改阶段都会写回；
  第一次改动之前，实验显示的是任务的默认布局，状态是"需要标定"——和 Mac 一样，没放过场地的实验不算"可以分析"。
- 「Use this setup for all sessions of the task…」把当前实验的场地和参数复制给同任务的其他实验（阶段各自保留）。
- 运行文件夹：`工作文件夹\任务名\小鼠_日期_s次数_编号\run1`、`run2` …；暂停或失败的运行在原文件夹继续
  （引擎从最后一帧接着跑）；如果设置已经和那次运行对不上，引擎会拒绝，程序自动开一个新的 runN，旧的保留。
- 状态：需要标定 / 可以分析 / 正在分析 / 已暂停 / 分析失败 / 已分析。程序退出时正在分析的，下次打开显示"已暂停"。
- 列表：待分析、待复核（已分析且"Tracking check"还是"Not checked yet"）、缺信息、已排除、全部。
- 「Analyse all ready」依次分析列表里可以分析的实验（已标定、信息完整、没排除、视频在原处；暂停的接着跑）；Stop 同时停住队列。
- 工作区存在 `%LOCALAPPDATA%\RodentFlow\workspace.json`，每秒最多写一次，关窗时再写一次。

**验证到哪**：`check_xaml.py`（76 个控件名、43 个处理器，读两个 partial 文件；注入 3/3）、括号配平（44 个文件）、
自检新增第 14–15 组（在 Windows 上跑）。文件名日期的规则另外用 Python 按同样的正则核对了 7 个例子。**C# 仍未编译过。**

**还没做**：分析完成的系统通知；组的手动排序和颜色（Mac 的 groupStyles，阶段 D 再做）；一个实验换任务；
多选实验批量改信息；工作区的导出 / 备份。

## 五之四、逐帧复核（阶段 V，2026-11-10 深夜）

**实验页的第四步「Review」**，对应 Mac 的 Video review 加上 Frame review 里的身份工具和追踪核对。

| 部分 | 文件 | 来源（Mac / 引擎） |
|---|---|---|
| 要检查的时刻 | `engine/…/ABI/ReviewABI.swift` `qcEvents`，随报告返回（`review.qc`） | `TrackingReviewEventBuilder.short`（阈值 0.35）；超出范围来自 `Analyzer.run` 的 `outsideArena` |
| A / B 互换 | `rf_swap_identity`、`rf_identity_segments`；`TrackCache.invalidate` | `IdentityResolver.correct(_:at:)` / `correct(_:from:to:)`、`PoseRunLoader.swapIdentity` |
| 轨迹在内存里 | `Core/Review/ReviewTrack.cs`（`rf_track_frames` 分块读） | `PoseTrack.nearestIndex`，复核的"¾ 步长 + 20 ms"规则 |
| 画在视频上 | `Core/Review/ReviewDrawing.cs` `PoseOverlay` | `MacPoseDrawing`、`AnimalGlyph.make`、`GlyphMetrics` |
| 时间轴 | `ReviewDrawing.cs` `ReviewTimeline`（复用 `ReportFigures.DrawTrack`） | `MacTimelineBars` |
| 播放 | `Core/Review/FramePlayer.cs` | `MacReviewPlayer`（AVPlayer） |
| 窗口 | `MainWindow.Review.cs`、`Figures/ReviewCanvas.cs`；`FigureView` 加了按下 / 拖动 | `VideoReviewView`、`ReviewExportView` |

**行为**：
- 两只鼠时出现「Swap A / B from this frame」和范围交换（先「Mark range start」，移到终点再点）。
  交换后 pose.mpt 重写，结果和要检查的时刻自动重算，该实验的"Tracking check"回到"Not checked yet"。
- 「The tracking is right / has problems」写进实验的 Tracking check（和 Session info 里是同一个字段，决定"待复核"列表）。
- 播放：一个 ffmpeg 进程从播放头起解码，缩到 960 宽，按每帧自己的时间戳（除以倍速）放；界面来不及就丢帧。
  单帧跳转、点时间轴、拖时间轴用单帧解码（连续请求只解最后一个）。
- 视频不在原处时，骨架画在黑底上，时间轴和交换照常可用。

**验证到哪**：`check_abi.py`（新文件注入 3/3）、`check_report_contract.py`（171 个键、29 个对象）、
`check_xaml.py`（97 个控件名、58 个处理器、3 个 partial 文件）、括号配平 49 个文件、自检第 16 组。
另外用 Python 重算了"某时刻显示哪一帧"的预期，发现并改正了自检里我自己写错的一条预期。**C# 和 Swift 都没编译过。**

**还没做**：手动标记行为与一致性（Mac `ManualScoringPanel`）、进食确认面板（新奇抑制摄食）、逐帧核对抽样
（Mac 的 viewed / flagged 帧列表）、键盘以外的快捷键、导出带标注的视频片段。

## 五之五、配对、埋珠、进食确认（阶段 B，2026-11-10 深夜）

| 部分 | 文件 | 来源（Mac / 引擎） |
|---|---|---|
| 配对 | `WorkspaceStore.Companion`、`WorkspaceSession.Values`；`MainViewModel.CompanionFor` | `SessionResultsEngine.companion`、`Paradigm.companionPhase` |
| 埋珠：读哪里 | `engine/…/ABI/MarbleABI.swift`（`rf_marble_plan`） | `MarbleGrid.pixelCenters / sampleKey`、`MarbleSampler.key(for:)`（抄了一份，文件头写明） |
| 埋珠：读像素 | `Core/Marbles/MarbleSampling.cs` | `MarbleSampler.sample`（取点、亮度、缓存格式） |
| 进食确认 | `MainWindow.Review.cs`（Review 下方一行）、时间轴的"候选进食"行 | `FeedingConfirmPanel` |
| 引擎读请求 | `RFCoding.decoder` 接受 "nan" / "inf" / "-inf"（Mac 文件的写法） | — |

**行为**：
- 每次分析后，实验保存全部有限的指标值（`Values`）。分析另一阶段时自动带上 companion，报告里就出现配对指标
  （SI ratio、CPP 分数、step-down 比）。打开已分析的实验会重算，所以先分析哪个阶段都可以。
- 埋珠：第一次分析（或珠子位置 / 大小 / 间隔改变后）会读整段视频一遍（状态栏显示百分比），之后用缓存。
  没有视频时报错，不给出没有主要指标的结果——和 Mac 一样。
- 新奇抑制摄食：在 Review 里确认首次进食后，潜伏期才进入组间统计（引擎的规则）。

**验证到哪**：`check_abi.py`（新文件注入 2/2）、`check_report_contract.py`（178 个键、30 个对象）、
`check_xaml.py`（103 个控件名、62 个处理器）、括号配平 52 个文件、自检第 17 组；取点数和亮度另用 Python 核对，
又改正了自检里我自己算错的一个亮度值（134.8，不是 135.0）。**仍未编译。**

## 五之六、组间比较（阶段 D，2026-11-10 深夜）

| 部分 | 文件 | 来源（Mac / 引擎） |
|---|---|---|
| 每个实验的摘要 | `rf_analyze` 的 `summary`（`SessionMetricSummary`）；`WorkspaceSession.Summary` | `SessionMetrics.summary`、`PoseMetricEntries.entries` |
| 组间分析与出图 | `engine/…/ABI/GroupABI.swift`（`rf_group_analysis`） | `GroupAnalysisEngine.run`、`TaskMetricDefinitions.context`、`PubGroupFigure.build`、`PubSVG.render`、`GroupReportText` |
| 契约 | `src/RodentFlow.Engine/GroupModels.cs` | — |
| 画出版图 | `Core/Figures/PubFigurePainter.cs`；画布接口加了 `RotatedText`（Win2D / SVG / PDF 都实现了） | `PubFigureView`、`PubRender` |
| 界面 | `App/Results/GroupPanel.cs`，放在任务页实验表下面 | `GroupsUI/GroupCharts.swift`、`GroupStatsCards.swift`、`TaskOverviewViews` |
| 引擎 JSON | 编码时 NaN 写作 "nan"（不再整条失败）；C# 读 "nan" / "inf" / "-inf" | Mac 文件的写法 |

**行为**：
- 只用"已分析、实验信息完整"的实验（和 Mac 一样，缺信息的不进汇总）；已排除的默认不进，可勾选包含。
- 跟踪核对为"有问题"的实验会标给引擎（`trackingProblem`），由引擎决定怎么在注释里说明。
- 改任何选项都会重新计算（在后台），卡片在计算时变淡。

**验证到哪**：`check_abi.py`（新文件注入 3/3）、`check_report_contract.py`（245 个键、40 个对象，请求字段另查 3 个结构；
注入 6/6）、括号配平 55 个文件、自检第 18 组。检查工具本身又修了一处：多行的位置记录（positional record）参数原来会把
类型名当成字段名。**仍未编译。**

**之后补上的**：协变量（ANCOVA）的选择框；固定 Y 轴范围（勾上时按当前数据给一个起止，可改）。

**还没做**：一次导出整套图（Mac 的图集 `TaskFigureExport`）；组的手动排序和颜色（Mac 的 groupStyles）。

## 五之七、没有编译器时降低编译风险（2026-11-10 深夜）

五个阶段都没在这里编译过，所以这一轮没有加新功能，专门查"一编译就会报"的错：

- 新写 `check/check_cs_members.py`：索引仓库里声明的所有 C# 类型（213 个；partial 类合并，记录的位置参数、
  项目内基类的成员都算），检查两种引用——`类型.成员`（静态成员、常量、枚举值、嵌套类型，也包括
  `RodentFlow.Engine.Engine.Analyze` 这样的限定名）和"本类里某个项目类型字段.成员"（如 `_model.UpdateResultsAsync`、
  `_store.FindTask`）。结果 0 问题；注入 4 种错误（改名的方法、拼错的静态成员、不存在的枚举值、拼错的 store 方法）4/4 抓到。
  它不查 WinUI / .NET 自己的成员（那要编译器），但项目内部改名或拼错是盲写代码最常见的编译错误。
- XAML：把新加的每个"元素.属性"列出来逐一核对；去掉了一处没把握的写法（`Grid` 上的 `IsTabStop`）。
- 逐一核对 Core / Engine / SelfCheck（这三个项目把警告当错误）里新代码的：switch 表达式是否都有兜底分支、可空性的流程、
  未使用的局部变量。没发现要改的。
- 复核时 Space 在已获焦的按钮上会和按钮自己的点击各触发一次，已改。

## 五之八、第一次在 Windows 上编译之后（2026-11-10 深夜）

- **编译结果**：引擎 77 秒编译通过（新的 4 个入口都在）；自检 18 组全部通过；App 只有 1 个 C# 错误
  （`Buffer` 同名：`System.Buffer` / `Windows.Storage.Streams.Buffer`），XAML 的 WMC9999 是它连带出来的。热修复 1 已改。
- **更新 2**（`06_更新2_…md`）：
  - 分析时显示剩余时间（按本次运行的速度）。
  - 分析时画面跟着动（`TrackingJob.PreviewMaxSide`：每次进度更新附一帧 640 像素的小图，是已解码的帧，几乎不花时间）。
  - 显卡加速：`Microsoft.ML.OnnxRuntime.DirectML` 1.24.4 取代 CPU 包（包里也有 CPU）；`OnnxPoseModel` 先试显卡，
    建会话失败就回到处理器并说明原因；设置 `UseGpu`（默认开），左栏可关；状态栏写明用的是哪个。
  - 整套中文界面，软件内即时切换：`ApplyLanguage()` 覆盖窗口里全部固定文字；切换时引擎按新语言重读目录
    （`MainViewModel.ChangeLanguage`，保持当前范式）；标定提示用 Mac 原文。

## 五之九、更新 3（2026-11-10 深夜）

- 切换任务时页面滞后：侧栏一动就作废还在打开中的实验（`_openGeneration`）；换任务时组间比较卡片立即清空；
  打开另一个实验时先清掉旧画面和结果；视频探测结果存盘缓存（`VideoProbeCache`，按大小和修改时间判断是否有效）。
- 去掉第二个语言切换，只保留结果页上的。
- 毛色只给本范式模型有的（`MainViewModel.CoatChoices`，抄自 `CoatColor.choices`）；群体范式不显示毛色、只显示只数。
- 每个范式都可"不标定"（`SetupABI.arenaKinds`：Mac 的列表 + none；Mac 共享代码未改）。
- 双鼠 / 多鼠画法与 Mac 一致：实时画面（Win2D 层 + `PoseOverlay.DrawPoses`）和复核视频（`AnnotatedVideoWriter.Request.Draw`
  → `Win2DAnnotation`）都改为一鼠画骨架、多鼠画彩色头部字形 + 字母牌。颜色值本来就与 Mac 相同。

## 五之十、更新 4（2026-11-10 深夜）

- 实时画面层移到手柄 / 区域层下面（更新 2 起它把区域盖住了）。
- 实时画面和骨架取自同一帧（原来骨架是第 k 帧、画面是第 k+14 帧）。
- 设备：`Device = auto | cpu | gpu`，默认 auto：每个模型文件第一次运行时实测处理器和 DirectML 0 / 1 各 10 帧（取 7 帧中位数），
  选最快并记入 `device-choice.json`；状态栏给出实测值。实测背景：单帧推理时每帧约 11 MB 的输入在内存和显卡之间往返，
  集成显卡或省电状态的显卡会输给快的处理器（ONNX Runtime 性能说明）。
- 模型输入缓冲区固定（`IPoseModelInput`，`OrtValue` 只包一次），流水线直接把帧写进去：每帧少一次约 11 MB 的拷贝和对象分配。
- 复核视频：Win2D 资源按尺寸复用；解码+绘制与编码并行（有界队列，缓冲循环使用）；探测用缓存。

## 六、接下来的顺序

1. **阶段 R 在 Windows 上编译、运行**：重编引擎（加了 `rf_translate`、`rf_analyze` 的报告），重编 App
   （NuGet 会拉 Win2D），跑自检，再按 `01_阶段R_先读这个.md` 的测试清单逐项看。
2. **阶段 W 在 Windows 上编译、运行**（本节五之三），按 `02_阶段W_工作区_先读这个.md` 的清单试。
3. **阶段 B**：配对阶段（选同一只鼠的另一个运行结果）、埋珠读取（移植 `MarbleSampler`，168 行）、进食确认的回看时间轴。
4. **阶段 V 在 Windows 上编译、运行**（本节五之四），按 `03_阶段V_逐帧复核_先读这个.md` 的清单试。
5. **阶段 D 在 Windows 上编译、运行**（本节五之六），按 `05_阶段D_组间比较_先读这个.md` 的清单试。
6. **和 Mac 比一次**：同一段视频、同一个模型，比 `pose.mpt`，定容差（第三节的 6 项差异写进容差说明）。

## 七、性能估计（没有实测）

11-10 那次导出里，Colab CPU 上 ONNX Runtime 的速度是：n 模型约 107–112 ms/帧，s 模型约 205–233 ms/帧。
按这个速度，一段 10 分钟 30 fps 的视频逐帧识别要 50–120 分钟。实验室的桌面 CPU 会快一些，
DirectML 或 TensorRT 应该快得多。要点：

- `--stride` 可以抽帧（引擎支持，分析用的就是实际识别的帧）；
- 大画面会自动降采样解码（`rf_plan_run` 给出尺度）；
- `rf_run_frame` 之外的开销很小：预处理在 C# 里是托管代码的双线性，1080p 大约几毫秒，
  和模型时间比可以忽略；真要优化可以把裁剪/缩放/填充/灰度整条都交给 ffmpeg 的滤镜图。
