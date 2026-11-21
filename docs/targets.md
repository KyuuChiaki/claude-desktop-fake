# Store 包与附加目标目录

[返回文档索引](README.md)

[`config/claude-targets.json`](../config/claude-targets.json) 定义发现候选文件的范围。身份记录按具体文件生成。配置时间、格式和语言请参阅[时间与区域配置](time-configuration.md)。

## 默认范围

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

`%CLAUDE_PACKAGE_ROOT%` 指**当前用户已注册的 Microsoft Store 版 Claude**的包目录，包含当前应用入口。`WindowsApps` 中的目录模式先选择名称符合 `AnthropicPBC.Claude_*` 的第一层目录，再扫描其中的 EXE。它可以发现同时存在的多个 Store 版本。匹配目录名与验证文件身份是两步。每个文件仍检查 AMD64、有效 Authenticode、发布者名称及文件身份。

| 变量 | 来源 |
| --- | --- |
| `%CLAUDE_PACKAGE_ROOT%` | 当前用户注册的 Store 包路径及入口 |
| `%LOCALAPPDATA%` | 当前用户的 LocalApplicationData |
| `%APPDATA%` | 当前用户的 ApplicationData |
| `%USERPROFILE%` | 当前用户的 UserProfile |
| `%PROGRAMDATA%` | 机器的 CommonApplicationData |
| `%ProgramFiles%` | 64 位管理进程看到的 ProgramFiles |

变量名忽略大小写。已知文件夹从 Windows 解析，路径随账户和安装位置变化。LocalSystem 后台沿用安装时记录的用户目录。其他盘上的 Store 应用库可用对应的明确目录或等价的末级模式表示。

## 配置格式

- 文件为 schema 1 JSON，上限 16 KiB，包含 1 至 16 个目录条目，须包含当前 Store 包根。证据清单最多保存 64 个映像和 64 KiB 数据。
- JSON 中每个反斜杠写成 `\\`。固定目录应为盘符开头的绝对目录。相对路径、UNC、整卷根目录和未知变量会被拒绝。
- `*` 与 `?` 只匹配最后一级目录名，忽略大小写。模式父目录中的文件不属于该模式。优先使用带 `AnthropicPBC.Claude_*` 的规则，避免扫描整个 `WindowsApps`。
- 重叠目录去重。扫描不跟随目录联接或符号链接，并支持深层目录。临时目录消失时记录 `directory-disappeared`，未找到匹配目录时记录 `folder-pattern-no-match`。其余读入错误见相应状态。[Windows 路径长度说明](https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation)

## 核对发现与登记

```powershell
$status = .\scripts\Manage-Claude.ps1 -Action Status | ConvertFrom-Json
$status.enumeration
$status.running |
    Select-Object pid, listed, inEnumeration, requiresEnable, requiresRestart
```

| 字段 | 用途 |
| --- | --- |
| `enumeration.configurationPath` | 当前用于检查的策略文件 |
| `enumeration.sha256`、`registeredSha256`、`changed` | 当前配置哈希、所登记的配置哈希及二者是否有变化 |
| `enumeration.directories[]` | 原始模板、展开路径、存在状态和可选的 `folderNamePattern` |
| `refreshRequired` | 策略、文件身份或运行候选出现需要重新核对的变化 |
| `running[].listed`、`inEnumeration` | 运行文件对应的登记与发现范围 |
| `running[].path`、`resolvedImagePath` | 操作系统所报路径与按实际映像身份核对出的路径 |
| `running[].requiresEnable`、`requiresRestart` | 登记或已运行快照需要更新 |

同名 EXE 可以来自不同目录和版本。发现范围、当前文件身份和进程内快照需要分别核对。后台使用自己的已部署发布快照，工作树中的配置发生变化时可对照状态中的哈希。有关运行中进程和全新文件名的诊断，见[自动刷新与启动诊断](automatic-refresh.md)。

## Claude Code 和共享子程序

Desktop 下载的 Claude Code 可能位于 `%LOCALAPPDATA%\Claude-3p\claude-code\<version>\<hash>\claude.exe`，也可能位于 `%LOCALAPPDATA%\Packages\<包家族目录>\LocalCache\Roaming\Claude\claude-code`。包内与包外查看得到的路径可能不同，可用 `resolvedImagePath` 检查当前记录。新版本或替换文件需要重新核实。Electron 适配结果只说明相应 Electron 构建，Claude Code 内部的 Date、Intl、语言和网络行为需独立验收。

共享 `ssh.exe` 和 `node.exe` 由单独的[子程序观察清单](../config/claude-network-children.json)管理。状态以实际 Claude 祖先关系判断归属。[网络子程序与归属](Network-Proxy.md#claude-启动的外部网络工具)
