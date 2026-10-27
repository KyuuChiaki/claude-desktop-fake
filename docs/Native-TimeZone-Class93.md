# Native 信息类 93 的查询契约

在参考 Windows x64 build 19045 内核中，`SystemTimeZoneInformation (93 / 0x5D)` 用于 `NtSetSystemInformation` 的设置路径，没有对应的 `NtQuerySystemInformation` 查询分支。查询 93 失败不应被虚拟化代码伪造成成功，也不应调用设置 API 来“修复”。

可查询路径包括 `SystemCurrentTimeZoneInformation (44 / 0x2C)`、`SystemDynamicTimeZoneInformation (102 / 0x66)`，以及 `RtlQueryTimeZoneInformation`／`RtlQueryDynamicTimeZoneInformation`。Provider 保留原失败状态、参数探测顺序、ReturnLength、缓冲区和 LastError 契约。

原型中曾错误地把 93 当作 RTL_TIME_ZONE_INFORMATION 查询；修正后，44／102 的配置地区结果必须成功，93 则对照未注册控制进程逐项验证。测试涵盖普通导入、动态地址、对齐／未对齐／空缓冲区、可选 ReturnLength 和多种长度，不能把“失败也算时区覆盖”作为通过条件。

此结论来自参考内核的查询／设置分派分析及实际调用。不要把一个 Windows 文件版本的 syscall 编号或 RVA 复制到其他版本；构建号相同也可能有不同维护版本。复现时使用当前系统的控制进程和匹配符号，并记录版本。相关枚举集中在 [include/time_native.h](../include/time_native.h)，回归在时间 Probe 中。
