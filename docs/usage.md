# 使用与启停

## 首次使用

先按 [构建文档](build.md) 完成构建。在安装了 Microsoft Store 版 Claude 的同一 Windows 用户会话中打开管理员、64 位 PowerShell，切换到仓库根目录：

```powershell
.\scripts\Initialize-Config.ps1
.\scripts\Manage-Claude.ps1 -Action Enable
.\scripts\Manage-Claude.ps1 -Action Status
```

初始化工具校验仓库模板并创建部署配置。已有不同配置时拒绝覆盖；已有相同内容时幂等返回。可先运行 `Initialize-Config.ps1 -WhatIf` 查看结果。`Enable` 校验配置但不改写它。

然后由用户退出并重新启动 Claude。服务进程需要用户自行决定何时重启。工具不操作应用或服务生命周期。

## 三个命令

| 命令 | 权限 | 行为 |
|---|---|---|
| `Enable` | 管理员 x64 | 发现当前 Store 包、验签、生成身份清单和兼容绑定，事务写入 IFEO |
| `Status` | 只读；进程检查可能需要提升权限 | 显示目标、跳过项、过期状态、绑定、运行进程及待重启信息 |
| `Disable` | 管理员 x64 | 检查冲突并恢复原 IFEO 值、类型和存在状态 |

```powershell
.\scripts\Manage-Claude.ps1 -Action Disable
```

IFEO 仅影响之后启动的进程。Disable 不会卸载已运行进程中的 DLL；这些进程退出后才恢复基线。System32 DLL、不可变绑定与所有权记录按设计保留，便于核对和复用。

## Store 更新与 Provider 升级

Claude 更新后重新执行 `Enable`。工具重新发现安装目录并验签；不依赖含版本号的固定 WindowsApps 路径。支持的运行时会生成新绑定，过期的文件身份清单会刷新。没有重新 Enable 的新文件保持身份不匹配透传。

升级本项目 DLL 时先用原构建执行 `Disable`，再构建或替换 DLL，最后 `Enable`。有受管理映像时，工具拒绝替换共享 Provider。确认旧进程已退出后再替换被占用的文件。

## 身份边界

当前目标为包 `AnthropicPBC.Claude`、家族 `AnthropicPBC.Claude_fnn82j28hfe8t`、x64 应用入口。EXE 必须有有效 Authenticode 签名，签名者 SimpleName 与 `Anthropic, PBC` 忽略大小写完全相同。主程序不符合则整批拒绝；其他不符合项显示为跳过。证书指纹不固定，以允许正常证书轮换。

IFEO 按 EXE 文件名触发，同名其他程序也会加载门控 DLL。Provider 在握手时核对管理员清单中的路径、卷、File ID、大小和写入时间；不匹配时不启用虚拟化。运行时不在加载器锁下调用 WinVerifyTrust。

使用另一个管理员账号会读取那个账号的包注册，不能代替当前用户的 Store 注册。

## EXE 枚举目录

[config/claude-targets.json](../config/claude-targets.json) 默认枚举 `%CLAUDE_PACKAGE_ROOT%`、`%LOCALAPPDATA%\Claude-3p` 和 `%LOCALAPPDATA%\Packages`，按当前用户动态解析，覆盖 Store 重定向缓存中的 Code。可以修改目录列表；Store 主程序仍为必需目标，所有候选仍需有效的 `Anthropic, PBC` 签名和文件身份检查。

修改后执行 Enable 刷新身份清单，Status 的 `enumeration` 显示实际路径、哈希和是否待应用。已运行进程保留原快照。目录配置、增删与 Code 覆盖边界见 [targets.md](targets.md)。

## 配置编辑

在管理员 PowerShell 中备份并编辑已部署文件：

```powershell
$config = Join-Path $env:ProgramData 'ClaudeDesktopFake\stage2\timezone.json'
$backup = "$config.backup-$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item -LiteralPath $config -Destination $backup
notepad $config
.\out\build\x64-release\bin\CdfTimeRules64.exe --validate-config $config
.\scripts\Show-TimeConfig.ps1 -ConfigPath $config
```

校验成功后由用户重启目标进程，读取新的启动快照。配置格式见 [configuration.md](configuration.md)。若有通用测试映像正在使用共享部署，先完成其撤销；通用安装器会把未登记的配置改动视为外部冲突。

只切换时区时保持 `utcOffsetSeconds=0`；该值是额外的 UTC 时钟偏移，不要填写洛杉矶的 −25200／−28800。预览同时显示时钟偏移和自动计算的时区偏移，但不验证现有进程是否已生效。

## 只读诊断

```powershell
.\scripts\Capture-Runtime.ps1 -ProcessId 1234 -OutputPath '.\out\capture.json'
```

使用实际 PID。DLL、`.map` 和目标构建必须匹配。工具只读进程内诊断数据和补丁字节，不远程调用导出或创建线程。可选 JavaScript 采样需要配置 `captureEnabled=true`，并由用户启动新进程；未创建、未采到的上下文会如实报告。

## 通用 Probe

通用工具按文件名加载 `CdfTimeZone64.dll`，不进行 Claude 签名门控，适合自己的隔离测试映像：

```powershell
.\scripts\Manage-TimeZone.ps1 -Action Install -ImageName CdfTimeProbe64.exe `
  -DllPath '.\out\build\x64-release\bin\CdfTimeZone64.dll' `
  -ConfigPath '.\config\timezone.json'
.\scripts\Manage-TimeZone.ps1 -Action Status -ImageName CdfTimeProbe64.exe
.\scripts\Manage-TimeZone.ps1 -Action Uninstall -ImageName CdfTimeProbe64.exe
```

Electron 测试映像另传 `-ImagePath` 生成绑定，详见 [compatibility.md](compatibility.md)。纯加载实验使用 `Manage-Verifier.ps1` 和 `CdfBootstrap64.dll`。不要混用不同管理工具对同一映像建立恢复记录。

## 部署与恢复材料

| 位置 | 内容 |
|---|---|
| `%SystemRoot%/System32` | 已部署 Provider DLL |
| `%ProgramData%/ClaudeDesktopFake/stage2` | 时间配置、通用测试部署和恢复记录 |
| `%ProgramData%/ClaudeDesktopFake/stage3/claude` | Claude 身份清单、绑定、所有权、逐映像记录和事务材料 |

遇到 `Debugger`、已有 Verifier、路径过滤或外部值变化时停止覆盖。不要手工删除状态文件或把注册表值直接清零；先保留原始材料，再按 [troubleshooting.md](troubleshooting.md) 恢复。

如果注册值已经全部或部分回到恢复记录中的原值，但管理记录仍存在，先执行 `Disable` 完成状态核对与还原，再按需 `Enable`。撤销只接受精确的安装值或原值，其他改动仍视为冲突；详见 [IFEO 状态恢复](troubleshooting.md#ifeo-已恢复但启用记录仍存在)。
