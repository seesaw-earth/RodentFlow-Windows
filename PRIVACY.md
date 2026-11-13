# Privacy policy: RodentFlow for Windows

*Last updated: 13 November 2026 · applies to RodentFlow for Windows, including the version in the
Microsoft Store · [简体中文版见下方](#隐私政策rodentflow-windows-版)*

**In short: RodentFlow for Windows does not collect, transmit or share any personal information or
any other data. Videos, results and everything you enter stay on your PC.**

The privacy policy of RodentFlow for iPhone, iPad and Mac is at
[seesaw-earth.github.io/RodentFlow/privacy.html](https://seesaw-earth.github.io/RodentFlow/privacy.html).

## Personal information

RodentFlow does not ask for, collect or transmit personal information about you: no name, e-mail
address, account, contacts, location, device identifier or usage data. The developer receives
nothing from the app.

## What the app processes, on your PC only

- videos you choose for analysis, which are read where they are and never modified;
- the experiment details you enter, such as project and task names, conditions, animal IDs, groups,
  sex, phases and notes;
- calibration points, review annotations (for example identity swaps between two mice) and other
  session settings;
- the results computed from them: positions and pose keypoints, tracking files, figures, statistics
  and exports.

This information is used only to compute and show your results.

## What the app does not do

- It contains **no code that connects to the internet**. It does not upload, sync or send your videos,
  entries or results to the developer or to anyone else.
- It has **no account**, no sign-in and no registration.
- It contains **no advertising, analytics, telemetry, crash-reporting or tracking** code or SDKs.
  If the app fails to start, the error is written only to a local file (`startup-error.log`, below)
  and is never sent anywhere.
- It does **not** access your camera, microphone, location, contacts or other personal data.

Pose tracking runs with ONNX models on your PC's graphics card (DirectML) or processor, so analysing a
video needs no internet connection. Video frames are read by ffmpeg and ffprobe, which run as local
programs on your PC.

## Where your data are stored

| What | Where |
|---|---|
| Settings, the workspace (projects, sessions and the details you entered), figure styles, which processor runs each model fastest, cached video properties (length, frame rate, size), `startup-error.log` | `%LOCALAPPDATA%\RodentFlow\` in your Windows user profile. For the Microsoft Store version, Windows may keep this folder inside the app's own package data under `%LOCALAPPDATA%\Packages\` instead. |
| Analysis results (tracking files and reports) | `Documents\RodentFlow`, or the folder you choose |
| Exported figures, tables and review videos | The folders you choose |

These are ordinary files protected by your Windows user account; the app adds no encryption of its
own. You can open, copy or delete them at any time.

Data leave your PC only when **you** copy, share or export them. If you save into a folder that a
cloud service synchronises, such as OneDrive, that service stores the files under its own terms.
Windows backups follow your own settings.

## Seeing and deleting your data

- Everything the app keeps is in the folders above, as files you can open; the workspace is a
  readable JSON file.
- In the app you can remove tasks and sessions. This does not delete your original videos, and
  result folders stay on disk until you delete them in File Explorer.
- To remove everything, uninstall the app and delete whichever of these folders remain:
  `%LOCALAPPDATA%\RodentFlow`, `Documents\RodentFlow` (or your chosen results folder) and your export
  folders.

The developer has no access to your data and cannot see, change or delete anything on your PC.

## Microsoft Store and Windows

The Microsoft Store and Windows are operated by Microsoft, not by the developer. Downloading and
updating the app through the Store, and the diagnostic data Windows itself sends, are governed by
the [Microsoft Privacy Statement](https://privacy.microsoft.com/privacystatement) and your Windows
privacy settings. Through Partner Center, Microsoft may give the developer aggregate reports, such as
the number of installations and crash statistics. The developer uses them only to find and fix
problems and does not combine them with any other data.

## You can check this

RodentFlow for Windows is open source under the GNU Affero General Public License v3.0:
[github.com/seesaw-earth/RodentFlow-Windows](https://github.com/seesaw-earth/RodentFlow-Windows).
Anyone can read how the app handles data and confirm that it makes no network connections.

## Children

RodentFlow is a tool for research laboratories and is not directed at children. It does not collect
data from anyone, including children.

## Changes

If this policy changes, the new version will be posted at this address with a new date; earlier
versions remain in the repository's history. A change that introduced any data collection would be
stated clearly here and in the release notes before it took effect.

## Contact

Questions about this policy or the app: open an issue at
[github.com/seesaw-earth/RodentFlow-Windows/issues](https://github.com/seesaw-earth/RodentFlow-Windows/issues).
GitHub issues are public: for a sensitive question, open an issue asking only for a private contact
channel, without the details.

Developer: Ziqing Shi

---

# 隐私政策：RodentFlow Windows 版

*最近更新：2026 年 11 月 13 日 · 适用于 RodentFlow Windows 版，包括 Microsoft Store 中的版本*

**简而言之：RodentFlow Windows 版不收集、不传输、不共享任何个人信息或其他数据。视频、结果和你填写的一切都留在你的电脑上。**

iPhone、iPad 和 Mac 版的隐私政策见
[seesaw-earth.github.io/RodentFlow/zh/privacy.html](https://seesaw-earth.github.io/RodentFlow/zh/privacy.html)。

## 个人信息

RodentFlow 不要求、不收集、不传输任何关于你的个人信息：没有姓名、电子邮件地址、账号、通讯录、位置、设备标识符或使用数据。开发者不会从 App 收到任何内容。

## App 处理哪些数据（仅在你的电脑上）

- 你选择用于分析的视频，在原位置读取，从不修改；
- 你填写的实验信息，如项目和任务名称、实验条件、动物编号、组别、性别、阶段和备注；
- 标定点、复核注释（例如两只小鼠的身份交换）和其他测试设置；
- 由此计算出的结果：位置和姿态关键点、追踪文件、图表、统计和导出文件。

这些信息只用于计算和显示你的结果。

## App 不做什么

- **不含任何联网代码**，不会向开发者或任何其他人上传、同步或发送你的视频、录入内容或结果。
- **没有账号**，不需要登录或注册。
- **不含任何广告、统计分析、遥测、崩溃上报或追踪**代码或 SDK。App 启动失败时，错误只写入本地文件（`startup-error.log`，见下表），不会发送到任何地方。
- **不访问**相机、麦克风、位置、通讯录或其他个人数据。

姿态追踪使用 ONNX 模型，在你电脑的显卡（DirectML）或处理器上运行，分析视频不需要联网。视频画面由 ffmpeg 和 ffprobe 读取，它们是在你电脑上本地运行的程序。

## 数据存放在哪里

| 内容 | 位置 |
|---|---|
| 设置、工作区（项目、测试和你填写的信息）、图表样式、每个模型在哪个处理器上最快、视频属性缓存（时长、帧率、尺寸）、`startup-error.log` | Windows 用户目录下的 `%LOCALAPPDATA%\RodentFlow\`。Microsoft Store 版中，Windows 可能把这个文件夹放在 `%LOCALAPPDATA%\Packages\` 下 App 自己的数据里。 |
| 分析结果（追踪文件和报告） | `文档\RodentFlow`，或你选择的文件夹 |
| 导出的图表、表格和复核视频 | 你选择的文件夹 |

这些都是普通文件，受你的 Windows 用户账户权限保护，App 不另外加密。你可以随时打开、复制或删除。

只有当**你**自己复制、共享或导出时，数据才会离开电脑。如果你保存到 OneDrive 等云服务同步的文件夹，文件由该服务按其自身条款保存。Windows 备份由你自己的设置决定。

## 查看和删除数据

- App 保存的一切都在上述文件夹中，都是可以直接打开的文件；工作区是可读的 JSON 文件。
- 在 App 中可以移除任务和测试。这不会删除你的原始视频，结果文件夹也会留在磁盘上，需要在文件资源管理器中删除。
- 要删除全部数据：卸载 App，再删除仍然存在的以下文件夹：`%LOCALAPPDATA%\RodentFlow`、`文档\RodentFlow`（或你选择的结果文件夹）以及你的导出文件夹。

开发者无法访问你的数据，也无法查看、修改或删除你电脑上的任何内容。

## Microsoft Store 与 Windows

Microsoft Store 和 Windows 由 Microsoft 运营，而不是开发者。通过 Store 下载和更新 App，以及 Windows 自身发送的诊断数据，适用 [Microsoft 隐私声明](https://privacy.microsoft.com/zh-cn/privacystatement)和你的 Windows 隐私设置。Microsoft 可能通过 Partner Center 向开发者提供汇总报告，例如安装次数和崩溃统计。开发者只用它们发现和修复问题，不会与任何其他数据合并。

## 你可以自行核实

RodentFlow Windows 版以 GNU Affero 通用公共许可证 v3.0 开源：
[github.com/seesaw-earth/RodentFlow-Windows](https://github.com/seesaw-earth/RodentFlow-Windows)。任何人都可以查看 App 如何处理数据，并确认它不进行任何网络连接。

## 儿童

RodentFlow 是面向科研实验室的工具，不面向儿童，也不收集任何人（包括儿童）的数据。

## 变更

如果本政策有变更，新版本会以新的日期发布在本地址；旧版本保留在仓库历史中。任何引入数据收集的变更，都会在生效前在此处和版本说明中明确说明。

## 联系方式

对本政策或 App 有疑问，请在
[github.com/seesaw-earth/RodentFlow-Windows/issues](https://github.com/seesaw-earth/RodentFlow-Windows/issues)
提交 issue。GitHub issue 是公开的：涉及敏感问题时，请只提交一个请求私下联系的 issue，不要写具体内容。

开发者：Ziqing Shi
