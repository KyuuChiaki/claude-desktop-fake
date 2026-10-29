# 可配置的 EXE 枚举目录

`Manage-Claude.ps1` 从当前项目的 [config/claude-targets.json](../config/claude-targets.json) 读取枚举策略。时间／区域配置仍使用原有部署 JSON，两份配置各自负责不同用途。

默认内容：

```json
{
  "schemaVersion": 1,
  "imageDirectories": [
    "%CLAUDE_PACKAGE_ROOT%",
    "%LOCALAPPDATA%\\Claude-3p",
    "%LOCALAPPDATA%\\Packages"
  ]
}
```

工具递归枚举各目录中的 EXE。每个候选仍须通过有效 Authenticode、`Anthropic, PBC` 签名者、AMD64 架构和验签前后文件身份一致性检查。Store 主程序必须通过，其他候选不符合条件时跳过并报告。

## 变量与路径

| 变量 | 解析来源 |
|---|---|
| `%CLAUDE_PACKAGE_ROOT%` | 当前用户注册的 Claude Store 包，核对包身份及入口后获得 |
| `%LOCALAPPDATA%` | 当前 Windows 用户的 LocalApplicationData 已知文件夹 |
| `%APPDATA%` | 当前用户的 ApplicationData 已知文件夹 |
| `%USERPROFILE%` | 当前用户的 UserProfile 已知文件夹 |
| `%PROGRAMDATA%` | CommonApplicationData 已知文件夹 |

变量名称忽略大小写。用户目录通过 Windows 已知文件夹 API 取得，无需写入用户名，也不依赖拼接用户目录名称。应在安装 Store 包的同一用户会话中使用管理员终端；切换管理员账号会解析另一个用户的目录和包注册。

允许使用明确的盘符绝对目录。JSON 中的反斜杠须写成 `\\`。不接受相对路径、UNC、通配符、整卷根目录或未知变量。配置上限 16 KiB、1 至 16 项；重复目录忽略大小写去重，必须保留 Store 包根目录。

不存在的附加目录会显示 `exists=false`，不会导致首次安装失败。枚举不跟随目录联接、符号链接等重解析点；跳过项会记录原因。读取目录失败会停止启用，避免把不完整枚举结果当成完整清单。

## 编辑并应用

在管理当前部署的同一个项目目录中编辑配置，再执行：

```powershell
.\scripts\Manage-Claude.ps1 -Action Enable
.\scripts\Manage-Claude.ps1 -Action Status
```

`Enable` 会重新枚举和验签，事务更新身份清单。它不会覆盖时间／区域 JSON，也不会重启程序。Source DLL 未变化时，无需先 Disable 或重新编译。Provider 版本升级仍须先 Disable。

不同目录或版本中同名的 EXE 各自拥有文件身份记录，共享按文件名设置的 IFEO 及首次恢复记录。移除目录并重新 Enable 后，后续新进程中的旧文件身份失效；不再使用的映像名按记录恢复。既有进程保留启动时快照，由用户决定退出和重启时间。

配置路径和内容哈希记录在管理状态中。配置损坏或变化时，Disable 仍按原有恢复材料撤销；Status 可以同时报告配置问题。

## Status 字段

- `enumeration.configurationPath`：当前策略文件。
- `enumeration.sha256`／`registeredSha256`：当前内容及上次 Enable 记录的哈希。
- `enumeration.changed`：策略已修改，尚未通过 Enable 应用。
- `enumeration.directories`：原始模板、展开后的路径和是否存在。
- `refreshRequired`：策略／文件身份变化，或枚举目录内出现未登记的运行候选。
- `running[].listed`／`inEnumeration`：进程是否已在清单中、是否位于当前枚举目录。
- `running[].requiresEnable`／`requiresRestart`：候选需要重新验签登记，或运行快照需要用户重启。

同名清单外程序也可能因 IFEO 加载 Provider；身份不匹配时保持透传。状态检查包含相关同名进程，以便发现需要退出的旧运行快照。

## Claude Code 的覆盖边界

默认附加目录包含 Desktop 下载的 Code 版本，例如 `%LOCALAPPDATA%\Claude-3p\claude-code\<version>\<hash>\claude.exe`。新版本或替换文件需要再次 Enable；文件夹在枚举范围内并不等于已登记。

`%LOCALAPPDATA%\Packages` 递归覆盖当前用户的 Store 包数据目录，包括 `%LOCALAPPDATA%\Packages\AnthropicPBC.Claude_fnn82j28hfe8t\LocalCache\Roaming\Claude\claude-code`。Store 进程可能把这里的映像显示为 `%APPDATA%\Claude\claude-code`，而管理工具在包外访问时须登记实际缓存文件。无需固定 Code 版本或哈希子目录，也无需写入用户名。

Packages 内其他程序也会被枚举，但只有通过既有 Anthropic 签名与文件身份检查的 EXE 才纳入清单；该目录不是全体程序的 Hook 白名单。目录较大时枚举和验签会更久，重解析点及读取失败仍按上述规则处理。

纳入文件身份后，可使用已启用的 Windows 时间／区域 Hook。Claude Code 内部 JavaScript 运行时的 Date、Intl、语言及网络行为仍须单独验收，不能用 Electron 的适配记录或 DLL 已加载代替。schema 2 不启用专门的运行时扩展。
