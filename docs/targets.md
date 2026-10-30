# 可配置的 EXE 枚举目录

`Manage-Claude.ps1` 从当前项目的 [config/claude-targets.json](../config/claude-targets.json) 读取枚举策略。时间／区域配置仍使用原有部署 JSON，两份配置各自负责不同用途。

默认内容：

```json
{
  "schemaVersion": 1,
  "imageDirectories": [
    "%CLAUDE_PACKAGE_ROOT%",
    "%LOCALAPPDATA%\\Claude-3p",
    "%LOCALAPPDATA%\\Packages",
    "%ProgramFiles%\\WindowsApps\\AnthropicPBC.Claude_*"
  ]
}
```

工具递归枚举各目录中的 EXE。每个候选仍须通过有效 Authenticode、`Anthropic, PBC` 签名者、AMD64 架构和验签前后文件身份一致性检查。Store 主程序必须通过，其他候选不符合条件时跳过并报告。

`%ProgramFiles%\WindowsApps\AnthropicPBC.Claude_*` 在默认 Store 安装目录中，先按名称选择 Claude 的一级版本目录，再递归扫描这些目录。默认安装位置通常为 `C:\Program Files\WindowsApps`；其他 Store 应用不会被递归扫描。模式不固定架构或发布者 ID 后缀，EXE 的架构与签名仍单独校验。可在同一次 Enable 中发现并存的 Claude 版本，包括已下载但尚未成为当前用户注册版本的安装目录。`%CLAUDE_PACKAGE_ROOT%` 仍用于定位和校验当前注册主程序，必须保留。其他盘符的独立应用库需单独添加同类规则。

新增目录只是扩大候选扫描范围。编辑配置或 Store 下载新版本后，仍需手动执行 Enable，将验签通过的具体文件身份写入清单；目录中的全部程序不会因此自动启用 Hook。现有 64 条已验证映像及 64 KiB 清单限制继续生效。

## 变量与路径

| 变量 | 解析来源 |
|---|---|
| `%CLAUDE_PACKAGE_ROOT%` | 当前用户注册的 Claude Store 包，核对包身份及入口后获得 |
| `%LOCALAPPDATA%` | 当前 Windows 用户的 LocalApplicationData 已知文件夹 |
| `%APPDATA%` | 当前用户的 ApplicationData 已知文件夹 |
| `%USERPROFILE%` | 当前用户的 UserProfile 已知文件夹 |
| `%PROGRAMDATA%` | CommonApplicationData 已知文件夹 |
| `%ProgramFiles%` | 64 位管理进程的 ProgramFiles 已知文件夹，不使用 ProgramFiles (x86) |

变量名称忽略大小写。用户目录与 Program Files 通过 Windows 已知文件夹 API 取得，不信任进程环境变量的临时覆盖；无需写入用户名或系统盘盘符。应在安装 Store 包的同一用户会话中使用管理员、64 位终端；切换管理员账号会解析另一个用户的目录和包注册。

允许使用明确的盘符绝对目录。JSON 中的反斜杠须写成 `\\`。配置上限 16 KiB、1 至 16 项；重复规则忽略大小写去重，必须保留 Store 包根目录。不接受相对路径、UNC、整卷根目录或未知变量。

名称模式只允许在**最后一级目录名**中使用 `*`（任意长度）与 `?`（单个字符），匹配忽略大小写。不支持中间层通配符、`**` 跨层递归或字符类。模式匹配的是目录名，父目录中的 EXE 不会当作匹配目录；选中目录后，内部子目录按原规则递归。例如：

```json
"%ProgramFiles%\\WindowsApps\\AnthropicPBC.Claude_*"
```

不要同时保留无筛选的 `%ProgramFiles%\\WindowsApps`，否则该普通目录规则仍会扫描全部子目录。普通目录字符串继续兼容。目录模式重叠时，同一路径不会重复扫描；没有匹配目录时记录 `folder-pattern-no-match`。

不存在的附加目录会显示 `exists=false`。枚举不跟随目录联接、符号链接等重解析点；跳过项记录原因。扫描时使用扩展路径，支持 Windows PowerShell 5.1 遍历超过 MAX_PATH 的目录，不要求修改系统 LongPathsEnabled，规则见 [Microsoft 路径长度说明](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)。排队后的临时目录消失会记录 `directory-disappeared` 并继续；权限拒绝等其他读取错误仍停止启用。必需的 Store 主程序缺失始终拒绝启用。

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
- `enumeration.directories[].folderNamePattern`：可选的一级子目录名称模式；`path` 为筛选父目录，Status 的范围判定应用相同模式。
- `refreshRequired`：策略／文件身份变化，或枚举目录内出现未登记的运行候选。
- `running[].listed`／`inEnumeration`：进程是否已在清单中、是否位于当前枚举目录。
- `running[].path`／`resolvedImagePath`：系统报告路径与经 Provider Native 路径核对后的实际清单路径；支持 Store 缓存重定向，避免误报已就绪进程需要重启。
- `running[].requiresEnable`／`requiresRestart`：候选需要重新验签登记，或运行快照需要用户重启。

同名清单外程序也可能因 IFEO 加载 Provider；身份不匹配时保持透传。状态检查包含相关同名进程，以便发现需要退出的旧运行快照。

## Claude Code 的覆盖边界

默认附加目录包含 Desktop 下载的 Code 版本，例如 `%LOCALAPPDATA%\Claude-3p\claude-code\<version>\<hash>\claude.exe`。新版本或替换文件需要再次 Enable；文件夹在枚举范围内并不等于已登记。

`%LOCALAPPDATA%\Packages` 递归覆盖当前用户的 Store 包数据目录，包括 `%LOCALAPPDATA%\Packages\AnthropicPBC.Claude_fnn82j28hfe8t\LocalCache\Roaming\Claude\claude-code`。Store 进程可能把这里的映像显示为 `%APPDATA%\Claude\claude-code`，而管理工具在包外访问时须登记实际缓存文件。无需固定 Code 版本或哈希子目录，也无需写入用户名。

Packages 内其他程序也会被枚举，但只有通过既有 Anthropic 签名与文件身份检查的 EXE 才纳入清单；该目录不是全体程序的 Hook 白名单。目录较大时枚举和验签会更久，重解析点及读取失败仍按上述规则处理。

纳入文件身份后，可使用已启用的 Windows 时间／区域 Hook。Claude Code 内部 JavaScript 运行时的 Date、Intl、语言及网络行为仍须单独验收，不能用 Electron 的适配记录或 DLL 已加载代替。schema 2 不启用专门的运行时扩展。
