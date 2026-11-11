# Third-party components

This repository contains source code only. The components below are used by it but are not
included; they are downloaded by the build tools (NuGet, Swift) or installed separately. When the
program is distributed in binary form, the notices of the components shipped with it must go with it.

| Component | Used for | Licence | How it arrives |
|---|---|---|---|
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) with DirectML (`Microsoft.ML.OnnxRuntime.DirectML`) | Running the pose models on the GPU or the processor | MIT. It brings in DirectML (`Microsoft.AI.DirectML`), a Microsoft redistributable under the terms included in that package | NuGet |
| [Windows App SDK](https://github.com/microsoft/WindowsAppSDK) (`Microsoft.WindowsAppSDK`) | WinUI 3 window | MIT for the SDK package; some component packages it brings in are under the Microsoft Software License Terms included in each package | NuGet |
| [Win2D](https://github.com/microsoft/Win2D) (`Microsoft.Graphics.Win2D`) | Drawing figures, poses and review overlays | Win2D's source is MIT; the package carries the licence terms shown on it | NuGet |
| Windows SDK Build Tools (`Microsoft.Windows.SDK.BuildTools`) | Building only; not redistributed | Microsoft licence terms in the package | NuGet |
| [.NET](https://github.com/dotnet/runtime) | C# runtime (bundled in a self-contained build) | MIT | .NET SDK |
| [Swift](https://www.swift.org) runtime and Foundation | Running the engine DLL (`swiftCore.dll`, `Foundation.dll`, …) | Apache License 2.0 with Runtime Library Exception | Swift toolchain |
| [FFmpeg](https://ffmpeg.org) (`ffmpeg.exe`, `ffprobe.exe`) | Reading video | LGPL 2.1 or later, or GPL, depending on the build | Installed by the user; run as a separate program |

PDF and SVG exports name the standard Helvetica / Arial fonts without embedding any font file.

The model export notebook (`notebooks/`) installs [Ultralytics](https://github.com/ultralytics/ultralytics)
(AGPL-3.0), PyTorch (BSD-3-Clause), ONNX (Apache-2.0) and ONNX Runtime (MIT) when it runs.

## The engine

`engine/Sources/RodentFlowABI/Shared/` is the analysis engine of the RodentFlow apps, by the same
author, included here under this repository's licence. `engine/Resources/` holds its interface
text translations.

## Model files

The `.onnx` model files are not part of this repository and are not covered by its licence. They
were trained with Ultralytics YOLO on public datasets, some of which carry non-commercial terms
(for example CC BY-NC-SA 4.0). The terms of each model file, and the datasets it was trained on,
are stated where the model files are published.
