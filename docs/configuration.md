# 配置

模板为 [config/timezone.json](../config/timezone.json)。每个进程启动时读取一次 UTF-8 JSON，最大 16 KiB；修改后需要启动新进程。严格校验版本、字段、类型、重复字段、未知字段和整数范围。

```json
{
  "schemaVersion": 3,
  "time": {
    "enabled": true,
    "timeZoneId": "Pacific Standard Time",
    "utcOffsetSeconds": 0
  },
  "locale": {
    "enabled": true,
    "formatLocale": "en-US",
    "uiLanguage": "en-US"
  },
  "region": {
    "enabled": true,
    "homeRegion": "US"
  },
  "runtime": {
    "enabled": true,
    "unknownVersionPolicy": "block",
    "captureEnabled": false
  }
}
```

## 字段

| 字段 | 含义 |
|---|---|
| `time.enabled` | 启用虚拟时间和时区 |
| `time.timeZoneId` | 本机安装的 Windows 时区 ID，不是 IANA 名称 |
| `time.utcOffsetSeconds` | **额外的 UTC 时钟偏移秒数，不是时区偏移**；`0` 表示 UTC 时钟不快进或倒退。必填整数，范围与日期由校验器检查 |
| `locale.enabled` | 启用 Windows 默认区域与 UI 语言 |
| `locale.formatLocale` | 默认格式区域，决定日期、数字、货币等标准 NLS 数据 |
| `locale.uiLanguage` | 默认 UI 语言，与格式区域分离 |
| `region.enabled` | 独立启用地理区域覆盖 |
| `region.homeRegion` | 具体 ISO 两字母国家／地区代码，如 US、DE、JP；不从语言或时区推导 |
| `runtime.enabled` | 启用 ICU／JavaScript、WinRT 和 Electron 默认语言扩展；关闭后原 Windows 功能仍可工作 |
| `runtime.unknownVersionPolicy` | `block` 或 `passthrough`，适用于身份门控通过的受管理 Claude |
| `runtime.captureEnabled` | 可选自然 JavaScript 上下文的有界内存诊断采样，默认 false；与是否启用 Hook 分开，不是日志、遥测或网络抓包开关 |

Locale 必须是本机 NLS 可验证、能稳定表示为 LCID/LANGID 的具体区域，如 en-US、en-GB、de-DE、fr-FR、zh-CN、ja-JP。中性名称、默认占位符和无法唯一表示的自定义 Locale 不支持。

## 时间模型

```text
虚拟 UTC = 真实 UTC + utcOffsetSeconds
虚拟本地时间 = 按 timeZoneId 对应日期的 DST 规则换算虚拟 UTC
```

### `utcOffsetSeconds = 0` 与洛杉矶时区完全一致

两个偏移分别在不同步骤应用：`utcOffsetSeconds` 调整“现在”的 UTC 时钟；`timeZoneId` 再决定该虚拟 UTC 所对应的本地时间与夏令时。`0` 是精确的零时钟偏移，不是“未指定”、自动探测占位符或强制使用 UTC 时区。

只需洛杉矶当前时间时，使用 `Pacific Standard Time` 和 `0`。时区规则自动产生夏令时 UTC−7（−25200 秒）或标准时 UTC−8（−28800 秒）。不要把这两个时区偏移填进 `utcOffsetSeconds`：那会使所有 UTC 读取也倒退 7／8 小时，然后再次进行正常的时区换算。字段为必填，删除会被严格配置校验拒绝。

以下为固定输入的例子，不依赖运行说明时的系统日期：

| 参考真实 UTC | Windows 时区 | `utcOffsetSeconds` | 虚拟 UTC | 虚拟本地时间 |
|---|---|---:|---|---|
| 2026-10-29 12:00Z | Pacific Standard Time | 0 | 2026-10-29 12:00Z | 2026-10-29 05:00−07:00 |
| 2026-01-15 12:00Z | Pacific Standard Time | 0 | 2026-01-15 12:00Z | 2026-01-15 04:00−08:00 |
| 2026-10-29 12:00Z | Eastern Standard Time | +3600 | 2026-10-29 13:00Z | 2026-10-29 09:00−04:00 |
| 2026-10-29 12:00Z | Pacific Standard Time | −25200 | 2026-10-29 05:00Z | 2026-10-28 22:00−07:00 |

夏令时按**偏移后的虚拟 UTC**判断；时钟偏移如果跨过夏令时切换点，使用切换后的规则。Windows ID 不能直接改成 `America/Los_Angeles`；ICU 的 Windows→IANA 映射在已支持运行时内部完成。

读取“现在”时只加一次偏移；转换调用方提供的时间戳时只转换输入。QPC、TickCount、timeGetTime、hrtime、运行时长和 CPU 耗时保持真实。

| 地区 | Windows ID |
|---|---|
| 洛杉矶 | `Pacific Standard Time` |
| 纽约 | `Eastern Standard Time` |
| UTC | `UTC` |
| 印度 | `India Standard Time` |

名称中的 Standard Time 不代表关闭 DST。可用 `Get-TimeZone -ListAvailable` 查看本机 ID。JSON 不支持设置一个冻结的固定时刻。

例如，纽约、UTC 偏移 +3600、德国格式、日语 UI、德国地理区域可分别设置为 `Eastern Standard Time`、`3600`、`de-DE`、`ja-JP`、`DE`，这些字段互不推导。

### 只读校验与时间预览

构建后，在仓库根目录预览模板，或用 `-ConfigPath` 指定部署文件：

```powershell
.\scripts\Show-TimeConfig.ps1 -ConfigPath '.\config\timezone.json'
$config = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ClaudeDesktopFake\stage2\timezone.json'
.\scripts\Show-TimeConfig.ps1 -ConfigPath $config
.\scripts\Show-TimeConfig.ps1 -ConfigPath '.\config\timezone.json' `
  -ReferenceUtc '2026-11-01T09:00:00Z'
```

不指定 `ReferenceUtc` 时从未注册的本工具读取参考 UTC。指定时只接受 `yyyy-MM-ddTHH:mm:ssZ` 或带三位毫秒的 `yyyy-MM-ddTHH:mm:ss.fffZ`；该参数仅用于本次计算，不修改 JSON 或系统时钟。支持 schema 1／2／3，不要求管理员；脚本从同一构建的 `CdfTimeRules64.exe --preview-config` 获取结果，复用 Provider 的解析、年度规则和换算代码。

输出包含 `configPath`、配置 SHA-256、`referenceUtc`、`utcClockShiftSeconds`（JSON 的 `utcOffsetSeconds`）、`virtualUtc`、`timeZoneOffsetSeconds`、`virtualLocalTime`、`daylightSavingTime`。关闭时间功能时保留配置值，虚拟结果为 null。`previewOnly=true` 表示这只是配置计算，不能用作现有进程已加载或 Hook 成功的证据。

[timezone-v3.schema.json](../config/timezone-v3.schema.json) 提供可供编辑器关联的 JSON Schema 和逐字段说明。请通过编辑器的外部关联使用，不要向配置添加 `$schema` 字段；运行时仍拒绝未知字段。该文件用于结构提示，不能替代本机时区、NLS、日期范围和运行时兼容校验。

### 采样与功能启用的关系

`captureEnabled=false` 仅关闭额外 JS 诊断采样，不会关闭时间、Locale 或运行时 Hook。设为 true 后，在安全的自然 JS 上下文中采样 Date、Intl、navigator、性能时钟等值，保存在进程内有界缓冲区，供 `Capture-Runtime.ps1` 只读提取；它不创建采样线程、开启调试端口或记录请求正文。未产生或未采到的上下文会分别报告，开启采样还要求该运行时具备完整的采样辅助 ABI。

## 显式选择

应用显式传入 Locale、时区、格式模板、币种、日历、数字系统，或成功设置线程／进程语言、会话语言和请求头时，保留其选择。默认查询使用配置；不会逐项硬编码英文格式字符串。

Node 的 TZ 和缓存重置保留对应运行时原有行为。Chromium 自己生成 Accept-Language 的归一化、父语言和 q 值。Node 原来不发送语言头或发送 `*` 的路径保持原义。

## 兼容与失败策略

`block`：启用前拒绝不支持的运行时；已通过身份门控的进程在启动适配失败时，于业务代码前退出，代码 `0xE0CDF501`。

`passthrough`：启动适配失败时回滚内部补丁，整套虚拟化透传，避免只保留部分时间／语言功能。身份不匹配的同名程序始终透传，不受 block 影响。通用测试 Provider 的失败行为详见测试代码，不应当作 Claude 门控 Provider 的阻止保证。

安装工具提前拒绝无效配置。运行时配置缺失、损坏和功能初始化失败可通过各诊断查询；不能将“DLL 已加载”视为功能就绪。

## 部署与旧版

调用 `Initialize-Config.ps1` 初始化。源码模板不会因为 `Enable` 自动覆盖已部署 JSON。schema 1 只保留原时间功能；schema 2 为时间和区域语言；schema 3 加入独立 region 和 runtime。旧配置不会自动升级。运行时适配需要 schema 3 且 `runtime.enabled=true`。

无 CRT Provider 从机器注册表中的 Common AppData 目录构造 `ClaudeDesktopFake\stage2\timezone.json`，默认即 `C:\ProgramData\ClaudeDesktopFake\stage2\timezone.json`，不信任进程自行覆盖的 `ProgramData` 环境变量。管理脚本通过 Windows 公共数据目录定位同一部署。重定向到其他盘符的公共数据目录尚未完成验收，不能只移动 JSON 后假定 Provider 会读取它。System32 部署使用 `%SystemRoot%`。这些是运行时部署约定，不是克隆目录或开发工具路径。
