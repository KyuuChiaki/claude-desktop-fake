# 第四步 · 签名、文件身份与登记

[返回文档索引](README.md)

第四步建立 Store 包的签名核验、进程的文件身份检查和登记恢复。现行后台生命周期、启动诊断和发布快照见[自动刷新与启动诊断](automatic-refresh.md)。

## 包发现与文件身份

先读取当前用户注册的 Store 包和应用入口，再按[目标目录](targets.md)核对候选 EXE。主程序必须通过有效 Authenticode、AMD64 和发布者名称 `Anthropic, PBC` 的检查。辅助程序逐个核对并报告跳过原因。发布者名称忽略大小写，允许证书在有效签名链下正常轮换。

经验证的清单记录普通路径、Native 路径、卷序列号、128 位 File ID、文件大小和最后写入时间。清单最多 64 个映像与 64 KiB。运行进程通过文件身份及清单匹配判定适用范围。IFEO 根据 EXE 文件名登记，实际 Provider 适用以身份诊断为准。新文件替换旧文件后可从状态发现清单过期。

## 查看进程状态

```powershell
$status = .\scripts\Manage-Claude.ps1 -Action Status | ConvertFrom-Json
$status.running | Select-Object pid, path, listed, requiresEnable, requiresRestart
```

`signatureStatus=VerifiedAtEnable` 表示登记时有验签结果，Status 仍会复核文件身份。`stale` 和 `refreshRequired` 反映清单、部署配置或候选的变化。已运行进程持有启动快照，登记状态变化主要影响后续启动。

`CdfClaudeQueryIdentityStatus` 是版本 1、2280 字节的只读结构。内容包括当前映像路径、匹配路径、文件身份、状态、拒绝原因及错误码。`0xF` 表示完整身份匹配。时间与区域语言状态分别报告。对应构建的 DLL 哈希、PE 时间戳、映像大小和链接 map 都可用于验证读出的诊断。[身份诊断结构](../include/claude_identity.h)

## 原值与事务

管理材料位于 `%ProgramData%\ClaudeDesktopFake\stage3\claude`。

| 文件或目录 | 内容 |
| --- | --- |
| `images.json` | 已验证文件身份及兼容性引用 |
| `deployment.json` | Provider 路径、哈希和所有权 |
| `state.json` 和 `state/<image>.json` | 当前登记与首次保存的原值、类型和存在状态 |
| `deployment-pending.json`、`recovery.<id>` | 未完成事务及恢复材料 |

批次更新以注册表当前状态和恢复记录为准。已全部或部分回到原值时，撤销操作仍逐个核对安装值或精确原值。第三种值、外部 Debugger、路径过滤或部署哈希冲突会停止处理。恢复记录和日志供进一步核对。

## 阶段验收

该轮共有 12 项 CTest，包含 `claude_gate_build_inspection` 和 `claude_gate_integration`。身份门控测试使用单独的测试 Provider 和自有夹具，覆盖多个 EXE 名称、签名失败、文件身份变化、缺失和损坏的清单、TLS 状态、外部冲突、幂等及事务中断恢复。

Store 注册验收报告验证过的候选、整批状态和 IFEO 前后快照。报告生成于 `out/build/x64-release/test-results`。登记成功、实际进程身份匹配和特定接口行为分别取证。JS、WinRT 与服务各自的范围见[运行时与 WinRT](Stage5-Runtime.md)和[验收摘要](validation.md)。
