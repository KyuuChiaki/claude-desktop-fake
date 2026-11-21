# 第六步 · 跨版本适配

[返回文档索引](README.md)

0.6.0 将本机兼容分析、运行时档案和绑定复核汇集到同一套规则。当前实现针对 Windows 10 build 19045、AMD64。以实际文件和 ABI 校验判断兼容性。

## 离线分析

构建 `CdfRuntimeResolve64.exe` 后，在仓库根目录运行。报告检查映像文件，适合在应用更新后重新确认。

```powershell
$imagePath = Read-Host '待检查的 EXE 文件路径'
.\scripts\Test-RuntimeCompatibility.ps1 -ImagePath $imagePath -OutputPath .\compatibility.json
.\scripts\Test-RuntimeCompatibility.ps1 -ImagePath $imagePath -RequireCapture
```

提供 `-SymbolsPath` 时，工具使用可用的 DIA 组件核对本地 PDB 的 GUID／Age，然后继续验证二进制规则。DIA 会从 Visual Studio 安装中查找，也可通过 `CDF_DIA_DLL` 指定机器上的组件。常规分析只需要磁盘映像，离线完成。

## 匹配来源

| 等级 | 判定依据 |
| --- | --- |
| `exact-image` | 完整映像 SHA-256 匹配登记，继续复核布局与角色 |
| `same-engine` | 规范化后的运行时指纹一致，差异在档案允许范围 |
| `abi-resolved` | 已实现 ABI 的布局、函数模板和调用关系成立，必需角色均唯一定位 |

[`profiles/runtime-adapters.json`](../profiles/runtime-adapters.json) 是维护来源。构建工具生成 C++ 静态档案，分析器与 Provider 核对同一档案修订和哈希。运行时指纹保留与加载和 ABI 相关的代码、布局、导入、展开和重定位信息。只规范化档案允许的打包差异。版本号与符号可用于对照报告，兼容性仍需全部二进制证据。

核心适配和可选采样独立检查。核心兼容而采样缺失时，`-RequireCapture` 会返回 `capture-unavailable`。历史样本中 Electron 44.8.0 满足核心规则，采样入口不完整。[参考环境与验收](validation.md)

## 绑定与现场诊断

绑定文件使用 944 字节版本化结构，记下映像及档案哈希、ABI、定位结果和采样准备状态。文件以内容 SHA-256 命名。启动时按文件身份和所管绑定复核完整映像、核心角色、内存代码及页面保护要求。错误触发整组回滚和配置的兼容策略。

schema 3 的 `runtime.enabled` 决定是否采用运行时适配。`block` 用于已登记并匹配身份的管理进程，适配失败退出码为 `0xE0CDF501`。`passthrough` 对应整套恢复原行为。清单外同名文件的行为由其身份判定与当前[启动范围](automatic-refresh.md#启动前保护的范围)决定。

```powershell
$status = .\scripts\Manage-Claude.ps1 -Action Status | ConvertFrom-Json
$status.runtime
```

`CdfRuntimeQueryCompatibilityStatus` 版本 1，552 字节，报告匹配来源、ABI、档案修订、绑定哈希和功能准备状态。`Capture-Runtime.ps1` 可在匹配 DLL 和 map 时读取已有进程诊断。[采样说明](Stage5-Runtime.md#可选采样)

| 分类 | 应核对 |
| --- | --- |
| `invalid-pe`、`unsupported-windows-build`、`unknown-fingerprint` | PE 架构、当前 Windows 构建和运行时档案 |
| `missing-site`、`ambiguous-site`、`abi-mismatch`、`invalid-fuse` | 定位证据、ABI 布局和可规范化的打包差异 |
| `binding-missing`、`binding-invalid`、`binding-stale`、`mapped-code-changed` | 绑定、档案、磁盘映像与现场进程 |
| `capture-unavailable`、`unsupported-symbols` | 采样入口及可选的本地符号检查 |
| 诊断阶段 12／14／15 | 写入与回滚、保护条件与绑定复核 |

通过静态分析表示当前文件符合某项规则。实际 Store 登记、功能就绪和真实应用行为需要从各自结果确认。
