# 时间与区域配置

[返回文档索引](README.md)

## 文件和版本

[`config/timezone.json`](../config/timezone.json) 是仓库模板。正在运行的受管进程在启动时读取机器 CommonApplicationData 下的 `ClaudeDesktopFake\stage2\timezone.json`，通常显示为 `%ProgramData%\ClaudeDesktopFake\stage2\timezone.json`。模板、部署文件和进程内快照对应不同状态。

| 版本 | 结构 |
| --- | --- |
| 1 | 顶层 `schemaVersion`、`enabled`、`timeZoneId` 和 `utcOffsetSeconds`，只启用时间功能 |
| 2 | 嵌套 `time` 与 `locale`，两组分别启用 |
| 3 | 加入独立的 `region` 与 `runtime`，当前模板使用此版本 |

JSON 使用 UTF-8，可带 BOM，整文件上限 16 KiB。各版本需要提供声明的完整字段，校验器拒绝未知或重复字段、错误类型和超出范围的数值。可在编辑器外部关联 [schema 3](../config/timezone-v3.schema.json)，运行配置中只保留该版本声明的字段。

## schema 3 示例

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

| 字段 | 作用 |
| --- | --- |
| `time.timeZoneId` | 使用本机安装的 Windows 时区 ID。洛杉矶为 `Pacific Standard Time`，纽约为 `Eastern Standard Time` |
| `time.utcOffsetSeconds` | 额外的 UTC 时钟偏移，单位为有符号整数秒。保留真实 UTC 时填 `0` |
| `locale.formatLocale` | 日期、时间、数字、货币和日历的默认 NLS 区域，例如 `de-DE` |
| `locale.uiLanguage` | 默认 UI 语言标识和首选列表，例如 `en-US`。实际资源文本由应用和系统的语言资源决定 |
| `region.homeRegion` | Windows NLS 可识别的具体 ISO 两字母国家或地区，独立于时区、语言和网络出口 |
| `runtime.unknownVersionPolicy` | 受管理且身份匹配的应用遇到兼容失败时选择 `block` 或整套 `passthrough` |
| `runtime.captureEnabled` | 兼容的 JS 上下文可选诊断采样。设为 `false` 时保留正常功能，关闭采样 |

各组的 `enabled` 独立控制对应功能。`locale` 要求具体且有稳定 LCID／LANGID 的名称。多组同时启用时，显式 Locale、时区、日期或格式仍按调用参数处理。[区域语言细节](Stage3-Locale.md) · [运行时细节](Stage5-Runtime.md)

## UTC、当地时间和夏令时

```text
虚拟 UTC = 参考 UTC + utcOffsetSeconds
本地时间 = 虚拟 UTC 按 timeZoneId 对应日期的 Windows 规则换算
```

一样的洛杉矶设置会得到不同季节的时区偏移，UTC 时钟偏移仍为零。

| 参考 UTC | `utcOffsetSeconds` | 当地时间 | 时区偏移 |
| --- | ---: | --- | ---: |
| 2026-01-15 20:00 UTC | 0 | 2026-01-15 12:00 PST | −28,800 秒 |
| 2026-07-15 20:00 UTC | 0 | 2026-07-15 13:00 PDT | −25,200 秒 |

`Standard Time` 是 Windows 时区 ID 的一部分。对应年度的规则仍会计算 DST。需要独立把时钟拨快一小时才将 `utcOffsetSeconds` 设为 `3600`。`UTC` 和 `India Standard Time` 也是可选的 Windows ID，需由本机规则校验。

读取「现在」的接口加一次时钟偏移。转换调用方传入的时间戳时只处理输入。年度时区查询和历史日期转换遵循 Windows 的规则区间。`FileTimeToLocalFileTime` 一类入口沿用 Windows 的当前偏移语义。QPC、TickCount 和 `timeGetTime` 继续用真实计时源。[Native 时区查询契约](Native-TimeZone-Class93.md)

| 接口 | 对应语义 |
| --- | --- |
| `GetLocalTime`、`GetSystemTime`、FILETIME 系列、`NtQuerySystemTime` | 从相应时间源读取，UTC 偏移只加一次。本地时间再按目标时区计算 |
| `GetTimeZoneInformation`、`GetDynamicTimeZoneInformation`、`GetTimeZoneInformationForYear` | 读取目标地区的当前或相应年份规则 |
| `NtQuerySystemInformation` 的 3、44 和 102 | 保留查询契约，在成功时处理时间或时区字段。类 93 保留原 Windows 查询行为 |
| `SystemTimeToTzSpecificLocalTime` 族及逆转换 | 默认时区使用目标规则，显式时区按原参数处理 |
| `RtlTimeToTimeFields` | 只将传入的时间戳转换为字段 |

类 3 的 `BootTime` 与 `CurrentTime` 使用同一 UTC 偏移，因此两者差值仍与真实运行时长一致。

## 预览与校验

构建 `CdfTimeRules64.exe` 后在仓库根目录执行。64 位 PowerShell 即可预览本机规则。

```powershell
.\scripts\Show-TimeConfig.ps1 -ConfigPath .\config\timezone.json
.\scripts\Show-TimeConfig.ps1 -ReferenceUtc '2026-07-15T20:00:00Z'

$machineData = [Environment]::GetFolderPath('CommonApplicationData')
$deployment = Join-Path $machineData 'ClaudeDesktopFake\stage2\timezone.json'
if (Test-Path -LiteralPath $deployment) {
    .\scripts\Show-TimeConfig.ps1 -ConfigPath $deployment
}
```

查看 `referenceUtc`、`virtualUtc`、`virtualLocalTime`、`utcClockShiftSeconds`、`timeZoneOffsetSeconds` 和 `daylightSavingTime` 可核对结果。固定 `ReferenceUtc` 为这次预览提供输入。已运行进程的实际行为请用具体 PID 的诊断检查。

## 启动快照与恢复

每个新进程读取一次 JSON，并校验相应的时区和 NLS 数据。文件结构无效时使用原始行为。功能组初始化失败时，诊断记录失败阶段。部署变更在下一次进程启动时读取。网页控制台提交配置时会先校验内容和当前哈希。

部署管理记录保存共享 DLL 和配置的哈希，以及所管 IFEO 值的原始类型和数据。发现外部修改时，管理工具保留恢复记录并报告冲突。先从 `Status` 核对期望、原值与实际值。手工编辑部署文件可能触发哈希冲突，因此建议使用模板副本和管理页面保存受管理配置。[控制台](GUI.md) · [恢复说明](automatic-refresh.md#状态与故障恢复)

## 时间诊断

[`CdfTimeZoneQueryStatus`](../include/time_zone_status.h) 使用版本 1、528 字节结构，记录解析状态、配置时区、偏移、错误阶段及调用计数。核心时间功能完全就绪时状态为 `0x1F`。运行时进程创建时间和 JS 采样另见[运行时说明](Stage5-Runtime.md)。
