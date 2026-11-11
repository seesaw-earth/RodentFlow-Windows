# RodentFlow for Windows

Pose tracking and behaviour analysis of mice from video, on Windows: the Windows version of
[RodentFlow](https://seesaw-earth.github.io/RodentFlow/) (Mac, iPhone and iPad).

> **Status: early development.** Built and run on Windows 11 during development. Results have not
> yet been compared with the Mac and iOS apps, and the assay measures have not been validated
> against human scoring on Windows. What has and has not been checked, part by part, is in
> [`docs/STATUS_CN.md`](docs/STATUS_CN.md) (in Chinese).

## What it does

- **Workspace** as on the Mac: task → group → animal → session. Add many videos at once, set each
  session's information, and analyse every ready session in a queue.
- **Calibration** for all 27 RodentFlow tasks: the arena (rectangle, circle, plus, Y or T maze) and
  each task's markers (cups, objects, platform, target hole, shelter, food, marble grid …) are dragged
  on a video frame, with the task's zones drawn as the analysis counts them, and the task's parameters
  in a panel.
- **Results** page with the same cards, figures and Methods text as the Mac app; every figure exports
  to PNG (300 / 600 dpi), PDF, SVG or CSV.
- **Frame-by-frame review**: the skeleton on the video, a timeline of moments to check, swapping the
  identities of two mice from a frame or over a range, and confirming the first bite in
  novelty-suppressed feeding.
- **Paired phases** (social interaction ratio, conditioned place preference score, step-down ratio)
  and **marble burying** (each marble read from the video).
- **Group comparison** with the apps' statistics, publication figures and per-animal CSV tables.
- GPU inference through DirectML (any DirectX 12 GPU), with the processor as fallback; the faster of
  the two is measured per model. English and Chinese interface.

## How it works

The analysis engine of the RodentFlow apps is about 23,600 lines of Swift: keypoint decoding,
identity tracking, arena zones, the rules of each assay, the statistics and the figures. It is
compiled **unchanged** into a Windows DLL, so the Windows version measures behaviour with the same
code as the Mac and iOS apps. C# replaces only what Apple frameworks do there:

| On Mac and iOS | On Windows | Why |
|---|---|---|
| AVFoundation | ffmpeg / ffprobe | Each frame's own timestamp; every duration, speed and threshold is built on it |
| Core ML | ONNX Runtime (DirectML or CPU) | FP32 ONNX exported from the same checkpoints |
| SwiftUI | WinUI 3 and Win2D | Native Windows interface |

```
C#     ffmpeg decoding (per-frame timestamps) → crop / grayscale / letterbox → ONNX Runtime → WinUI
             ↓ raw model output per frame, JSON for settings and results
Swift  keypoint decoding → identity tracking → pose.mpt → kinematics → assay analysis → report
       + each task's setup, zones and handles; marble positions; identity swaps; group statistics
```

Whatever the engine decides is answered by the engine through a C interface of 22 functions
(`engine/include/rodentflow.h`); the C# side has no task-specific rules. The design is described in
[`docs/ARCHITECTURE_CN.md`](docs/ARCHITECTURE_CN.md); how the window follows the Mac app, in
[`docs/MAC_PARITY_CN.md`](docs/MAC_PARITY_CN.md).

## Building

Requirements (for building only; a lab machine running the app does not need them):

- Windows 10 1809 or later, x64
- [Swift 6.4 for Windows](https://www.swift.org/install/windows/), with Visual Studio 2022
  **"Desktop development with C++"** (for the Windows SDK headers) and Windows **Developer Mode** on
- .NET 8 SDK
- ffmpeg and ffprobe 5.0 or later
- The repository at a short path, e.g. `C:\rf\RodentFlow-Windows`

```bat
:: x64 Native Tools Command Prompt for VS 2022: the engine
cd /d C:\rf\RodentFlow-Windows\engine
swift build -c release --scratch-path .build
```

```powershell
# PowerShell: the window and the self-check
cd C:\rf\RodentFlow-Windows\src\RodentFlow.App
dotnet build -c Release
cd ..\..\tools\RodentFlow.SelfCheck; dotnet run -c Release
```

The window is `src\RodentFlow.App\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\RodentFlow.exe`
(`bin\Release\…` when built outside the Visual Studio prompt). Put the `.onnx` models in `models\`
before building (they are copied next to the program) and ffmpeg next to the program or on the `PATH`.

## Models

The `.onnx` files are not part of the source; they are distributed separately as release assets,
together with their terms. [`notebooks/RodentFlow_Export_ONNX_All_Models.ipynb`](notebooks/)
exports them (FP32, opset 17) from YOLO pose checkpoints and checks ONNX Runtime against PyTorch.
[`models/README_CN.md`](models/README_CN.md) lists the file names the program looks for.

## Command line

```powershell
$cli = "src\RodentFlow.Cli\bin\x64\Release\net8.0\rodentflow.exe"
& $cli run video.mp4 runs\test --task open_field --models models
& $cli run maze.mp4 runs\epm --task elevated_plus_maze --param openAxis=EW
& $cli annotate runs\test runs\test\annotated.mp4 --video video.mp4   # keypoints drawn on the video
& $cli --help
```

## Repository

| Folder | Contents |
|---|---|
| `engine/` | Swift: the RodentFlow engine (`Shared/`, synced from the apps), Windows shims, the C interface |
| `src/RodentFlow.Engine` | P/Invoke and the JSON contracts (no dependencies) |
| `src/RodentFlow.Core` | Video, frame preparation, tracking loop, workspace, review, marble sampling, figures and their PNG / PDF / SVG export, task forms (no dependencies) |
| `src/RodentFlow.Onnx` | ONNX Runtime wrapper (DirectML or CPU) |
| `src/RodentFlow.Cli`, `src/RodentFlow.App` | Command-line tool and WinUI 3 window |
| `tools/RodentFlow.SelfCheck` | Checks that need no engine, run with `dotnet run` |
| `check/` | Static checks for working without a Swift or Windows toolchain |
| `notebooks/` | Model export |
| `docs/` | Design, status and Mac parity notes (Chinese) |

The static checks: `check_abi.py` (every engine call in the C interface against the engine source),
`check_report_contract.py` (report JSON written by Swift against the C# properties that read it),
`check_xaml.py` (control names and handlers between XAML and code), `check_cs_members.py`
(project-internal C# references) and `check_forms.py` (task parameter forms against the Mac app's
`PoseCalibrationEditor.swift`; needs the RodentFlow app source). `check/winui_stub/` compiled the early
window against stand-in types and is out of date; a real Windows build is the reference.

## Licence

Copyright © 2026 Ziqing Shi. Licensed under the GNU Affero General Public License v3.0 only
([`LICENSE`](LICENSE)). Third-party components and the terms of the model files are listed in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

If you use RodentFlow in research, please cite it (see [`CITATION.cff`](CITATION.cff)).
