# 故障排查与恢复

先运行 `Manage-Claude.ps1 -Action Status`，保存 JSON 和完整错误。不要先删除恢复文件或把 IFEO 值清零。

| 现象 | 排查 |
|---|---|
| 找不到编译器、CMake、Ninja | 检查 C++ 工作负载、PATH、vswhere；参照构建文档传显式工具参数 |
| SDK 找不到 | 安装 `10.0.26100.0`，或明确选择已安装 SDK；不同 SDK 需要自行验证 ABI |
| 配置缺失 | 构建后运行 `Initialize-Config.ps1` |
| 初始化拒绝覆盖配置 | 已有文件会保留；备份并编辑部署 JSON，再运行校验器 |
| 洛杉矶配置搭配 `utcOffsetSeconds=0` 是否错误 | 正确。该值是额外的 UTC 时钟偏移；UTC−7／UTC−8 由 Windows 时区和日期自动计算，使用 `Show-TimeConfig.ps1` 分别查看 |
| 本地时间多差了 7／8 小时 | 检查是否将时区偏移 −25200／−28800 填进 `utcOffsetSeconds`；只切换时区应使用 0，恢复前先预览配置 |
| 找不到 Store 包 | 在实际安装 Claude 的同一用户会话运行；检查包身份和 x64 入口 |
| Code DLL 已加载但 `image-not-listed` | 检查 `config/claude-targets.json` 是否包含 Code 所在目录，重新 Enable 验签登记后，由用户重启对应进程；目录存在不等于文件已登记 |
| `enumeration.changed`／`refreshRequired` | 查看展开目录和配置错误；配置有效后重新 Enable，不手工改身份清单 |
| 签名不符合 | 查看 Valid 状态和签名者；主程序不符合会整批拒绝，不应关闭身份检查 |
| Access denied／注册拒绝 | 使用管理员 x64 PowerShell，检查已有调试／Verifier／过滤配置和安全产品事件记录；工具不自动停用系统防护 |
| PowerShell 5.1 报长目录不存在 | 更新枚举脚本；扩展路径访问已兼容超过 MAX_PATH 的目录，无需修改系统长路径策略。真正消失的临时目录会记录 `directory-disappeared`，权限错误仍会中止 |
| WindowsApps 扫描过慢 | 将目录改为 `%ProgramFiles%\\WindowsApps\\AnthropicPBC.Claude_*`，不要同时保留无筛选的父目录规则；匹配后仍需逐文件验签 |
| `catalogue-build-mismatch` | JSON 与解析器不是同一构建，重新构建并保持 DLL、解析器和档案一致 |
| `unsupported-windows-build` | 当前运行时分支只支持 build 19045 |
| `missing-site`／`ambiguous-site`／`abi-mismatch` | 不满足已验证 ABI，保留兼容报告，不能仅添加版本号或短序言放行 |
| `capture-unavailable` | 核心与采样独立校验；44.8.0 可使用核心，不能宣称采样就绪 |
| `unsupported-symbols` | 检查匹配 GUID/Age、本机 DIA SDK／COM 注册或 `CDF_DIA_DLL`；普通分析不要求 PDB |
| `binding-invalid`／`binding-stale` | 检查绑定哈希、文件版本和档案；没有外部冲突时重新 Enable |
| DLL／绑定被外部修改 | 停止覆盖，保留日志、状态和备份，确定改动来源后恢复记录期望的原文件 |
| 状态提示重启 | 已运行进程仍持有启动快照；用户自行退出再启动，服务自行安排重启 |
| Disable 后 DLL 文件仍在 | 按所有权设计保留，注册已撤销不等于删除文件或卸载现有进程 |

## 中断恢复

`deployment-pending.json` 与 `recovery.<id>` 是写前事务材料。中断后用管理该映像的同一个工具执行 `Disable` 或 `Uninstall`。工具预检注册值和文件哈希，恢复原存在状态、类型和值；外部冲突会停止并保留材料。

存在冲突时不要使用另一套版本的脚本覆盖记录，不要直接删除 System32 DLL、状态目录或绑定。先保存材料，比较记录中的 old/new 哈希与实际文件，确认哪些改动属于本工具。应用仍运行并持有 DLL 时，先按自己的维护安排退出进程。

## IFEO 已恢复，但启用记录仍存在

如果 `Enable` 报 `External IFEO conflict ... recovery records retained`，而 `Status` 显示 `managed=true`、`enabled=false`，先保留状态目录并检查各映像的注册值。使用同一套管理脚本执行：

```powershell
.\scripts\Manage-Claude.ps1 -Action Disable
.\scripts\Manage-Claude.ps1 -Action Status
.\scripts\Manage-Claude.ps1 -Action Enable
```

`Disable` 会对整批映像预检：每个值必须与本工具安装的值或恢复记录中的原值完全一致，包括存在状态、注册表类型和数据。全部或部分值已经恢复时，工具完成剩余还原并清理管理记录；事务失败或中断时，回滚到这次撤销开始前的实际状态，不会重新创建原本已缺失的值。

出现第三种值、类型变化、Debugger、UseFilter、路径过滤子键或部署文件哈希冲突时，仍停止整批操作并保留恢复材料。不要用删除状态文件的方式绕过检查。`Enable` 保持严格检查，不会直接覆盖被移除或改动的注册配置。

重新启用后，由用户退出并重启 Claude；服务的重启也由用户安排。工具不会卸载既有进程中的 Provider。

## 只读排查命令

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
.\scripts\Manage-Claude.ps1 -Action Status
.\out\build\x64-release\bin\CdfTimeRules64.exe --validate-config `
  (Join-Path $env:ProgramData 'ClaudeDesktopFake\stage2\timezone.json')
```

报告问题时附上版本、操作步骤、兼容级别、失败阶段和退出码；不要把“DLL 加载”当成 Hook 或采样通过。Native 信息类 93 的失败有独立契约说明，见 [Native-TimeZone-Class93.md](Native-TimeZone-Class93.md)。
