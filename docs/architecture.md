# 实现结构

```text
Manage-Claude
  -> Store 包发现 / Authenticode / 文件身份
  -> CdfRuntimeResolve64 + 统一档案
  -> 身份清单 + 内容寻址绑定 + IFEO 事务
  -> 新进程 Verifier 握手
       -> 身份不匹配: 空描述表透传
       -> 配置快照 + 绑定复核 + Windows thunk / 受限运行时尾跳
       -> TLS / 业务代码
```

## 源码导航

| 路径 | 责任 |
|---|---|
| `src/bootstrap.cpp`、`include/verifier_abi.h` | 最小 x64 provider 握手和 ABI |
| `src/time_*` | 时间配置、年度 DST、Native/Win32 时间 thunk 与解析桥接 |
| `src/locale_*` | NLS、UI/MUI、显式线程／进程选择与缓冲区契约 |
| `src/claude_identity.cpp` | 启动文件身份与清单检查 |
| `src/runtime_compat.cpp` | 无 CRT PE 解析、指纹、模板匹配和绑定复核 |
| `src/runtime_resolve.cpp` | 带普通运行库的离线 CLI 与可选 PDB 校验 |
| `src/runtime_adapter.cpp` | 角色地址、保护条件、补丁安装与回滚 |
| `src/runtime_provider.cpp`、`runtime_winrt*` | 进程时间、Geo、WinRT 激活代理和默认格式化 |
| `src/runtime_capture.cpp` | 可选、有界、自然上下文采样 |
| `profiles/runtime-adapters.json` | 唯一维护档案，构建生成 C++ 表 |
| `scripts/Claude-ManagerCore.ps1` | 所有权、批量注册、事务及恢复 |
| `tests` | Probe、辅助 DLL、Node/Electron 夹具与契约测试 |

Windows API 重定向使用 Verifier 原生 thunk 和窄范围动态地址桥接；运行时适配使用经过整组验证的两个尾跳，不修改磁盘包、ASAR、签名或应用入口。生产入口不主动加载业务 DLL、创建线程、等待或写日志。配置／时区／区域数据初始化形成快照，热路径不读 JSON。

## 已发布诊断 ABI

| 导出 | 定义 |
|---|---|
| `CdfBootstrapQueryState` | 握手位 0x1，进程附加位 0x2 |
| `CdfTimeZoneQueryStatus` | `include/time_zone_status.h`，528 字节 |
| `CdfLocaleQueryStatus` | `include/locale_status.h` |
| `CdfClaudeQueryIdentityStatus` | `include/claude_identity.h`，2280 字节 |
| `CdfRuntimeQueryStatus` | `include/runtime_status.h`，版本 2、816 字节 |
| `CdfRuntimeQueryCompatibilityStatus` | `include/runtime_compat_status.h`，版本 1、552 字节 |

诊断只查询，不触发初始化。终端使用匹配 map 和模块哈希读取 backing state；不能混用构建。Native MUI 的不公开 ABI 另见 [Native-MUI-ABI.md](Native-MUI-ABI.md)。
