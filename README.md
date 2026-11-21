<div align="center">

# Claude Desktop Fake

**Windows x64 进程内时间、区域语言与网络行为实验**

C++17 · PowerShell · Go · MIT

[快速开始](#快速开始) · [配置](#配置) · [查看状态](#查看状态) · [项目结构](#项目结构) · [文档](docs/README.md)

</div>

---

## 这是什么

Claude Desktop Fake 用于在 Windows 上研究单个进程读取时间、时区、区域格式、UI 语言和网络设置时的行为。仓库提供 Application Verifier Provider、隔离测试程序、离线兼容分析工具和本机网页控制台。时间和区域设置只在支持的进程接口中生效，Windows 的全局时钟和区域设置保留原值。

| 功能 | 可查看或验证的行为 |
| --- | --- |
| 时间与时区 | 虚拟 UTC、Windows 年度时区规则、夏令时和进程内当前时间 |
| 区域格式、UI 语言与地理区域 | 分别配置日期和数字格式、首选语言及默认国家或地区 |
| Electron、V8、ICU 与 WinRT | 通过离线分析确认运行时兼容性并检查各功能的就绪状态 |
| 网络代理预览 | 查看受测代理连接、目标域名和端口、DNS 记录及 WebRTC 策略状态 |
| 更新与启动诊断 | 查看签名和文件身份判定、已登记映像、最近的后台刷新及启动观测耗时 |

## 快速开始

从仓库根目录运行命令。需要 Windows x64、Visual Studio 的 x64 MSVC 和 MASM、Windows SDK `10.0.26100.0`、CMake 3.24+、Ninja、Python 3.10+ 及 64 位 PowerShell。带运行时扩展的历史行为验收使用 Windows 10 build 19045。网页控制台要求 PowerShell 7.5 或更新版本。

构建原生组件后，可以预览一个固定时刻。

```powershell
.\scripts\Build.ps1
.\scripts\Show-TimeConfig.ps1 -ReferenceUtc '2026-01-15T20:00:00Z'
```

默认模板会得到洛杉矶当地时间 12:00。输出中的 `utcClockShiftSeconds` 为 `0`，`timeZoneOffsetSeconds` 为 `-28800`。预览只读取配置和本机规则。完整构建、已有缓存和网络组件的构建方式见[构建指南](docs/build.md)。

构建 Go 传输和控制台后，可以从工作树打开只读页面。默认监听本机环回端口 `17862`，占用时自动选择可用端口。[控制台使用说明](docs/GUI.md)

```powershell
.\scripts\Build-Network.ps1
.\scripts\Start-Gui.ps1 -ReadOnly
```

首次登记、可写控制台以及升级和撤销的步骤见[使用与启停](docs/usage.md)。

## 配置

| 文件 | 用途 |
| --- | --- |
| [`config/timezone.json`](config/timezone.json) | schema 3 配置模板，包含时间、区域语言、地理区域和运行时四组 |
| [`config/timezone-v3.schema.json`](config/timezone-v3.schema.json) | 编辑器校验参考，运行时以 Windows 时区、NLS 和项目校验器为准 |
| [`config/claude-targets.json`](config/claude-targets.json) | Store 包及附加目录的发现范围 |
| [`config/claude-network-children.json`](config/claude-network-children.json) | 控制台观察的外部子程序名称，默认包含 `ssh.exe` 和 `node.exe` |

**洛杉矶当地时间使用 `timeZoneId: "Pacific Standard Time"` 和 `utcOffsetSeconds: 0`。** 后者只调整 UTC 时钟。时区规则根据日期单独计算 UTC−7 或 UTC−8。每个新进程读取一次部署配置，已运行进程继续使用自己的启动快照。`captureEnabled` 控制运行时诊断样本，默认关闭。完整字段说明、旧版配置和预览示例见[时间与区域配置](docs/time-configuration.md)。

## 查看状态

```powershell
.\scripts\Manage-Claude.ps1 -Action Status
.\scripts\Manage-ClaudeAuto.ps1 -Action Status
```

从 `running[]` 检查具体 PID 的文件身份、Provider 和功能状态。配置已保存、映像已登记、DLL 已加载和功能已就绪对应不同证据。启动观测的 `creationToVerdictMs` 从 Windows 记录的进程创建时刻计到身份判定完成。完全新的 EXE 名称仍存在启动后的发现窗口。[状态字段与诊断](docs/automatic-refresh.md)

运行时兼容性取决于映像、ABI、规则和 Windows 构建。网络结果限于受测进程、采样窗口和接口范围，真实应用、共享子程序和系统服务需要各自的运行证据。[跨版本适配](docs/Stage6-Compatibility.md) · [验收范围](docs/validation.md)

## 项目结构

```text
config/           环境配置、目标范围和子进程观察清单
profiles/         运行时适配档案与网络工具链锁定信息
include/          配置、Provider 与诊断结构定义
src/              Windows x64 Provider 和离线分析工具
scripts/          构建、配置、状态查询和验收脚本
transport/        Go 网络传输、连接记录和本机控制台
tests/            自有测试程序与隔离运行时夹具
docs/             使用指南、技术说明和阶段验收
third_party/      第三方源码、数据及许可证
```

## 文档

| 想了解 | 入口 |
| --- | --- |
| 构建、配置校验和测试结果 | [构建与验证](docs/build.md) · [测试](docs/testing.md) · [文档索引](docs/README.md) |
| 时区、UTC 偏移和语言选择 | [时间与区域配置](docs/time-configuration.md) · [区域格式与 UI 语言](docs/Stage3-Locale.md) |
| 控制台、默认浏览器打开确认、代理与连接记录 | [网页控制台](docs/GUI.md) · [外链确认](docs/GUI.md#打开默认浏览器前询问) · [网络代理](docs/Network-Proxy.md) |
| Store 目录、后台刷新和新 EXE 观测 | [目标目录](docs/targets.md) · [自动刷新与启动诊断](docs/automatic-refresh.md) |
| 运行时兼容性及可选采样 | [运行时与 WinRT](docs/Stage5-Runtime.md) · [离线兼容分析](docs/Stage6-Compatibility.md) |

文档结构参考 [Vectored Overloading 的 README](https://github.com/KyuuChiaki/Vectored-Overloading/blob/master/README.zh-CN.md)。

## 许可证

仓库自有代码采用 [MIT](LICENSE)。传输依赖及其许可证见[第三方声明](transport/THIRD_PARTY_NOTICES.md)和[许可证目录](third_party/network-licenses/)。
