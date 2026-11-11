# 让 Windows 版和 Mac 版一样好：差距、做法、顺序

写于 2026-11-10，阶段 R（结果页）完成时。目的是让之后每一步都按同一套规则做，不靠记忆。

## 一、总原则（三条，之前的五条原则不变）

1. **Mac 上凡是"数据"的东西，都从引擎要；Mac 上凡是"画法"的东西，逐行移植。**
   Mac 的结果页看着复杂，但图上的每个数——区域、热图格、轨迹、刻度、CSV、英文标题——都来自
   `AnalysisReport`，UI 只是画。所以 Windows 用一个 ABI 入口把报告整份拿过来（`ABI/ReportView.swift`），
   再把 `ReportFigures.swift` 的画法照抄到 C#（`RodentFlow.Core/Figures/ReportFigures.cs`）。
   只要两边画的是同一份数据，就不会出现"Windows 的图和 Mac 的数对不上"。
2. **文字也走引擎。** 结果页上的界面文字（"全部指标""起点""%d 条提示"）通过 `rf_translate`
   用引擎的 `L10n.tr` 翻译，所以两个平台措辞一字不差。只有 Windows 窗口自己的文字才用 `AppText.L(en, zh)`。
3. **一次画，三处用。** 图只对 `IFigureCanvas` 画一次：屏幕（Win2D）、SVG、PDF 是三个实现，
   PNG 是 Win2D 离屏渲染。这就是 Mac 上 CoreGraphics 的角色——Mac 的屏幕和 PDF/PNG 导出也是同一段 Canvas 代码。

## 二、Mac 和 Windows 现在差在哪（逐项）

| 方面 | Mac（文件） | Windows 现在 | 阶段 |
|---|---|---|---|
| 单次实验结果页 | `PoseResultFigures.swift` PoseReportView | ✅ 阶段 R：同样的顺序、卡片、图、菜单 | R |
| 图：场地、热图、原图对照、时间轴、柱、线、极坐标、表 | `Shared/PoseUI/ReportFigures.swift` | ✅ 逐段移植 | R |
| 图层开关、原图叠加 / 并排、按范式记住 | `FigureLayersSheet`、`FigureStyleStore` | ✅ 同样的键和 JSON 形式 | R |
| 复制图像 / PNG / 矢量 PDF / 300·600 dpi / CSV | `RPReportBlockView` 菜单、`FigureExport` | ✅ 另加 SVG；PNG 写入 dpi | R |
| 改标定或参数后重算，不重新识别 | `TaskResultsView` + `SessionOutputCache` | ✅ "Update results"，切到结果页时自动重算 | R |
| 标定超出已识别区域的提示 | `TaskResultsView.outsideTrackedRegion` | ✅ | R |
| 重新打开以前的分析 | 工作区里一直都在 | ✅ 工作区里一直都在；阶段 R 的运行文件夹可用「Import an analysed folder…」并入 | R/W |
| 工作区：任务 → 组 → 动物 → 实验，智能列表 | `AnalysisWorkflowView`、`WorkspaceStore` | ✅ 阶段 W：侧栏、实验列表、任务页、实验信息步骤 | W |
| 批量分析队列、进度、后台完成提醒 | `NativeRunSession` | ✅ 「Analyse all ready」顺序分析；分析时不休眠。完成提醒没有做 | W |
| 逐帧复核：时间轴、骨架、超出范围、A/B 互换、追踪核对 | `VideoReviewView`、`ReviewExportView` | ✅ 阶段 V：「Review」一步 | V |
| 手动标记行为、与自动判定比精确率 / 召回率 | `ManualScoringPanel`、`BehaviorSegments` | ❌ | V2 |
| 配对阶段（SI ratio、CPP、step-down 比） | `SessionResultsEngine.companion` | ✅ 阶段 B：同一小鼠另一阶段的已保存数值 | B |
| 埋珠读数（`MarbleSampler`）、进食确认 | `Shared/Vision/MarbleSampler.swift`、`FeedingConfirmPanel` | ✅ 阶段 B：ffmpeg 读像素，规则同 Mac；进食确认在 Review | B |
| 组间统计、图、Prism / R 表 | `GroupsUI/`、`TaskOverviewViews` | ✅ 阶段 D：任务页「Group comparison」 | D |
| 一次导出整套图（图集） | `TaskFigureExport` | ❌（单张图都能导） | D2 |
| 首次启动引导 | `PoseUI/Onboarding` | ❌ | 最后 |
| 视频遮挡、手机同步、多格悬尾 | `VideoPatch/`、`Sync/`、`TST/` | ❌（见 STATUS 第四节） | 之后 |

## 三、SwiftUI → WinUI 3 对照表（以后照这张表做）

| Mac 用的 | Windows 用的 | 要注意的 |
|---|---|---|
| `Canvas { ctx, size in … }` | Win2D `CanvasControl` + `Draw` 事件 | 从 .NET 用必须显式 `RemoveFromVisualTree` 并丢掉引用，否则泄漏（`FigureView.Release`） |
| `ImageRenderer` → PNG（scale = dpi/72） | Win2D `CanvasRenderTarget(device, w, h, dpi)` + `SaveAsync` | Win2D 的单位是 1/96 英寸：每单位 s 个像素就传 `96 × s`；渲染目标要先 `Clear`；PNG 的 dpi 标记另写（`PngEncoder.SetDpi`） |
| CoreGraphics PDF | 手写 `PdfCanvas`（Helvetica，WinAnsi） | 导出是英文，所以标准字体够用；≥ 等非 WinAnsi 字符换写 |
| Swift Charts | 自己画（`ReportFigures.Bars/Line`），轴线照 Swift Charts 的默认：y 轴在右侧、网格线、零线 | Windows App SDK 2.6 的 Chart 控件还在实验通道，不能用于正式应用 |
| `LazyVGrid(.adaptive(minimum: 148))` | 自定义 `Panel`（`AdaptiveGridPanel`） | |
| `DisclosureGroup` | `Expander` | |
| `Menu` / `.contextMenu` | `MenuFlyout`（按钮 `Flyout` + 卡片 `ContextFlyout`，两个实例） | |
| `.sheet` | `ContentDialog`（要设 `XamlRoot`） | 同一时刻只能开一个 |
| `NSSavePanel` | `FileSavePicker` + `InitializeWithWindow.Initialize(picker, hwnd)` | 非打包应用必须给窗口句柄 |
| `NSPasteboard` | `Clipboard.SetContent(DataPackage)` | 只能在应用位于前台时写，否则抛异常；`Flush()` 让内容在退出后保留 |
| `@AppStorage` / UserDefaults | `%LOCALAPPDATA%\RodentFlow\*.json` | |
| `WorkspaceStore`（Application Support/workspace.json） | `RodentFlow.Core.Workspace.WorkspaceStore`（`%LOCALAPPDATA%\RodentFlow\workspace.json`） | 先写临时文件再替换；读不出的文件先另存一份、绝不覆盖（和 Mac 一样） |
| `MacKeepAwake` | `KeepAwake`（`SetThreadExecutionState`） | 开始和结束要在同一个线程 |
| 导入视频 sheet | `ContentDialog`（`ImportDialog`） | ContentDialog 默认很窄：在它的 `Resources` 里改 `ContentDialogMaxWidth` |
| `L("en", "zh")` | `AppText.L(en, zh)` | |
| `L10n.tr("中文")` | `Tr.T("中文")`（经 `rf_translate`） | 格式串用 `Tr.F`，规则同 `String(format:)`，小数点永远是点 |
| 分段控件 / 步骤 | `SelectorBar` | 没有 `SelectedIndex`、没有 `ItemsSource`；**不要在 XAML 里写 `IsSelected`**——事件会在窗口建好之前触发（否则启动时就会崩溃） |
| AVPlayer + 叠加层 | 一个 Win2D `CanvasControl` 同时画帧和骨架（`ReviewCanvas`）；ffmpeg 从某时刻起解码、按每帧自己的时间戳放（`FramePlayer`）；单帧跳转用 `VideoFrameGrabber` | 界面来不及画时丢帧，播放器不等；每换一帧释放上一帧的 GPU 位图 |
| `NavigationSplitView` 三栏 | `NavigationView`（左，任务 → 组、列表，`InfoBadge` 显示数目）+ `ListView`（中）+ 内容区（右） | 侧栏按内容签名重建，选中项按 Tag 恢复；重建时用 `_quiet` 挡住 SelectionChanged |
| 系统浅色 / 深色 | 根元素 `ActualTheme` + `ActualThemeChanged` | 图用 `FigureTheme`，导出永远浅色（和 Mac 一样） |

## 四、版本与依赖（查过的事实，不要凭记忆改）

- Windows App SDK：截至 2026-11-10 最新稳定版 **2.6.5**（工程里就是这个）。实验通道的 TableView、Chart 不用。
- Win2D：`Microsoft.Graphics.Win2D` **1.4.0**，依赖 `Microsoft.WindowsAppSDK.WinUI ≥ 1.8.260204000`；
  PowerToys 用的就是 Windows App SDK 2.6.4 + Win2D 1.4.0。Win2D 是原生代码，工程必须是 x64 / arm64，
  不能是 AnyCPU（工程已经是 x64）。
- Swift 运行库随包发布：Windows 上 `-static-stdlib` 目前不能用（Windows SDK 不带静态库；实验版 Swift SDK
  才有静态运行库）。可行做法：对 `RodentFlowABI.dll` 递归跑 `dumpbin /dependents`，把 Swift 运行库、Foundation、
  ICU 的 DLL 一起放进程序文件夹，再装 VC++ 运行库（微软推荐用 Redistributable 安装包集中部署）。
  这一步留到发布前做，见 STATUS 第七节。

## 五、阶段顺序和理由

1. **R 结果页**（本次）。它是后面所有阶段的底座：配对指标显示在同一页；复核的时间轴复用
   `ReportFigures.DrawTrack`；组间图集复用同一个画布接口（引擎的 `PubFigure` 也可以画上去）。
2. **W 工作区**（已做）：任务 → 组 → 动物 → 实验，智能列表（待分析、待复核、缺信息、已排除、全部），批量队列。
   规则全部照 Mac：每段视频是一只小鼠的一次实验；小鼠编号、日期、实验次数必填；分组和性别属于小鼠；
   日期从文件名读（2026-10-17 / 2026_10_17 / 20261017），读不到用文件创建日期并提示核对；
   组的顺序是"像对照组的"在前（WT、Veh、control …），"未分组"在最后；小鼠按自然顺序（M2 在 M10 前）。
3. **V 逐帧复核**（已做）：视频 + 骨架（两只鼠：A 蓝 B 红的头部三角、鼻线、尾根点、字母牌）+ 2 秒轨迹 + 区域；
   时间轴（要检查的时刻按种类分行、行为、时段、播放头，可点、可拖）；播放（0.25–4×）、逐帧、上一个 / 下一个时刻；
   「从此帧起交换 A / B」「在范围内交换 A / B」（引擎的 `IdentityResolver.correct`，重写 pose.mpt 后自动重算）；
   追踪核对。要检查的时刻由引擎从 pose 轨迹算（`ReviewABI.qcEvents`，Mac `TrackingReviewEventBuilder.short` 的移植，
   阈值同 Mac 的 0.35）。**手动标记行为**（`ManualScoringPanel`）留到 V2。
4. **B**（已做）：
   - 配对：每个实验分析后保存全部指标值；另一阶段分析时取同一小鼠、已分析、最近完成的那次的数值作 companion
     （位置偏好：后测取前测；step-down：测试取训练；社交互动：两个阶段互取）——`SessionResultsEngine.companion` 的规则。
   - 埋珠：要读哪里由引擎给（`rf_marble_plan`：`MarbleGrid.pixelCenters`、`mbSampleInterval`、缓存键）；像素用 ffmpeg 读，
     取点、亮度公式照 `MarbleSampler.sample`；读数存成 Mac 同格式的 `marble_samples.json`（NaN 写作 "nan"），键不变就不再读。
     与 Mac 的差别：ffmpeg 的 fps 滤镜取的是每个读数时刻"之前或当时"的最后一帧，Mac 取"当时或之后"的第一帧，最多差一帧。
   - 进食确认（新奇抑制摄食）：Review 里列出候选进食、跳过去、设为首次进食 / 截止前未进食 / 清除；存在参数里
     （`nsfFeedingTime`、`nsfNoFeeding`），结果随即重算——`FeedingConfirmPanel` 的做法。
5. **D**（已做）：任务页的组间比较。
   - 引擎：`rf_analyze` 顺带返回每个实验的 `SessionMetricSummary`（Mac 每个实验存一份的那种）；`rf_group_analysis`
     吃进这些摘要和实验信息，跑 `GroupAnalysisEngine.run`，用 `PubGroupFigure.build` 出图——给出画图条目和 SVG 两种形式。
   - 窗口：设计、指标 / 时间进程 / 配对、阶段、实验次数、检验（参数 / 非参数）、比较方式、第二因素、与参考值比较、
     是否包含已排除的实验、纳入哪些组；图的样式（点 / 柱 / 箱线 / 小提琴、误差线、显著性、灰度）。全部选项来自引擎。
   - 屏幕上画的就是要导出的那张出版图（Mac 也是 `PubFigureView` 画同一个 `PubGroupFigure`）；导出 PDF / SVG / 300·600 dpi PNG，
     统计表和"每只小鼠一行"的数据表（CSV，给 Prism / R），文件一律英文。
   - 请求和样式随任务保存。

## 六、每一步的检查方法（这里没有编译器时）

| 工具 | 查什么 | 注入测试 |
|---|---|---|
| `check/check_abi.py` | ABI 层引用的引擎类型、成员、参数标签 | 本次 3/3（成员拼错、参数标签错、属性名错） |
| `check/check_report_contract.py` | Swift 写的键 ↔ C# 读的属性（报告、复核、埋珠、组间：245 个键、40 个对象），以及 C# 发出的请求字段 ↔ Swift 解码的字段（rf_analyze、rf_group_analysis） | `--selftest` 6/6 |
| `check/check_cs_members.py` | 项目内 C# 引用：`类型.成员`（含枚举值、嵌套类型、限定名）、"项目类型字段.成员"，213 个类型 | `--selftest` 4/4 |
| `check/check_xaml.py` | XAML 里的事件处理器在代码里存在且是两个参数；代码用到的控件名在 XAML 里有。读同一个窗口的所有 partial 文件（`MainWindow.*.cs`） | `--selftest` 3/3 |
| `check/check_forms.py` | 27 个范式的参数键 vs Mac 参数面板 vs 引擎 | 之前 3/3 |
| `tools/RodentFlow.SelfCheck` | 新增 18 组：出版图条目画进 SVG / PDF（曲线、虚线、旋转的 y 轴标题）、回复里的 "nan"、发给引擎的实验字段名。另有 17 组：配对规则（三种范式）、埋珠取点和亮度、读数文件的 Mac 格式。另有 16 组：复核（两鼠字形的几何对照 `AnimalGlyph.make`、某时刻显示哪一帧、时间轴的行、画进 SVG）。另有 14–15 组：工作区（文件名里的日期、小鼠编号猜测、自然排序、组顺序、下一个实验次数、冲突、分组随小鼠、阶段、列表、run1/run2、保存后读回、"运行中"读回为"已暂停"、读不出的文件另存）。另有 8–13 组：printf、调色板和坐标轴、报告 JSON（含 null→NaN）、每种图画进 SVG / PDF（XML 能解析、PDF 交叉引用表对、压缩流能解开）、PNG 和 dpi 标记、图层设置读写 | 在 Windows 上 `dotnet run` |

**替身编译（`check/winui_stub`）这次没有更新**，它不认识 Win2D 和新加的控件，现在跑会失败。真编译以 Windows 为准。
