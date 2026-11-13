# RodentFlow for Windows — 框架

Windows 版 RodentFlow 的骨架。**所有科学计算仍是同一份 Swift 代码**（iPhone / iPad / Mac 跑的那份），
编译成 Windows 的 DLL；C# 只负责界面、读视频和跑模型。

```
          ┌─────────────────────── C# (这个仓库) ───────────────────────┐
视频文件 → │ ffmpeg 解码（逐帧时间戳）→ 裁剪/灰度/letterbox → ONNX Runtime │
          └────────────────────────────┬───────────────────────────────┘
                                       │  [1,300,24] 裸张量
          ┌────────────────────────────▼───────────── Swift 引擎 ───────┐
          │ PoseDecoding → ArenaROI.uncrop → 身份追踪 → 毛色描述子       │
          │ → pose.mpt → Kinematics → 各任务分析器 → 导出 / Methods      │
          └─────────────────────────────────────────────────────────────┘
```

这样做的理由：引擎里 23,617 行判定和统计一行都不用重写，三端结果出自同一份代码。

## 目录

| 位置 | 内容 | 这边编译过？ |
|---|---|---|
| `engine/` | Swift：63 个引擎源文件（从 App 的 `Shared/` 同步）+ C ABI | **否**，见下 |
| `src/RodentFlow.Engine/` | C#：P/Invoke 绑定和 JSON 契约 | 是，0 警告 |
| `src/RodentFlow.Core/` | C#：读帧、帧预处理、识别循环 | 是，0 警告 |
| `src/RodentFlow.Onnx/` | C#：ONNX Runtime 封装（约 190 行） | 否（缺 NuGet） |
| `src/RodentFlow.Cli/` | C#：命令行版（第一步可交付物） | 类型检查过 |
| `src/RodentFlow.App/` | C#：WinUI 3 窗口（含拖四角标定） | 否（需要 Windows） |
| `tools/RodentFlow.SelfCheck/` | 纯算术部分的自检 | 是，**全部通过** |
| `check/` | 静态核对 ABI 与引擎符号的脚本 | 是，**0 问题** |

**引擎、命令行版和整条链路已经在 Windows 11 + Swift 6.4.2 + ffmpeg 9.0.2 上跑通**
（23,617 行 Swift 编译 60 秒；识别 23 ms/帧；`pose.mpt` 和全套导出正常产出）。
WinUI 窗口还没在 Windows 上编译过。逐条的验证状况和当天修掉的三个 bug 写在 `docs/STATUS_CN.md`。

## 你需要准备的

1. **一台 Windows 机器**（Windows 10 1809 以上；WinUI 的下限）。
2. **Swift for Windows**：`winget install --id Swift.Toolchain -e`。
   **还必须装 Visual Studio 的「使用 C++ 的桌面开发」工作负载**（含 Windows SDK），
   并且 `swift build` 要在 **x64 Native Tools Command Prompt** 里跑——否则 `INCLUDE`
   不指向 SDK，会报 `stdlib.h file not found`。这只是编译时的要求。
3. **.NET 8 SDK**。
4. **ffmpeg.exe 和 ffprobe.exe**，5.0 以上（用 `-fps_mode passthrough`）。
   放在程序旁边，或用 `--ffmpeg DIR` 指定。
   用 ffmpeg 而不用 Media Foundation 只有一个原因：它给出文件里每一帧自己的时间戳。
   引擎所有时长、速度和阈值都建立在这些时间戳上，用「帧号 ÷ 帧率」近似是不行的。
5. **模型**：`.onnx` 文件放进 `models/`。从本仓库的 Releases 下载，或者用
   `notebooks/RodentFlow_Export_ONNX_All_Models.ipynb` 从自己的 checkpoint 导出。

## 第一次构建

```powershell
# 1. 引擎（Swift → RodentFlowABI.dll）
powershell -ExecutionPolicy Bypass -File build\build_engine.ps1

# 2. 其余部分 + 自检
powershell -ExecutionPolicy Bypass -File build\build_all.ps1
```

`NuGet.config` 现在清空了包源（这边没有网络），`build_all.ps1` 会自动把它改名，让 NuGet 可用。

## 先跑命令行版

界面之前先把这条链路跑通，因为它把引擎、模型和读帧三件事都试了一遍，中间没有别的东西干扰：

```powershell
cd src\RodentFlow.Cli
dotnet run -- models --models ..\..\models        # 哪些模型在位
dotnet run -- info   D:\videos\cage3.mp4          # 尺寸、帧率、逐帧时间戳
dotnet run -- plan   D:\videos\cage3.mp4          # 用哪个模型、裁哪块、解码多大
dotnet run -- run    D:\videos\cage3.mp4 D:\runs\cage3 --task open_field --cm 40 40
```

`run` 会写出和 Mac 完全相同的东西：`pose.mpt`、`segment_*.csv`、`pose_stream.json`，
以及 `results/` 里的 `report.json`、`rodentpose_frame_metrics.csv`、`metrics.csv`、
`summary.txt`、`segments.csv`。

中途 Ctrl+C 可以停，已经识别的帧会保留；用同一条命令可以接着跑（和 Mac 一样）。

## 引擎源文件怎么更新

`engine/Sources/RodentFlowABI/Shared/` 是从 App 的 `Shared/` 复制来的，过滤规则和 App 自己的
`tools/shared_sources.sh` 相同。App 那边改了引擎之后：

```powershell
powershell -File engine\sync_shared.ps1 -AppRoot "C:\…\RodentFlow-2.1 shell"
python check\check_abi.py engine\Sources\RodentFlowABI engine\Sources\RodentFlowABI\ABI\*.swift
```

第二条命令会把 ABI 层引用的每个类型、成员和参数标签和引擎源码核对一遍，这是没有 Swift 编译器时
最有用的一道检查（它能发现改名和改标签；实例成员的类型推断它做不了）。

Mac 的参数面板（`PoseCalibrationEditor.swift`）改了之后，Windows 的参数表单要跟着改：

```powershell
python check\check_forms.py "C:\…\RodentStudio\Views\PoseCalibrationEditor.swift" `
    engine\Sources\RodentFlowABI\Shared\PoseEngine\SessionModels.swift `
    engine\Sources\RodentFlowABI\Shared\PoseEngine\Paradigms.swift `
    src\RodentFlow.Core\Setup\AssayForms.cs
```

它逐个范式比对两边绑定的参数键，多一个、少一个、拼错一个都会报出来。标题、范围和显示条件是手抄的，它不查。

`check/winui_stub/` 是在没有 Windows App SDK 的机器上编译窗口代码用的替身（**不是**真的 WinUI），
只在 Linux 上写代码时用；Windows 上直接 `dotnet build` 就是真编译。

当前同步的版本记在 `engine/Sources/RodentFlowABI/Shared/SYNC_STAMP.txt`。

## 看一眼追踪对不对

这是 RodentFlow 自己 Box 1 第 9 条要求的检查，置信度看不出来：

```powershell
dotnet run -- annotate D:\runs\cage3 D:\runs\cage3\annotated.mp4 --video D:\videos\cage3.mp4
```

骨架是从 `pose.mpt` 读出来的，不是重新推理——你看到的就是分析实际用的那份数据。
实心点 = 分析采用的关键点；空心圈 = 置信度 < 0.5，分析当作缺失；灰框 = 送进模型的区域；
红边框 = 这一帧什么都没找到。

## 下一步

`docs/STATUS_CN.md` 里有完整清单。最要紧的四件：

1. WinUI 窗口第一次在 Windows 上编译。
2. 同一段视频在 Mac 和 Windows 各跑一次，比 `pose.mpt` 的逐帧关键点，定容差。
3. 区域叠加显示（中央区、臂、象限）——需要给 ABI 加一个返回区域多边形的入口。
4. 多格悬尾（`MouseDetector` 没有 `.onnx`）和视频遮挡都没有包含。

## 显卡加速和语言

- 左栏「识别」里的「使用显卡（GPU）加速」默认开着：用 DirectML，NVIDIA / AMD / Intel 的 DirectX 12 显卡都行；用不了时自动用处理器，
  状态栏会写明用的是哪个。
- 左侧栏底部切换 English / 中文，整个界面即时切换（导出的图表仍是英文，与 Mac 相同）。

## 工作区（阶段 W）

和 Mac 一样按 **任务 → 组 → 动物 → 实验** 管理：

1. 左侧栏底部 **New task…**：选实验范式、起名字。
2. **Add videos…**：可以一次选多个视频。每段视频是一只小鼠的一次实验；小鼠编号、日期、实验次数必填
   （编号和日期会先从文件名猜，实验次数自动排）。
3. 点一个实验：**Session info**（信息）→ **Calibrate**（放场地）→ **Analyse** → **Results**。
   相机没动的话，放好一个实验后点 **Use this setup for all sessions of the task…**。
4. **Analyse all ready**：把所有可以分析的实验依次分析完。暂停的会接着跑。
5. 左侧「列表」：待分析、待复核、缺信息、已排除、全部。

阶段 R 之后用旧窗口分析的文件夹，可以用 **Import an analysed folder…** 并入工作区。

## 组间比较（阶段 D）

选中一个任务，页面下方是 **Group comparison**：选设计（组间比较、按实验次数、按天、时间进程、配对指标、阶段变化）、
指标、阶段、检验方式和要比较的组，下面就是出版用的图、结果段落、检验详情和各组描述统计。「Save…」导出 PDF / SVG /
300·600 dpi PNG 的图，以及统计表和每只小鼠一行的数据表（CSV，给 Prism / R）。图和表格一律英文。

## 配对阶段、埋珠、进食确认（阶段 B）

- **配对**：同一只小鼠的两个阶段放在同一任务里（比如位置偏好的 Pre-test 和 Post-test），各自分析；另一阶段的数值会自动带进来，
  报告里出现配对指标。
- **埋珠**：放好珠子网格后分析，程序会读一遍视频里每颗珠子的亮度（只读一次，之后用缓存）。
- **新奇抑制摄食**：在 Review 里找到首次进食那一帧，点「Set as first bite」（或「No feeding before the cut-off」）。

## 逐帧复核（阶段 V）

实验页第四步 **Review**：视频上画着分析用的骨架（两只鼠：A 蓝、B 红），可选 2 秒轨迹和区域；下面是时间轴
（要检查的时刻按种类分行，再是行为），可点可拖。空格播放 / 暂停，← → 逐帧；⏮ ⏭ 跳到上一个 / 下一个时刻
（可只看某一类）。两只鼠时可「从此帧起交换 A / B」或在一段范围内交换，结果自动重算。看完点
「The tracking is right」或「has problems」。

## 结果页（阶段 R）

分析结束后自动切到 **Results**：顺序和 Mac 一样——提示、主要指标（带刻度）、识别质量、全部指标、各张图、
识别质量详情、Methods。每张图右上角「⋯」（或右键）：图层与原图对照、复制图像、保存 PNG、矢量 PDF、SVG、
300 / 600 dpi PNG、复制 CSV。文件一律英文，和 Mac 一样。

- 改了标定、区域或参数：**Update results**（或直接切到 Results）用已保存的识别结果重算，不用重新识别。
- 实验的结果随时可看：打开一个已分析的实验，结果会从它保存的识别结果重算。视频不在原处也能看结果和图。
- 结果页右上角切换 English / 中文（报告、图和参数面板都换；任务列表等少数地方要重启才换）。

检查工具（没有编译器时）：

```powershell
python check\check_abi.py engine\Sources\RodentFlowABI engine\Sources\RodentFlowABI\ABI\*.swift
python check\check_report_contract.py          # 报告 JSON：Swift 写的键 ↔ C# 读的属性
python check\check_report_contract.py --selftest
python check\check_xaml.py src\RodentFlow.App\MainWindow.xaml
python check\check_cs_members.py                # 项目内 C# 引用：类型.成员、字段.成员
```

## 其他文档

- `docs/MAC_PARITY_CN.md` — 和 Mac 差在哪、SwiftUI → WinUI 对照表、阶段顺序

- `docs/ARCHITECTURE_CN.md` — 为什么这样分界，ABI 长什么样
- `docs/STATUS_CN.md` — 逐项的完成度、验证状况和已知差异
- `engine/include/rodentflow.h` — C 接口的参考副本

## 隐私与支持

RodentFlow 完全在你的电脑上运行：没有联网代码、没有账号、没有统计分析，不收集任何数据，见[隐私政策](PRIVACY.md)。问题和建议请提交 [issue](https://github.com/seesaw-earth/RodentFlow-Windows/issues)，见 [SUPPORT.md](SUPPORT.md)。
