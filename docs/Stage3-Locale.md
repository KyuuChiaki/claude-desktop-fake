# 第三步 · 区域格式与 UI 语言

[返回文档索引](README.md)

第三步在 Windows 时间功能上加入独立的默认格式 Locale 和 UI 语言。当时验收了 53 个区域语言逻辑入口和 90 个模块绑定。[`include/locale_hooks.inc`](../include/locale_hooks.inc) 是逻辑入口和测试清单的来源。

## 配置

当前模板采用 schema 3。下面保留 schema 2 的最小完整示例，兼容已部署旧配置。[时间与区域配置](time-configuration.md)

```json
{
  "schemaVersion": 2,
  "time": {
    "enabled": true,
    "timeZoneId": "Pacific Standard Time",
    "utcOffsetSeconds": 0
  },
  "locale": {
    "enabled": true,
    "formatLocale": "en-US",
    "uiLanguage": "en-US"
  }
}
```

schema 1 只控制时间。schema 2 的两组分别启用，仍须提供该版本的全部字段。格式和 UI 语言可以不同，例如 `de-DE` 和 `en-US`。名称由本机 NLS 校验并规范化，要求具体且有稳定 LCID／LANGID。en-US、en-GB、de-DE、fr-FR、zh-CN、ja-JP 均在测试范围内。中性名称、invariant、默认占位符、自定义 LCID `0x1000` 和未知名称会被校验拒绝。

UTF-8 可带 BOM，总文件上限 16 KiB。严格解析拒绝重复、未知、缺失字段和错误类型。结构错误使两组停用。独立组初始化失败时诊断报告具体组和阶段。

部署位置以 Windows 的 CommonApplicationData 为准，通常显示为 `%ProgramData%\ClaudeDesktopFake\stage2\timezone.json`。每个进程读取一次，查询使用启动时的配置快照。

## 行为和显式选择

默认用户／系统 Locale、LCID、区域 LANGID 来自 formatLocale，UI LANGID 和首选列表来自 uiLanguage。GetUserDefaultUILanguage 返回 LANGID 0x0409，不返回字符串。

GetLocaleInfo A/W/Ex、日期／时间／数字／货币 A/W/Ex 和日历查询将各自的默认标记映射到明确的配置 Locale。默认查询使用标准 NLS 数据并加 NOUSEROVERRIDE，避免混入宿主自定义格式；明确的 Locale 和格式模板保持原含义。`LOCALE_NAME_USER_DEFAULT` 就是 nullptr，已覆盖；空字符串 invariant 不被改写。LOCALE_RETURN_NUMBER 由原 NLS 实现处理。

日期／时间格式化收到空时间参数时，时间组启用则使用已有的虚拟本地时间，明确时间不叠加偏移。时间组停用时保持真实当前时间。

SetThreadLocale、SetThreadUILanguage、进程／线程首选语言和 Native MUI 设置成功后保留显式选择；失败不改变虚拟选择状态。清除线程／进程首选列表后恢复相应配置默认值。SetThreadUILanguage(0) 选择配置默认语言，而不是将宿主默认值写入线程 MUI 缓存。这个调用仍会改变本线程的 Windows 状态；本项目不承诺隐藏调用产生的内部缓存变化。

首选列表保留显式顺序和去重，线程选择先于进程选择，用户和系统 fallback 来自配置。MUI_THREAD_LANGUAGES 排除进程列表；MUI_MERGE_SYSTEM_FALLBACK 按各来源扩展 NLS parent，MUI_MERGE_USER_FALLBACK 合并配置用户来源。名称／十六进制 LANGID、大小查询、双终止符和短缓冲区均使用虚拟结果计算。筛选标志的单独设置／重置不清除语言列表。保存／恢复保留真实 Windows 快照句柄，并另存虚拟显式状态。

线程状态使用系统 TLS、按需 Native heap 记录，线程退出释放。KernelBase 尚未出现在模块列表时，Verifier 的 DLL-load 回调用已提供的模块地址准备 TLS，早于启动消费者。诊断必须同时满足配置、TLS 和全部模块绑定，才报告就绪。

## 校验与预览

构建时间规则校验器后，在仓库根目录运行。配置预览可以检查时间组。区域语言格式可在控制台查看，并用 NLS 规则测试核对。[控制台](GUI.md) · [构建与验证](build.md)

```powershell
.\out\build\x64-release\bin\CdfTimeRules64.exe --validate-config .\config\timezone.json
ctest --test-dir out/build/x64-release -R '^locale_rules$' --output-on-failure
```

## 诊断和验收

```cpp
DWORD WINAPI CdfLocaleQueryStatus(CdfLocaleStatus* buffer, DWORD bufferSize);
```

定义在 `include/locale_status.h`，版本 1，x64 结构大小为 832 字节。状态位 1=握手、2=attach、4=JSON 已验证、8=区域快照启用、16=所有 Hook 模块绑定已解析、32=TLS 就绪，完整为 `0x3F`。error_stage 为 1=文件／JSON、2=NLS 校验、3=TLS 初始化；含 Win32/Native 错误、规范名称、LCID/LANGID、53 个入口计数与线程记录数。查询不触发初始化。原时间诊断版本 1、528 字节和时间计数保持兼容。

Native MUI 查询与设置的固定版本参考、包装核验和返回值约定见 [Native-MUI-ABI.md](Native-MUI-ABI.md)。回归测试入口见[测试指南](testing.md)。

第三步构建共有 10 项 CTest，包含 `locale_rules`、`locale_build_inspection` 和 `locale_integration`。集成脚本串行管理共享 IFEO 和 JSON，测试六个区域、混合 UI、独立开关、两名称各 10 次及 16 线程查询。对照涵盖未注册 NLS、Native、UCRT、快照及无效配置恢复，写入 `out/build/x64-release/test-results`。

该轮覆盖已验收的 Windows API 与 UCRT 路径。UI 标识只是语言查询结果，资源文本由实际可用资源决定。`English_United States.936` 中的 `936` 为样本机器的代码页。后续地理地区、ICU／JavaScript 和 WinRT 的范围见[运行时与 WinRT](Stage5-Runtime.md)。
