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
| `time.utcOffsetSeconds` | 有符号整数秒；需能转换为 100ns 值，并使当前 UTC／本地日期保持可表示，具体由校验器检查 |
| `locale.enabled` | 启用 Windows 默认区域与 UI 语言 |
| `locale.formatLocale` | 默认格式区域，决定日期、数字、货币等标准 NLS 数据 |
| `locale.uiLanguage` | 默认 UI 语言，与格式区域分离 |
| `region.enabled` | 独立启用地理区域覆盖 |
| `region.homeRegion` | 具体 ISO 两字母国家／地区代码，如 US、DE、JP；不从语言或时区推导 |
| `runtime.enabled` | 启用 ICU／JavaScript、WinRT 和 Electron 默认语言扩展；关闭后原 Windows 功能仍可工作 |
| `runtime.unknownVersionPolicy` | `block` 或 `passthrough`，适用于身份门控通过的受管理 Claude |
| `runtime.captureEnabled` | 可选自然 JavaScript 上下文采样，默认 false |

Locale 必须是本机 NLS 可验证、能稳定表示为 LCID/LANGID 的具体区域，如 en-US、en-GB、de-DE、fr-FR、zh-CN、ja-JP。中性名称、默认占位符和无法唯一表示的自定义 Locale 不支持。

## 时间模型

```text
虚拟 UTC = 真实 UTC + utcOffsetSeconds
虚拟本地时间 = 按 timeZoneId 对应日期的 DST 规则换算虚拟 UTC
```

读取“现在”时只加一次偏移；转换调用方提供的时间戳时只转换输入。QPC、TickCount、timeGetTime、hrtime、运行时长和 CPU 耗时保持真实。

| 地区 | Windows ID |
|---|---|
| 洛杉矶 | `Pacific Standard Time` |
| 纽约 | `Eastern Standard Time` |
| UTC | `UTC` |
| 印度 | `India Standard Time` |

名称中的 Standard Time 不代表关闭 DST。可用 `Get-TimeZone -ListAvailable` 查看本机 ID。JSON 不支持设置一个冻结的固定时刻。

例如，纽约、UTC 偏移 +3600、德国格式、日语 UI、德国地理区域可分别设置为 `Eastern Standard Time`、`3600`、`de-DE`、`ja-JP`、`DE`，这些字段互不推导。

## 显式选择

应用显式传入 Locale、时区、格式模板、币种、日历、数字系统，或成功设置线程／进程语言、会话语言和请求头时，保留其选择。默认查询使用配置；不会逐项硬编码英文格式字符串。

Node 的 TZ 和缓存重置保留对应运行时原有行为。Chromium 自己生成 Accept-Language 的归一化、父语言和 q 值。Node 原来不发送语言头或发送 `*` 的路径保持原义。

## 兼容与失败策略

`block`：启用前拒绝不支持的运行时；已通过身份门控的进程在启动适配失败时，于业务代码前退出，代码 `0xE0CDF501`。

`passthrough`：启动适配失败时回滚内部补丁，整套虚拟化透传，避免只保留部分时间／语言功能。身份不匹配的同名程序始终透传，不受 block 影响。通用测试 Provider 的失败行为详见测试代码，不应当作 Claude 门控 Provider 的阻止保证。

安装工具提前拒绝无效配置。运行时配置缺失、损坏和功能初始化失败可通过各诊断查询；不能将“DLL 已加载”视为功能就绪。

## 部署与旧版

调用 `Initialize-Config.ps1` 初始化。源码模板不会因为 `Enable` 自动覆盖已部署 JSON。schema 1 只保留原时间功能；schema 2 为时间和区域语言；schema 3 加入独立 region 和 runtime。旧配置不会自动升级。运行时适配需要 schema 3 且 `runtime.enabled=true`。

当前无 CRT Provider 使用固定 Native 配置路径 `C:\ProgramData\ClaudeDesktopFake\stage2\timezone.json`。管理脚本通过 Windows 公共数据目录定位同一部署；当前支持默认 ProgramData 布局。重定向到其他盘符的 ProgramData 尚未验收，不能只移动 JSON 后假定 Provider 会读取它。System32 部署使用 `%SystemRoot%`。这些是运行时部署约定，不是克隆目录或开发工具路径。
