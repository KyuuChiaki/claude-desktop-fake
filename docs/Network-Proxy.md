# 进程内网络代理

[返回文档索引](README.md)

网络组件在受支持的 Windows x64 进程中将部分 TCP 和名称解析请求交给独立传输。纯测试 Provider 为 `CdfNetwork64.dll`，签名门控版本为 `CdfClaudeNetwork64.dll`。两者使用 `CdfProxyTransport64.dll` 中的 Go／Xray 传输。测试与适用条件见[验收范围](validation.md#网络与控制台)。

## 数据路径

```text
受支持的 TCP 请求 → 进程内环回桥 → 认证代理上游 → 目标
受支持的 DNS 查询 → 同一代理上游 → 远程 HTTPS DNS
```

当前传输面向固定数字 IPv4 上游的 VLESS／TCP／REALITY Vision。所选物理网卡 GUID 表示代理连接的底层接口，目标站点看到的是代理出口。受测路径在网卡不可用、认证失败或代理不可达时返回失败。`CdfNetwork64.dll` 静态依赖 ntdll，独立的 Go 传输含自身运行时。[构建工具链与产物](build.md#构建网络组件和控制台)

## 配置与凭据

配置和连接诊断可从[本机网页控制台](GUI.md)查看。当前支持的配置使用数字 IPv4 上游、端口、网卡 GUID 和协议所需的认证参数。存储使用 CurrentUser DPAPI 密文。应在拥有该配置的同一个 Windows 账户下核对。LocalSystem 不共享该用户的解密上下文，`serviceNetworkEnabled` 当前为 `false`。发布包和问题报告应省略私有凭据、活动 `.dpapi` 文件、完整连接记录和账户数据。

WebRTC 禁用开关默认开启。新建代理连接会应用受支持的 STUN／TURN 识别策略。隔离测试浏览器在会话初始化时也应用对应策略。真实桌面端的会话级验证仍需针对实际进程取得结果。

## 查看状态

```powershell
$status = .\scripts\Manage-ClaudeNetwork.ps1 -Action Status | ConvertFrom-Json
$status | Select-Object requested, enabled, serviceNetworkEnabled, issues
$status.images | Select-Object name, networkEnabled, matchesRecovery
```

| 字段 | 含义 |
| --- | --- |
| `requested` | 代理是否被设置为开启 |
| `enabled` | 所管登记和部署哈希等预检通过，且有对应映像 |
| `images[].networkEnabled` | 该映像名的当前 Provider 选择 |
| `images[].matchesRecovery` | 当前登记值与管理记录一致 |
| `transport`、`issues` | 传输部署校验和冲突原因 |
| `serviceNetworkEnabled` | LocalSystem 服务的网络集成状态 |

上述状态描述登记和文件。运行中的进程可能仍使用启动时的组件。网页控制台列出已观察到的 PID、连接状态及 DNS 记录。对指定 PID 做只读诊断时需使用与其已加载组件一致的 DLL 和 map。`Capture-Network.ps1` 的 `-ProviderName` 区分纯测试和签名门控版本。

## Claude 启动的外部网络工具

[`config/claude-network-children.json`](../config/claude-network-children.json) 默认列出 `ssh.exe` 和 `node.exe`。识别从清单中身份已核实的 Claude 进程开始，核对同一快照中的各级父子关系与创建时间。已退出的中间进程、PID 复用或无法核实的根进程会限制可判定范围。

```powershell
$status = .\scripts\Manage-ClaudeNetwork.ps1 -Action Status | ConvertFrom-Json
$status.networkChildTargets | ConvertTo-Json -Depth 5
```

`enforcement=not-configured` 和 `firstConnectionEnforced=false` 表示当前只报告所识别的子进程。它们的出站仍由各程序和 Windows 策略决定。内核级首次连接控制需要系统提供可验证的进程归属及出站授权。完全新文件名的首次启动边界见[启动诊断](automatic-refresh.md#启动前保护的范围)。[Windows 连接授权层](https://learn.microsoft.com/en-us/windows/win32/fwp/ale-layers)

## 覆盖与边界

| 路径 | 当前处理与验证口径 |
| --- | --- |
| TCP 与连接完成 | 受支持的 Winsock、ConnectEx 和 Native AFD 路径经代理。已验收事件、IOCP 和取消用例。部分非阻塞认证路径仍可能等待 |
| DNS | 已测 `getaddrinfo`、`GetAddrInfoExW` 和 `DnsQuery` 家族的多种调用。受覆盖路径使用远程 DoH，本机可查看公开给诊断的域名与结果 |
| IPv6 | 受覆盖策略拒绝 IPv6 套接字和目标。AAAA 在本地结束，响应过滤 AAAA 和 HTTPS／SVCB 中的 IPv6 提示 |
| WebRTC、UDP 与 QUIC | UDP 与 QUIC 在受覆盖路径拒绝。WebRTC 策略还检查可识别的 STUN／TURN。第三方运行时的完整会话矩阵仍待验收 |
| WinHTTP 与其他客户端 | 已测部分基于 Winsock 的连接。WinInet、WinRT、.NET、URLMon、BITS 和系统服务代发需要单独验收 |
| 既有连接和其他入口 | 继承连接、未映射入口、直接系统调用和系统服务流量超出本次可证实的覆盖范围 |

`fullPlanAccepted=false` 对应预览版的完整网络覆盖尚未通过。独立 ETW 和物理网卡证据对应该次受测 PID、IPv4 上游及采样窗口。当前范围内的退出、连接历史清空及 DNS 记录行为见[控制台](GUI.md#连接记录与-dns)。

## 第三方组件

Go 与模块版本以 [`transport/go.mod`](../transport/go.mod) 和 [`go.sum`](../transport/go.sum) 为准。锁定工具版本和存档哈希见[网络工具链档案](../profiles/network-toolchain.json)。Xray 的 MPL-2.0 许可及依赖声明见[第三方声明](../transport/THIRD_PARTY_NOTICES.md)。
