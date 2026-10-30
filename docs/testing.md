# 测试

## 无注册测试

构建后，在仓库根目录执行：

```powershell
.\scripts\Test.ps1
```

默认 Unit 套件的 9 项测试不安装 Provider、不修改 IFEO，检查配置／规则、时间语义预览、AMD64、入口、导出、静态依赖和源码约束。脚本从构建缓存发现 CTest，不要求它在 PATH。

`time_config_preview` 覆盖 schema 1／2／3、洛杉矶冬夏令时及两次切换边界、UTC 时钟正负偏移跨越 DST、纽约、印度半小时、跨日／闰日、禁用、无效时间输入和文件只读契约。它同时验证 `0` 不改变 UTC、时区偏移单独应用，且省略必填 `utcOffsetSeconds` 会失败。

## 完整集成测试

仅在受控的 Windows build 19045 x64 测试环境中，用管理员、64 位 PowerShell 执行。涉及共享配置、System32 和 HKLM IFEO；先确保没有其他受管理实例或未完成恢复。测试会启动自己的 Probe 和官方 Electron，并在成功／失败后清理本次注册；外部冲突时保留恢复材料。

已有 Claude 部署时，先执行 `Manage-Claude.ps1 -Action Disable`，同时停止后台刷新和移除开机任务，避免监控与集成测试争用注册锁或共享配置。测试结束后按需重新 `Enable`。CTest 的 `RUN_SERIAL` 只协调本次 CTest 内的用例，不能代替停止另一个终端或后台任务中的部署操作。

先准备三个官方夹具，下载校验 SHA-256：

```powershell
.\scripts\Build.ps1
.\scripts\Prepare-RuntimeFixture.ps1 -Version 44.9.3
.\scripts\Prepare-RuntimeFixture.ps1 -Version 44.9.2
.\scripts\Prepare-RuntimeFixture.ps1 -Version 44.8.0
.\scripts\Initialize-Config.ps1
```

完整套件还需要通用部署所有权记录。全新环境先执行一次测试映像安装／撤销以建立记录：

```powershell
$config = Join-Path $env:ProgramData 'ClaudeDesktopFake\stage2\timezone.json'
try {
  .\scripts\Manage-TimeZone.ps1 -Action Install -ImageName CdfTimeProbe64.exe `
    -DllPath '.\out\build\x64-release\bin\CdfTimeZone64.dll' -ConfigPath $config
} finally {
  .\scripts\Manage-TimeZone.ps1 -Action Uninstall -ImageName CdfTimeProbe64.exe
}
.\scripts\Test.ps1 -Suite Full
```

若检测到已有冲突，应按恢复说明处理，不要强制清理记录。不要同时在两个克隆或终端中运行注册测试。

构建继续使用 16 线程；注册及共享配置测试通过 `RUN_SERIAL` 串行。六组配置、两种名称的重复启动、各进程上下文及完整文件复核会耗时较长。

## 20 项 CTest

| 分组 | 用例 |
|---|---|
| 规则 | `time_rules`、`time_config_preview`、`locale_rules`、`runtime_rules`、`runtime_compatibility_rules` |
| 构建 | `build_inspection`、`timezone_build_inspection`、`locale_build_inspection`、`claude_gate_build_inspection`、`runtime_build_inspection` |
| 加载／恢复 | `verifier_load_integration`、`configuration_safety`、`timezone_configuration_safety` |
| 功能 | `timezone_integration`、`locale_integration`、`claude_gate_integration`、`runtime_integration`、`runtime_cross_version`、`runtime_safety` |
| 自动监控 | `claude_auto_monitor`：文件事件、进程终止条件及临时 SYSTEM 开机任务生命周期 |

`runtime_compatibility_rules` 需要 44.9.3 夹具；`runtime_cross_version` 需要另外两个版本。测试结果输出到 `out/build/x64-release/test-results`，此目录不提交到 Git。

补充测试可单独运行 `Test-GenericRuntimePolicy.ps1` 和 `Test-RuntimeProfilePreflight.ps1`。真实 Store 注册测试 `Test-ClaudeRuntimeRegistration.ps1` 需要当前用户安装 Claude；仅验证注册、签名、绑定和撤销，不启动／停止 Claude 或服务。

`Test-ClaudeAuto.ps1` 的签名模拟仅作用于项目自己的有界休眠 Probe；未签名／其他签名者／签名错误的进程必须保持运行。任务测试以随机名称创建短期 SYSTEM 任务并在 finally 停止、删除，不操作正式 Claude 任务。Windows PowerShell 5.1 与 PowerShell 7 分别验证。`Test-ClaudeGate.ps1` 另验证保护目录、DOS 盘符启动解析、损坏清单、TLS 前退出及原值恢复。所有这些测试也必须串行运行。

## 证据分层

- 静态解析：支持级别、唯一定位、ABI 和指纹，不代表真实运行。
- 隔离行为：官方 Electron 和项目 Probe 的输出、回环网络请求、控制进程时间窗口。
- 实际部署：当前 Store 包的签名、IFEO、绑定与撤销快照。
- 实际运行：用户控制启动后的 Claude／服务诊断与自然上下文采样。

各层不能互相替代。CI 编译或非注册测试通过，不表示其他 Windows 版本的运行时已支持。原始日志可能包含本地程序路径；发布 issue 前检查并删去个人目录和账户数据。
