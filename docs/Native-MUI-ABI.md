# Native MUI ABI

声明集中在 [include/locale_native.h](../include/locale_native.h)。部分入口没有公开 SDK 导入库，不能仅凭名字猜测参数，或把 NTSTATUS 当作 BOOL。

查询声明参考固定的 [phnt ntrtl.h](https://github.com/winsiderss/phnt/blob/53fbbdc5b5d2b08761db1c7b26bfa8c820924356/ntrtl.h)。附加设置入口还结合目标 Windows 包装实现和调用契约验证。该说明限定已验证 Windows 版本。

| 入口 | 使用的 ABI |
|---|---|
| RtlGetSystemPreferredUILanguages / RtlGetUserPreferredUILanguages | `NTSTATUS NTAPI (ULONG, PCWSTR, PULONG, PZZWSTR, PULONG)` |
| RtlGetProcessPreferredUILanguages / RtlGetThreadPreferredUILanguages | `NTSTATUS NTAPI (ULONG, PULONG, PZZWSTR, PULONG)` |
| RtlSetProcessPreferredUILanguages / RtlSetThreadPreferredUILanguages | `NTSTATUS NTAPI (ULONG, PCZZWSTR, PULONG)` |
| RtlSetThreadPreferredUILanguages2 | `NTSTATUS NTAPI (ULONG, PCZZWSTR, PULONG, PVOID*)` |
| RtlRestoreThreadPreferredUILanguages | `VOID NTAPI (PVOID)` |

Native 成功通常是 0；Win32 设置接口成功是非零 BOOL。线程保存／恢复使用系统生成的快照句柄，在 Provider 线程记录中关联虚拟显式状态，不向系统恢复入口传入自造指针。线程退出释放记录。

[src/ntdll_extra.def](../src/ntdll_extra.def) 生成 SDK 导入库缺少的 Native 入口和 ntdll 栈探测入口。保留栈探测，避免早期大栈帧越过 guard page。语言列表、失败状态、长度、保存／恢复、清除与线程隔离的验证见区域语言集成测试。
