# Claude Desktop Fake

Windows x64 的进程内时间、时区、区域格式和语言虚拟化实验项目。当前版本 **0.6.0**。

通过 IFEO + Windows Application Verifier，在测试程序或通过签名与文件身份门控的 Microsoft Store 版 Claude 进入 TLS／业务代码前加载 Provider。配置由 JSON 提供，运行时读取启动快照。项目不会修改系统全局时间、时区或磁盘上的 Claude 包／ASAR。

本项目独立于 Anthropic、Microsoft 和 Electron。语言标识与格式化结果不等于应用资源文本翻译，地理区域也不等于 IP 地理位置。

## 支持范围

- Windows **build 19045、AMD64**；其他 Windows 上能编译不代表运行时已验收。
- Windows Native／Win32、验收覆盖的 UCRT、WinRT 默认语言与格式化、独立 Geo。
- 已验证 ABI 的 Node／V8／ICU／Electron 默认 Intl、navigator 和 Chromium 默认网络语言。
- Electron 44.9.3、44.9.2 完整矩阵通过；44.8.0 核心通过，可选采样不完整。
- 真实 Claude 的包注册与隔离 Electron 的行为证据分开，真实进程／SYSTEM 服务仍需用户控制启动后采集。

未知 ABI、直接 syscall／共享页、自定义时间源、未覆盖的私有接口和其他 Windows 版本不作兼容保证。完整边界见 [兼容性](docs/compatibility.md)。

## 快速开始

需要 64 位 PowerShell 7、Visual Studio 2022/Build Tools 的 C++ 工作负载、Windows SDK 10.0.26100.0、CMake 3.24+、Python 3.10+。默认 Ninja + MSVC，x64 Release，16 线程。工具路径自动发现，也可显式指定；详见 [构建](docs/build.md)。

在仓库根目录执行，无需管理员：

```powershell
.\scripts\Build.ps1
.\scripts\Test.ps1
```

随后在**安装了 Claude Store 包的同一用户会话**中打开管理员、64 位 PowerShell，仍从仓库根目录执行：

```powershell
.\scripts\Initialize-Config.ps1
.\scripts\Manage-Claude.ps1 -Action Enable
.\scripts\Manage-Claude.ps1 -Action Status
```

初始化工具创建经过校验的首次配置，拒绝覆盖已有不同内容。然后由用户退出并重新启动 Claude；服务的重启也由用户安排。命令不自动改变应用／服务生命周期。

关闭：

```powershell
.\scripts\Manage-Claude.ps1 -Action Disable
```

Disable 恢复 IFEO，但不卸载已运行进程中的 DLL；进程退出后恢复基线。保留部署和恢复材料的规则见 [使用与恢复](docs/usage.md)。

## 默认配置

[config/timezone.json](config/timezone.json) 为 schema 3 模板：

```json
{
  "schemaVersion": 3,
  "time": {"enabled": true, "timeZoneId": "Pacific Standard Time", "utcOffsetSeconds": 0},
  "locale": {"enabled": true, "formatLocale": "en-US", "uiLanguage": "en-US"},
  "region": {"enabled": true, "homeRegion": "US"},
  "runtime": {"enabled": true, "unknownVersionPolicy": "block", "captureEnabled": false}
}
```

```text
虚拟 UTC = 真实 UTC + utcOffsetSeconds
虚拟本地时间 = 按配置时区及对应日期的 DST 规则换算虚拟 UTC
```

`utcOffsetSeconds` 是**额外的 UTC 时钟偏移**，不是时区偏移。只想显示洛杉矶当前时间时，保持 `Pacific Standard Time` 和 `0`；程序自动按日期采用 UTC−7／UTC−8。不要把 `-25200` 或 `-28800` 再填进该字段，也不要删除这个必填字段。

构建后可只读预览，不需要管理员，也不安装 Provider：

```powershell
.\scripts\Show-TimeConfig.ps1 -ConfigPath '.\config\timezone.json'
```

输出将 `utcClockShiftSeconds` 与 `timeZoneOffsetSeconds` 分开，并显示虚拟 UTC、本地时间和夏令时状态。`captureEnabled` 只控制可选 JS 诊断采样，关闭采样仍能启用 Hook；具体见 [配置说明](docs/configuration.md)。

格式区域与 UI 语言分离；国家地区独立。显式 Locale、时区、线程／进程语言、会话及请求头优先。QPC、TickCount、hrtime、运行时长和 CPU 耗时保持真实。schema 1／2 保留旧行为，不自动开启新功能。字段、编辑与校验说明见 [配置](docs/configuration.md)。

## 更新后的兼容处理

Claude 更新后重新执行 `Enable`。工具从当前用户的 Store 注册发现路径，重新检查有效 Authenticode 签名、`Anthropic, PBC` 签名者和具体文件身份，再进行离线兼容解析。

EXE 枚举目录由 [config/claude-targets.json](config/claude-targets.json) 配置，默认包含动态发现的 Store 包、当前用户的 `%LOCALAPPDATA%\Claude-3p`、`%LOCALAPPDATA%\Packages` 和 `%ProgramFiles%\WindowsApps`，覆盖 Desktop 下载的 Claude Code、Store 重定向缓存及磁盘上并存的 Claude 安装版本。目录变量无需写入用户名或系统盘盘符。每个文件仍须独立验签和登记，修改目录或下载新版本后重新 Enable；详见 [枚举目录](docs/targets.md)。

完整映像命中、同运行时重打包或已验证 ABI 自动解析均会生成绑定。定位不唯一、ABI 改变或证据不足时拒绝适配。默认 block 会在启用前拒绝不支持的目标；启动复核失败按配置阻止或整套透传。身份不匹配的同名程序保持透传。

Provider 自身升级先 `Disable`，再替换构建并 `Enable`。不强行覆盖调试器、其他 Verifier、过滤配置或外部修改。

## 文档

| 文档 | 内容 |
|---|---|
| [构建](docs/build.md) | 环境、自动发现、工具覆盖、产物和生成器 |
| [使用](docs/usage.md) | 首次部署、启停、更新、通用 Probe、诊断和恢复 |
| [配置](docs/configuration.md) | 时间、区域、语言、地理区域与失败策略 |
| [枚举目录](docs/targets.md) | JSON 目录列表、用户变量、Code 缓存、身份刷新与状态 |
| [兼容性](docs/compatibility.md) | 分级识别、离线分析、绑定和支持边界 |
| [测试](docs/testing.md) | 9 项无注册检查、19 项完整套件和夹具准备 |
| [故障排查](docs/troubleshooting.md) | 错误分类、冲突与中断恢复 |
| [架构](docs/architecture.md) | 源码导航、加载链与诊断 ABI |
| [验收摘要](docs/validation.md) | 参考环境事实与实际进程证据边界 |

构建缓存、下载夹具、日志、map、PDB、身份清单和本机恢复记录不作为仓库内容提交。第三方运行时 EXE 和 Windows SDK 不随仓库分发。

## 许可证与参与

原创代码与文档使用 [MIT License](LICENSE)。第三方材料适用各自许可证，见 [第三方通知](THIRD_PARTY_NOTICES.md)。

提交修改前阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
