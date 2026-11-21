# 第一步 · Verifier 加载原型

[返回文档索引](README.md)

第一步用自有 Probe 验证 Windows x64 Application Verifier 的加载时序。`CdfBootstrap64.dll` 交付一个空描述表，并记录握手和进程附加状态。测试只检查加载与状态，时间、区域语言和网络组件分别由后续阶段负责。

## 产物和状态

| 产物 | 用途 |
| --- | --- |
| `CdfBootstrap64.dll` | 独立的空 Provider，自定义入口，无 CRT 和 PE 导入依赖 |
| `CdfProbe64.exe` | 在 TLS 回调和 main 阶段记录模块、握手、实际 Verifier 标志和进程附加状态 |
| `CdfBootstrap64.map` | 对应构建的符号和诊断定位 |

[`include/verifier_abi.h`](../include/verifier_abi.h) 集中定义并在编译时核对 x64 描述符布局。入口收到 Windows 的 Verifier 请求后返回 80 字节静态描述符。描述表只有结束项。模块、卸载和堆回调为空。

| 导出 | 返回值 |
| --- | --- |
| `CdfBootstrapQueryState` | `0x1` 表示收到 Verifier 握手，`0x2` 表示收到进程附加。完整状态为 `0x3` |
| `CdfBootstrapQueryVerifierFlags` | 读取描述符中由 Windows 设置的实际标志 |

## 验收记录

该轮在 Windows x64 build 19045 完成。加载失败日志记录了本机加载器对任意位置 DLL 的限制，以及零配置标志回落到内置检查的现象。预期状态以 Probe 实际读取为准。仅在进程模块表找到 DLL 还需核对握手状态和加载路径。

- `build_inspection` 检查 PE 架构、入口、导出、依赖和符号。
- `configuration_safety` 检查同名部署所有权、记录原类型和数据以及外部冲突。
- `verifier_load_integration` 使用两个自有测试文件名，核对未注册基线、TLS／main、重复启动、撤销及基线恢复。

报告位于 `out/build/x64-release/test-results`，对应 `build-inspection.json`、`configuration-safety.json` 和 `verifier-load.json`。加载诊断写入 `out/diagnostics`。涉及注册的用例需要专用测试环境并串行运行。[构建与验证](build.md#验证)

## 冲突与撤销

第一步的所有权、哈希和逐映像原值保存在 `%ProgramData%\ClaudeDesktopFake\stage1`。恢复前核对当前值、预期值和原值，冲突时保留材料。退出码 `0xC0000142` 需结合加载器日志和构建匹配情况判断。构建、加载及诊断在其他 Windows 版本上的行为以对应平台实测为准。
