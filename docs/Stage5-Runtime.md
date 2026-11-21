# 第五步 · 运行时、WinRT、网络语言与地理区域

[返回文档索引](README.md)

第五步在 Windows 10 build 19045、x64 上把运行时扩展纳入正式构建。本文记录 0.5.0 引入的功能语义。当前离线识别、适配规则和绑定状态见[第六步兼容性](Stage6-Compatibility.md)。

## 配置与优先级

每个进程启动时读取部署的 `timezone.json`。schema 1／2 保留原有范围。schema 3 增加独立的 `region` 和 `runtime`。已有配置需明确提供新版字段才会启用新增组。[配置版本与示例](time-configuration.md)

| 配置 | 默认行为 |
| --- | --- |
| `locale.formatLocale` | 受支持的 Intl 和 WinRT 默认格式化。显式 Locale、币种、日历和数字系统优先 |
| `locale.uiLanguage` | 默认 UI 标识、navigator 语言和 Chromium 默认网络语言。应用选择、会话和显式请求头优先 |
| `region.homeRegion` | Win32 默认国家／地区、WinRT HomeRegion 和默认 GeographicRegion。显式地区查询仍由 Windows 处理 |
| `runtime.enabled` | 控制运行时扩展。关闭时核心时间、区域语言和独立地理区域仍由各组配置决定 |
| `runtime.captureEnabled` | 已支持 JS 上下文的可选内存样本。默认关闭 |

## 时间与格式化

- 读取当前 UTC 时应用一次额外偏移。明确的时间戳按输入转换。
- `GetProcessTimes` 和 Native ProcessTimes 调整创建时间和非零退出时间。零退出时间、CPU 耗时及性能计时器保留原义。
- Intl 默认时区从 Windows 时区 ID 经 CLDR 映射获得。CLDR 48 的原始映射和许可证位于 [`third_party/cldr`](../third_party/cldr/)。
- 默认 Intl 覆盖已验收的 8 类构造器，以及 `toLocaleString`、`toLocaleDateString`、`toLocaleTimeString` 和 `localeCompare`。显式时区及 Node 的 `TZ` 缓存遵循运行时原义。
- WinRT 日期和时间格式器使用目标区域的标准数据。格式化传入时间戳时按配置时区转换。明确指定时区时保留调用方选择。
- WinRT Decimal、Percent、Permille 和 Currency 通过 Windows 格式器保留属性、解析和舍入。UI 列表、集合迭代、HSTRING 所有权及引用计数在隔离夹具中验证。

## 默认网络语言

Chromium 使用自己的语言归一化和 Accept-Language 生成规则。验收记录包括默认语言、显式 partition、请求头和重定向。Node `fetch` 的默认 `*` 与 `http` 的无头状态保留原义。该轮运行时语言测试只访问环回服务器。TCP 代理与 DNS 属于[独立网络组件](Network-Proxy.md)。

## 可选采样

`CdfRuntimeQueryStatus` 使用版本 2、816 字节的[诊断结构](../include/runtime_status.h)，记录兼容结果、各组准备状态、错误阶段、Hook 计数和采样计数。匹配构建的本地 DLL 和 map 可用于现有进程的只读检查。

```powershell
$targetPid = [int](Read-Host '要检查的运行时进程 PID')
.\scripts\Capture-Runtime.ps1 -ProcessId $targetPid -OutputPath .\runtime-diagnostics.json
```

`captureEnabled=false` 时关闭可选 JS 样本。开启后最多保存 32 个自然创建的 JS 上下文，每个最多 8,192 字节，字段包括 Date、Intl、navigator、性能计时和运行时版本。采样工具读取已有缓冲区，不触发应用初始化。尚未触发的上下文为 `not-sampled`，失败、采样中和截断各有状态。是否需要采样会影响兼容预检。

## 验收与证据

运行时回归覆盖六组配置、两个测试名以及主进程、渲染进程、Node／Web Worker 和 Utility。固定输入和时间速度与未注册控制进程对照。运行时保护拒绝、回滚、旧 schema 和损坏配置用独立夹具验证。[测试指南](testing.md) · [验收摘要](validation.md)

测试结果在 `out/build/x64-release/test-results`。系统资源文本、真实应用中的 JS 上下文、LocalSystem 服务和其他 Windows 构建均需要各自的行为证据。[构建与验证](build.md#验证)
