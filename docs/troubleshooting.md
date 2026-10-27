# 故障排查与恢复

先运行 `Manage-Claude.ps1 -Action Status`，保存 JSON 和完整错误。不要先删除恢复文件或把 IFEO 值清零。

| 现象 | 排查 |
|---|---|
| 找不到编译器、CMake、Ninja | 检查 C++ 工作负载、PATH、vswhere；参照构建文档传显式工具参数 |
| SDK 找不到 | 安装 `10.0.26100.0`，或明确选择已安装 SDK；不同 SDK 需要自行验证 ABI |
| 配置缺失 | 构建后运行 `Initialize-Config.ps1` |
| 初始化拒绝覆盖配置 | 已有文件会保留；备份并编辑部署 JSON，再运行校验器 |
| 找不到 Store 包 | 在实际安装 Claude 的同一用户会话运行；检查包身份和 x64 入口 |
| 签名不符合 | 查看 Valid 状态和签名者；主程序不符合会整批拒绝，不应关闭身份检查 |
| Access denied／注册拒绝 | 使用管理员 x64 PowerShell，检查已有调试／Verifier／过滤配置和安全产品事件记录；工具不自动停用系统防护 |
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

## 只读排查命令

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
.\scripts\Manage-Claude.ps1 -Action Status
.\out\build\x64-release\bin\CdfTimeRules64.exe --validate-config `
  (Join-Path $env:ProgramData 'ClaudeDesktopFake\stage2\timezone.json')
```

报告问题时附上版本、操作步骤、兼容级别、失败阶段和退出码；不要把“DLL 加载”当成 Hook 或采样通过。Native 信息类 93 的失败有独立契约说明，见 [Native-TimeZone-Class93.md](Native-TimeZone-Class93.md)。
