# 分界在哪里，为什么

## 一、为什么不把引擎改写成 C# 或 Python

App 的 `Shared/` 里有 23,617 行只依赖 Foundation 的代码：

| 内容 | 行数 |
|---|---|
| `PoseEngine/` 姿态引擎、各任务判定、导出、Methods | 13,219 |
| `Groups/` 组间统计 | 4,182 |
| `Figures/` 出版级图（含 SVG 输出） | 2,052 |
| `TST/Core/` 多格悬尾规则 | 2,988 |
| `Tracking/`、`Tasks/`、`Sync/` | 1,176 |

改写成第二种语言意味着两份判定、两份阈值、两套统计，而且每次 App 改规则都要改两处。
本来最担心的"引擎能不能离开 Apple 框架"已经有答案：`Shared/` 11-09 那次就在 Linux 上用
Swift 5.10 编译并跑过测试（`tools/run_shared_tests.sh`，14 项里 12 项通过，另两项在未改动的原包上同样失败）。
Windows 的 Swift 工具链和 Linux 用的是同一套 swift-corelibs-foundation。

所以：引擎原样编译成 DLL，C# 只做 Apple 框架替代品的那三件事。

## 二、模块怎么分

```
engine/Sources/RodentFlowABI/
├── Shared/          63 个文件，从 App 同步，一个字母都没改
├── Platform/        WindowsShims.swift：Lang / L / RFText / AppInfo / FlowAssay
└── ABI/             ABISupport · RunPlan · TrackingRun · AnalysisRun · Setup · ABI
```

**只有一个 Swift 模块。** 这是被迫的，也是对的：`Shared/` 里所有类型都没写访问修饰符，
默认就是 `internal`，只在自己的模块内可见。如果把 ABI 放进单独的 target，它看不到
`PoseTrack`、`Analyzer` 这些类型，就只能给引擎源码批量加 `public`——那就改动了共享代码。
放在同一个模块里，一行都不用改。

`Platform/WindowsShims.swift` 是每个 App 都要给引擎提供的那 5 个符号。iOS、Mac 和
`tools/test_support/TestShims.swift` 各有一份，这是 Windows 的那份。除了把语言开关从环境变量
改成可设置的标志、以及 `AppInfo` 写 Windows 的版本号，内容和测试用的那份一致。

## 三、C ABI：一次 run 怎么跑

Mac 上 `PoseStreamEngine.run` 是一个函数拥有整个循环，自己从 AVFoundation 拉帧。
Windows 上反过来：**C# 拥有循环**，Swift 拥有循环体里模型之后的一切。

```
rf_plan_run(settings, calibration, frameW/H)
    → 用哪个模型、裁哪块（像素）、解码多大
      这三件都是引擎的决定，所以由引擎回答，C# 不另写一份

rf_run_open(request)  → handle + 循环要用的参数

对每一个解码出来的帧，按顺序：
    rf_run_filter(handle, time, &frameNumber)
        1  这帧要识别（和 Mac 读帧循环里那几个 guard 完全一致：
           续跑点、时间范围、抽帧间隔）
        0  跳过
       -1  还没到范围，继续解码
       -2  过了范围，停止解码
    若为 1：C# 裁剪 → 灰度 → letterbox → ONNX
    rf_run_frame(handle, frameNumber, time, tensor, 形状, 裁剪矩形, BGRA缓冲)
        Swift：PoseDecoding.decode → ArenaROI.uncrop
             → OnlineIdentityTracker / GroupIdentityTracker / bestPose
             → AppearanceSampler（双鼠毛色）
             → PoseStreamFormat.row → 分段 CSV → manifest

rf_run_finish(handle, msPerFrame)
    → PoseStreamFormat.assemble → IdentityResolver.resolve → pose.mpt

rf_analyze(session, poseFile, outDir)
    → Kinematics.build → Analyzer.run → Exporter.{reportJSON, frameCSV, metricsCSV, textSummary}
      + BehaviorSegments.csv
```

把抽帧规则放在 `rf_run_filter` 里而不是让 C# 自己算，是为了不出现第二份规则。
同样的理由，ROI、裁剪矩形的取整（`NRect.pixelRect`，最小 32 px、向外取整）、模型路由
（`PoseModels.name(for:)`）都走 `rf_plan_run`。

唯一在 ABI 层重写的引擎逻辑是 `PoseFrame.decodeScale`（4K 视频的降采样尺度，约 10 行算术），
因为它住在 `Shared/Vision/PoseVision.swift` 里，那个文件依赖 Core ML。`RunPlan.swift` 里注明了
这一点，两边要一起改。

### 约定

- 返回的每个 `char*` 都由 Swift 分配，必须还给 `rf_string_free`，两边的运行时不互相释放内存。
- 请求和结果都是 UTF-8 的 JSON，结果一律是 `{"ok":true,…}` 或 `{"ok":false,"error":"…"}`。
- 逐帧那个调用走标量和裸指针，不走 JSON（一段 10 分钟 30 fps 的视频有 18,000 帧）。
- 一个 handle 只能由一个线程驱动，和 Mac 一样。
- C# 交给 Swift 的 BGRA 缓冲**必须是正立的**（ffmpeg 默认已经应用了容器里的旋转）。
  所以 `RawImageGeometry` 用 `.up`，降采样造成的尺寸差由 `AppearanceSampler` 自己换算。

### 范式设置：每个范式要显示什么，由引擎回答（`ABI/Setup.swift`）

27 个范式的标定和参数各不相同：十字迷宫有 5 个臂端手柄，三箱有杯子和可拖的中箱分隔线，
水迷宫有平台，埋珠有 4 个角珠……如果在 C# 里按范式写分支，就是第二份规则。所以：

```
rf_catalogue        每个范式的场地类型、标记点、阶段（主测试阶段在第一项）、默认尺寸、配对阶段
rf_default_setup    ArenaCalibration.makeDefault + AnalysisParams.defaults(for:)
rf_setup_view       ZoneBuilder.zones（分析就用这些区域计数）+ 手柄 + 识别区域 + 比例尺
                    + 引擎读回的标定和参数
rf_move_handle      拖一个手柄 → 新设置（拖动规则抄自 Mac 的 PoseCalibrationCanvas.move）
```

手柄和拖动规则在 Mac 上住在 UI 层（`RodentStudio/Views/PoseCalibrationEditor.swift`），没有进
`Shared/`，所以逐行抄进了 `Setup.swift`，文件头写明了出处，两边要一起改。

**参数永远是完整的一份，而且以引擎读回的为准。** 引擎的解码是宽容的：缺的键补默认值，
读不懂的值（比如 Int 字段收到 20.5）悄悄换成默认值。更隐蔽的是，**不完整**的参数对象里缺的键
补的是通用的 `AnalysisParams()` 默认值，不是这个范式的 `defaults(for:)`。所以 C# 从引擎拿一份
完整参数，原地改，发回去，再保留引擎读回的那份，并逐键比较发出和读回——不一致就在状态栏报出。

参数面板是数据，不是代码：`src/RodentFlow.Core/Setup/AssayForms.cs` 逐项抄自 Mac 的
`PoseParamsEditor`，窗口按行类型（数字、百分比、选项、开关、时间列表、说明）生成控件。
`check/check_forms.py` 逐个范式比对两边绑定的参数键。

### 结果页：报告整份交出来，C# 只画（`ABI/ReportView.swift`）

```
rf_analyze { …, includeReport: true, reportLanguage: "interface" | "english" }
   → report: 主要指标及刻度、全部指标、提示、Methods、识别质量、
             blocks[]：arena | timeline | bars | line | polar | table
                       （区域轮廓；区域和热图格映射到原图的像素坐标；原图裁剪；可开关的图层；CSV）
rf_translate { texts: ["全部指标", "%d 条提示"], english } → 同一套 L10n 词典
```

Mac 的结果图在 UI 层（`Shared/PoseUI/ReportFigures.swift`），但它画的全部是 `AnalysisReport` 里的数据。
所以 Windows 不另算任何东西：几何（`ArenaMapping.toImage`、`FigureGeometry.cellCorners / frameCrop`）、刻度
（`MetricScale`）、CSV（`BlockCSV`）、英文（`ReportEnglish`）都在引擎里算好；C# 的 `ReportFigures.cs`
逐段照抄 Mac 的画法。只有 `FigureLayersSheet.layers`（哪些图层可开关）在 PoseUI 里，抄进了 `ReportView.swift`，
文件头写明了出处。

画法只写一次，对着 `IFigureCanvas`：

```
ReportFigures / FigureCards ──► IFigureCanvas ─┬─ Win2DCanvas  屏幕（CanvasControl）、PNG（CanvasRenderTarget）
                                               ├─ SvgCanvas    矢量 SVG
                                               └─ PdfCanvas    矢量 PDF（手写，Helvetica）
```

这样屏幕上看到的和导出的文件是同一段代码画的，和 Mac 用同一个 SwiftUI Canvas 画屏幕和 PDF 一个道理。
导出时卡片宽 420（热图与原图并排 640），四周留 12，浅色——都是 Mac `FigureExport` 的值。

## 四、C# 这边为什么分成四个项目

`RodentFlow.Onnx` 需要 NuGet 包，`RodentFlow.App` 需要 Windows。把它们和其余部分分开，
意味着最容易出错的那两部分——FFI 契约和图像几何——可以在任何机器上编译和自检：

- `RodentFlow.Engine`：无外部依赖（`System.Text.Json` 在 .NET 8 框架里）
- `RodentFlow.Core`：无外部依赖，通过 `IPoseModel` / `IVideoReader` 两个接口和外界打交道；
  `Setup/` 里是参数表单（数据）和读写参数值的规则；`Figures/` 是结果图的画法和 SVG / PDF / PNG 写出，
  `Text/` 是经引擎翻译的界面文字
- `RodentFlow.Onnx`：唯一需要 `Microsoft.ML.OnnxRuntime` 的项目，约 190 行
- `RodentFlow.App`：WinUI 3，加 Win2D（屏幕上的图和 PNG 导出）

`IPoseModel` 这个接口不只是为了测试：换推理后端（Windows ML、OpenVINO、TensorRT）时，
只有这一个文件要改。

## 五、帧预处理：和训练一致，而不是和 Core Image 一致

C# 要重现 Mac 上 Core Image + Vision 做的事。有两处我**故意**不照搬 Apple 的行为，
而是照搬模型训练时的做法（两处都列在 `docs/STATUS_CN.md` 里等着量）：

| | Mac（Core Image / Vision） | 这里 | 为什么 |
|---|---|---|---|
| letterbox 填充 | Vision `.scaleFit`，填黑 | 填 114 | Ultralytics 用 114，模型就是这么训出来的 |
| 灰度 | `CIColorControls` 饱和度 0，在线性空间 | sRGB 空间 Rec.601 亮度 | 训练管线就是这么转的；也和引擎 `AppearanceSampler` 的权重一致 |

letterbox 的**几何**没有自由度，必须和引擎逐位一致，因为 `PoseDecoding.decode` 要把它反过来：

```
gain = min(mh/ih, mw/iw)
padX = round((mw - round(iw·gain)) / 2 - 0.1)
```

两个坑：Swift 的 `rounded()` 是四舍五入远离零，C# `Math.Round` 默认是四舍六入五取偶，
所以到处都要写 `MidpointRounding.AwayFromZero`；那个 `- 0.1` 是引擎里就有的偏置，不能省。

`tools/RodentFlow.SelfCheck` 用 10 组尺寸核对 letterbox 计划，再把一个已知位置的亮点过一遍
预处理、用引擎的反变换还原，4 种裁剪下最大误差 0.38 px。

## 六、读视频

`FFprobe` 先取尺寸、旋转，再列出**每一帧的时间戳**；`FFmpegVideoReader` 把 ffmpeg 的
`rawvideo bgra` 管道按顺序和这个时间戳列表配对。

不 seek：续跑时会从文件头重新解码。引擎的 `rf_run_filter` 会把已经有的帧跳掉，所以结果是对的，
只是慢。加 seek 要么用 `-ss -copyts` 并重新确定第一帧对应哪个时间戳，要么改成从 ffmpeg 自己
读时间戳——两条路都要在真机上验证，所以第一版选了简单且确定正确的那条。
