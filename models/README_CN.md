# 模型放这里

把 `.onnx` 文件复制到这个文件夹：从本仓库的 Releases 下载，或者用
`notebooks/RodentFlow_Export_ONNX_All_Models.ipynb` 从自己的 checkpoint 导出。

RodentFlow 2.1 用到的模型（Releases 里的 `.onnx` 就是这几个）：

| 文件 | 对应引擎里的模型 | 用于 |
|---|---|---|
| `MousePose6_960_fp32.onnx` | `MousePose6_960_int8` | 一只深色鼠（默认） |
| `WhiteMousePose6_960_fp32.onnx` | `WhiteMousePose6_960_int8` | 一只白鼠 |
| `MousePose6Dyad_960_fp32.onnx` | `MousePose6Dyad_960_int8` | 两只深色鼠 |
| `MousePose6DyadBW_960_fp32.onnx` | `MousePose6DyadBW_960_int8` | 一黑一白 |
| `GroupPose6_960_fp32.onnx` | `GroupPose6_960_int8` | 3–10 只 |

`CylinderPose7_640_fp32.onnx` 不用放（RodentLimb 已从 2.0 移除）。

文件名只要以引擎模型名的第一段开头就行（`MousePose6…`、`GroupPose6…`），
程序按这个前缀找文件，再用 ONNX 元数据里的 `rodentflow.model` 核对是不是对的模型。

检查哪些在位：

```powershell
cd src\RodentFlow.Cli
dotnet run -- models --models ..\..\models
```
