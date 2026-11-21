# 文档索引

[返回主文档](../README.md)

## 使用指南

| 文档 | 内容 |
| --- | --- |
| [构建与验证](build.md) | Windows 工具链、通用构建命令、测试条件和产物位置 |
| [使用与启停](usage.md) | 初始配置、登记、升级、撤销及终端开关 |
| [时间与区域配置](time-configuration.md) | schema 1／2／3、UTC 与时区的区别、命令行预览和快照语义 |
| [网页控制台](GUI.md) | 启动、页面状态、时间和网络检查、连接记录和 DNS |
| [网络代理](Network-Proxy.md) | 传输、配置和凭据、接口范围及验证边界 |
| [目标目录](targets.md) | Store 发现、通配规则、Claude Code 和状态字段 |
| [自动刷新与启动诊断](automatic-refresh.md) | 后台状态、身份预验签、耗时测量和冲突恢复 |
| [跨版本适配](Stage6-Compatibility.md) | 离线兼容报告、运行时档案和绑定诊断 |
| [测试](testing.md) | 原生、Go、控制台及隔离进程的验证入口 |
| [故障排查](troubleshooting.md) | 冲突、兼容失败和中断恢复 |

## 技术说明

| 文档 | 内容 |
| --- | --- |
| [Verifier 加载原型](Stage1.md) | 自有 Probe、早期加载观测与握手诊断 |
| [区域格式与 UI 语言](Stage3-Locale.md) | Windows NLS、显式选择、列表和线程状态 |
| [签名与文件身份](Stage4-Claude.md) | 包发现、签名检查、进程身份和注册状态 |
| [运行时与 WinRT](Stage5-Runtime.md) | 默认语言、格式、地理区域、时间和可选采样 |
| [Native 时区信息类 93](Native-TimeZone-Class93.md) | 特定 Windows 构建下的查询契约 |
| [Native MUI ABI](Native-MUI-ABI.md) | Native 和 Win32 的返回契约以及验证依据 |

## 验收记录

- [公开验收摘要](validation.md)记录参考环境、运行时行为、网络与控制台的验证范围。
- [启动观测验收](automatic-refresh.md#启动观测验收)记录全机启动事件订阅下的 100 个新测试文件名及实际耗时。
