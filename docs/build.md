# 构建

## 环境

- Windows x64、64 位 PowerShell 7。
- Visual Studio 2022 或 Build Tools，安装“使用 C++ 的桌面开发”、MSVC x64 工具和 CMake/Ninja 工具。
- Windows SDK `10.0.26100.0`。
- CMake 3.24+、Python 3.10+。Python 生成器只使用标准库。
- DIA SDK 可选，仅用于 `-SymbolsPath` 的本地 PDB 校验。没有 DIA 时，普通二进制兼容分析仍可构建和使用。

构建不需要管理员权限。当前运行时支持范围是 Windows build 19045；在其他 Windows 上完成编译不等于运行时兼容验收。

## 默认构建

在仓库根目录的 PowerShell 中执行：

```powershell
.\scripts\Build.ps1
```

脚本通过 `vswhere` 或已初始化的开发者环境发现 Visual Studio，导入 x64 环境，优先使用 PATH 中的 CMake/Ninja，再查找 Visual Studio 自带工具。默认使用 Ninja、MSVC、x64 Release、16 线程，输出到 `out/build/x64-release`。

```powershell
.\scripts\Build.ps1 -Parallel 8
```

若工具未被注册，可传入本机实际路径：`-CMakePath`、`-NinjaPath`、`-VisualStudioPath` 或 `-VcvarsPath`。也可设置 `CDF_CMAKE`、`CDF_NINJA`、`CDF_VS_INSTALLATION`、`CDF_VCVARS64` 环境变量。路径只属于本地环境，不应写回仓库 preset。

`-WindowsSdkVersion` 可选择其他已安装 SDK；此选项不会自动扩大经过验收的 SDK、Native ABI 或 Windows 版本范围。

在已初始化的 x64 Developer PowerShell 中，且 CMake/Ninja 都在 PATH 时，也可直接执行：

```powershell
cmake --preset x64-release
cmake --build --preset x64-release
```

本地专用配置可放进已忽略的 `CMakeUserPresets.json`。

## 主要产物

都位于 `out/build/x64-release/bin`：

| 文件 | 用途 |
|---|---|
| `CdfClaudeTimeZone64.dll` | Claude 签名与文件身份门控 Provider |
| `CdfTimeZone64.dll` | 通用测试 Provider，不进行 Claude 身份筛选 |
| `CdfBootstrap64.dll` | 纯 Verifier 握手加载探针 |
| `CdfRuntimeResolve64.exe` | 离线兼容解析器 |
| `CdfTimeRules64.exe` | 配置校验器和时间规则测试 |
| `Cdf*Probe64.exe`、辅助 DLL、`.node` | 隔离测试程序 |
| 同名 `.map` | 与对应 DLL 匹配的只读进程诊断布局 |

生产 Provider 无 CRT，静态导入仅 `ntdll.dll`。分析工具和 Probe 使用普通运行库。保留 DLL 与对应 `.map`，不要把不同构建的文件混用。

## 可选符号校验

CMake 从当前 VS 安装发现 `dia2.h`；缺失时会提示关闭可选符号支持。脚本在指定 `-SymbolsPath` 时发现当前 VS 的 x64 DIA DLL，也可由 `CDF_DIA_DLL` 指定；直接调用解析器可传 `--dia-library`。不指定 DLL 时尝试已注册的 DIA COM 类。普通兼容分析不加载 DIA，也不下载符号。

## 生成器

- `Compile-RuntimeCatalog.py`：正常构建自动调用，从统一档案生成静态表。
- `Generate-WindowsIana.py`：从随库 CLDR 48 数据生成 Windows→IANA 表。
- `Generate-WinRtAbi.py`：从本机 SDK 的接口声明生成 WinRT 表和转发汇编。自动读取 SDK 环境或注册信息，也接受 `--sdk-root`、`--sdk-version`。通常无需重生成；修改 SDK 后必须审查生成差异和 ABI。

测试分级和管理员集成测试准备见 [testing.md](testing.md)。
