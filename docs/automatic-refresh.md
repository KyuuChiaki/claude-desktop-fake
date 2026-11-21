# 自动刷新与启动诊断

[返回文档索引](README.md)

自动刷新状态与启动观测在现行管理脚本中独立报告。前者显示所管任务、刷新结果和注册事务。后者记录 Windows 创建进程后，文件身份何时可以核实。

## 查看后台状态

```powershell
$status = .\scripts\Manage-ClaudeAuto.ps1 -Action Status | ConvertFrom-Json
$status | Select-Object configured, enabled, taskPresent, startsAtBoot, monitorRunning, pending, error
```

`Manage-Claude.ps1 -Action Status` 也在 `automaticRefresh` 下返回这些字段。

| 字段 | 含义 |
| --- | --- |
| `configured`、`enabled`、`taskPresent` | 是否有管理记录、是否激活有效任务、是否存在对应计划任务 |
| `monitorRunning` | 计划任务正在运行，近 30 秒内有有效心跳，进程身份核对通过 |
| `startsAtBoot` | 所有权核对通过的任务配置可随开机启动。重启实测以独立记录为准 |
| `health` | 最近刷新、进程事件订阅、失败原因与后台处理 |
| `pending`、`error` | 未完成的安装事务以及验证错误 |
| `startupObservation` | 启动观测健康、预验签统计和最近的身份判定 |

正式后台从 `%ProgramData%\ClaudeDesktopFake\stage3\claude-auto` 中有所有权记录的发布快照运行。任务使用安装时保存的目标用户已知文件夹，并以 LocalSystem 运行。更新工作树后，可从状态核对后台仍在使用哪份发布快照。`Enable` 和 `Disable` 的完整生命周期包含该任务。[文件身份与事务](Stage4-Claude.md)

## 新 EXE 的启动身份诊断

独立线程接收 `Win32_ProcessStartTrace`，并记录 Windows 提供的创建时间。另一线程在所配置目录中新 EXE 写完或改名后进行 Authenticode 预验签。全机补扫、整包刷新或读取更新目录时，启动诊断仍可独立处理到达的事件。

有效签名在内存中保留两分钟。命中前复核路径、卷序列号、File ID、大小、最后写入时间和 NTFS 更改时间。文件仍有写入者、磁盘内容在进程创建后才变化、进程已经退出或 PID 已复用时，诊断给出对应的待核实分类。溢出和目录变化会触发补扫。缓存未命中时可在启动路径验签，并用当前身份清单检查登记状态。

```powershell
$status = .\scripts\Manage-ClaudeAuto.ps1 -Action Status | ConvertFrom-Json
$status.startupObservation | Select-Object ready, stale, hosting
$status.startupObservation.processStarts.recent |
    Select-Object image, pid, signature, registration, source, creationToReceiptMs, creationToVerdictMs, withinThreeSeconds
```

| 字段或值 | 含义 |
| --- | --- |
| `ready`、`stale` | 观察组件是否就绪，以及最近状态是否超过 5 秒未更新 |
| `hosting=monitor` | 已部署后台自身托管观察组件 |
| `hosting=current-monitor-session` | 临时组件跟随旧版后台的当前进程，后台退出、切换发布版或设备重启时结束 |
| `preverified` | 文件在进程启动前已验签，启动时复核通过 |
| `startup-verification`、`startup-cache` | 启动路径验签，或复用之前核实过的同一文件 |
| `registered`、`unlisted`、`file-changed` | 匹配当前登记、清单中没有该文件、同一路径已有其他文件记录 |
| `manifest-unavailable`、`changed-since-start` | 清单无法读取，或磁盘文件更改晚于进程创建 |
| `creationToReceiptMs`、`creationToVerdictMs` | 从进程创建到收到事件、到完成判定的毫秒数 |
| `exitedBeforeInspection`、`reusedPid`、`unavailable`、`dropped` | 进程提前退出、PID 复用、无法检查和队列丢弃分别计数 |

需要临时观察时，可在当前账户下执行一次限时采样。采样结束输出 JSON，读取现有范围和清单。

```powershell
.\scripts\Measure-StartupObservation.ps1 -Seconds 15
```

## 启动前保护的范围

IFEO 按已经管理的 EXE 文件名触发。完全新的名字可能在后台收到通知前就执行代码或联网。设备启动和后台任务就绪之间也存在事件监控窗口。启动观测报告的是**身份判定耗时**。实际注册和后台处理从各自的事务与 `health.actions` 核对。

已知文件名的启动门控拒绝和后台处理对应各自的诊断。历史日志中的 `0xE0CDF601` 表示启动门控拒绝，`0xE0CDF602` 表示后台已处理未登记进程。运行时适配失败的 `0xE0CDF501` 见[跨版本适配](Stage6-Compatibility.md)。

## 状态与故障恢复

- `enabled=true` 对应任务配置。查看具体 PID 的实际状态还需对照 `running[]` 和 Provider 诊断。
- `startupObservation` 缺失或过期时，检查后台任务、发布快照和心跳。旧版后台的临时观测只覆盖当次会话。跨开机会话的诊断依赖包含该组件的已部署后台。
- 刷新失败时保留原有登记并重试。可从 `health` 和离线兼容报告查看签名、文件身份或运行时失败原因。
- 关闭现有托管部署时，管理器先停止自己的任务并收尾正在进行的刷新事务，再恢复原 IFEO 值。存在来源不一致的值或任务定义时保留恢复材料。保留 `state.json`、`install-pending.json` 和事务备份，以便核对原值和当前配置。
- 已运行进程继续使用其启动快照。`Status` 可以报告需要退出后再次启动的 PID。进程生命周期由用户控制。

需要撤销现有部署时，在对应发布版的 64 位管理员 PowerShell 中执行恢复，并重新查询结果。

```powershell
.\scripts\Manage-Claude.ps1 -Action Disable
.\scripts\Manage-Claude.ps1 -Action Status
```

## 启动观测验收

2026-11-20 使用全机启动事件订阅，启动 100 个不同文件名的微软签名离线夹具。100 次身份判定均在 3 秒内完成，21 项契约检查通过。实测范围为隔离夹具和身份观察。真实 Claude 新版本的启动耗时及首次联网控制需要独立证据。

| 指标 | 实测 |
| --- | ---: |
| 创建至判定中位数 | 945.2 毫秒 |
| 创建至判定 P95 | 1,972.8 毫秒 |
| 创建至判定 P99 | 1,989.0 毫秒 |
| 创建至判定最大值 | 2,000.6 毫秒 |
| 未预验签的额外单样本 | 864.1 毫秒 |

完整记录生成于 `out/audits/startup-observation-global-20261120.json`。可复测文件替换、写入占用、超长路径、清单损坏、退出和 PID 复用等情形：

```powershell
.\scripts\Test-StartupObservation.ps1 -Samples 100 -AllStartEvents -RequireThreeSeconds
```

原有任务和注册回归由 `claude_auto_monitor`、`claude_gate_integration` 验收。它们需要专用测试 Windows 环境与串行执行。[构建与验证](build.md#验证)
