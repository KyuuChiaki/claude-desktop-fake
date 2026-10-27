# 兼容性与边界

## 当前范围

版本 0.6.0 的运行时适配限定 Windows build 19045、AMD64。时区、格式区域、UI 语言、国家地区分别配置。版本号只是测试输入和报告信息，不能单独证明二进制兼容。

| 隔离运行时 | 核心行为矩阵 | 可选自然上下文采样 |
|---|---|---|
| Electron 44.9.3 x64 | 通过 | 支持 |
| Electron 44.9.2 x64 | 通过，ABI 自动解析 | 支持 |
| Electron 44.8.0 x64 | 通过，ABI 自动解析 | 不完整；要求采样会拒绝 |

这些是 0.6.0 参考环境的结果，不表示任意未来 Electron 或 Windows 版本都支持。真实 Claude 的包注册验证与实际运行时证据分别记录，见 [validation.md](validation.md)。

## 分级匹配

唯一档案是 [profiles/runtime-adapters.json](../profiles/runtime-adapters.json)。构建生成 C++ 静态表，离线解析器与生产 DLL 使用同一校验核心。PowerShell 核对编译档案与 JSON 的哈希一致。

1. `exact-image`：完整 SHA-256 命中，并复核函数。
2. `same-engine`：代码、相关数据和布局指纹一致，允许明确声明的打包差异。
3. `abi-resolved`：完整函数模板、边界、字段、调用关系、关键常量全部匹配，必需角色唯一定位。
4. 证据不足、定位缺失或歧义：不安装内部补丁。

`CDFENGINE1` 纳入除资源节外的节名、布局、属性与内容；仅规范化已知 fuse 状态和资源导致的重定位节放置差异。其余只读数据、导入、展开信息和重定位内容仍参与指纹。完整映像由绑定中的 SHA-256 固定。

十四种角色统一维护补丁、Node navigator 调用点、字符串构造和 V8 采样辅助地址。ABI 桥接编译进 Provider；绑定不能带入可执行代码。新增同 ABI 构建可离线生成绑定，无需修改桥接。新指令模板需审查和重建，新 ABI 必须先实现、验收再发布。

## 只读分析

准备官方测试映像后：

```powershell
.\scripts\Prepare-RuntimeFixture.ps1 -Version 44.9.2
$image = (Resolve-Path '.\out\runtime-fixtures\electron-44.9.2\CdfElectronProbe64.exe').Path
.\scripts\Test-RuntimeCompatibility.ps1 -ImagePath $image -OutputPath '.\out\compatibility.json'
.\scripts\Test-RuntimeCompatibility.ps1 -ImagePath $image -RequireCapture
```

分析不修改 IFEO，不启动目标映像。可选 `-SymbolsPath` 只接受匹配 GUID/Age 的本地 PDB；符号不能代替二进制校验。正常分析和启动不访问符号服务器。

解析器也可直接运行：

```powershell
.\out\build\x64-release\bin\CdfRuntimeResolve64.exe --image $image
```

报告包括匹配来源、完整映像与运行时指纹、ABI、档案、角色地址、采样准备状态和失败原因。退出 0 为支持，1 为不支持，2 为命令行参数错误。

## 绑定与启动复核

`Enable` 重新发现包、验签和读取文件身份，先离线解析，再将 944 字节绑定以内容 SHA-256 命名保存。身份清单引用绑定，和 IFEO、所有权、恢复记录一起事务提交。默认 block 会在注册前拒绝不支持的目标。

Provider 先进行身份门控，再复核绑定、磁盘映像、整组函数和已映射代码，检查保护、CFG、CET 与展开边界，在应用 TLS 前安装。失败整组回滚，然后执行 block 或整套 passthrough。大映像的完整校验有启动成本和临时缓冲占用。

通用 Electron Probe 需指定映像以生成绑定：

```powershell
.\scripts\Manage-TimeZone.ps1 -Action Install -ImageName CdfElectronProbe64.exe `
  -DllPath '.\out\build\x64-release\bin\CdfTimeZone64.dll' `
  -ConfigPath '.\config\timezone.json' -ImagePath $image
.\scripts\Manage-TimeZone.ps1 -Action Uninstall -ImageName CdfElectronProbe64.exe
```

此通用工具无 Claude 身份筛选，仅用于自己的隔离测试。

## 覆盖保证

覆盖验收中的 Native／Win32 时间和区域接口、UCRT 路径，以及登记 ABI 的 ICU/V8/Electron、WinRT 默认语言和格式化、独立 Geo 查询与 Chromium 默认网络语言。显式 Locale、时区、语言、格式、会话和请求头优先。

直接 syscall、直接共享页读取、自定义私有时间源、未登记 ABI、其他 Windows 版本、资源文本翻译、ACP/OEMCP、输入法、IP 地理位置及虚拟机内部环境不在保证内。修改语言标识不等于安装或翻译语言资源。UI、网络和格式化的真实应用证据必须由对应进程采集，不能用隔离 Electron 结果替代。
