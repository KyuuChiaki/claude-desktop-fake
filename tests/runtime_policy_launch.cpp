#include <Windows.h>
#include <iostream>
#include <string>
#include <vector>

// A test-only parent that creates a real process with the Windows dynamic-code
// mitigation. The provider must reject the protection policy before patching.
int wmain(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    std::wstring command;
    for (int i = 1; i < argc; ++i) {
        if (i != 1) command += L' ';
        command += L'"';
        unsigned slashes = 0;
        for (const wchar_t* p = argv[i];; ++p) {
            if (*p == L'\\') { ++slashes; continue; }
            if (*p == L'"' || !*p) command.append(slashes, L'\\');
            command.append(slashes, L'\\'); slashes = 0;
            if (!*p) break;
            if (*p == L'"') command += L'\\';
            command += *p;
        }
        command += L'"';
    }
    SIZE_T bytes = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &bytes);
    std::vector<BYTE> storage(bytes);
    auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if (!InitializeProcThreadAttributeList(attributes, 1, 0, &bytes)) return 3;
    const DWORD64 policy = PROCESS_CREATION_MITIGATION_POLICY_PROHIBIT_DYNAMIC_CODE_ALWAYS_ON;
    if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY,
        const_cast<DWORD64*>(&policy), sizeof(policy), nullptr, nullptr)) {
        DeleteProcThreadAttributeList(attributes); return 4;
    }
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!job || !SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
        if (job) CloseHandle(job);
        DeleteProcThreadAttributeList(attributes); return 7;
    }
    STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attributes;
    PROCESS_INFORMATION child{};
    const BOOL created = CreateProcessW(argv[1], command.data(), nullptr, nullptr, FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr, nullptr, &startup.StartupInfo, &child);
    const DWORD error = created ? 0 : GetLastError();
    DeleteProcThreadAttributeList(attributes);
    if (!created) {
        CloseHandle(job);
        std::cout << "{\"created\":false,\"error\":" << error << "}" << std::endl; return 5;
    }
    if (!AssignProcessToJobObject(job, child.hProcess) || ResumeThread(child.hThread) == static_cast<DWORD>(-1)) {
        TerminateProcess(child.hProcess, 0xE0CDF502);
        CloseHandle(child.hThread); CloseHandle(child.hProcess); CloseHandle(job); return 8;
    }
    CloseHandle(child.hThread);
    const DWORD wait = WaitForSingleObject(child.hProcess, 60000);
    if (wait != WAIT_OBJECT_0) {
        TerminateProcess(child.hProcess, 0xE0CDF502);
        WaitForSingleObject(child.hProcess, 5000);
    }
    DWORD code = 0; GetExitCodeProcess(child.hProcess, &code);
    FILETIME creation{}, exit{}, kernel{}, user{};
    GetProcessTimes(child.hProcess, &creation, &exit, &kernel, &user);
    const ULONGLONG real_creation = static_cast<ULONGLONG>(creation.dwHighDateTime) << 32 | creation.dwLowDateTime;
    std::cout << "{\"created\":true,\"pid\":" << child.dwProcessId
        << ",\"exitCode\":" << code << ",\"timedOut\":" << (wait == WAIT_OBJECT_0 ? "false" : "true")
        << ",\"prohibitDynamicCode\":true,\"realCreationFileTime\":" << real_creation << "}" << std::endl;
    CloseHandle(child.hProcess); CloseHandle(job);
    return wait == WAIT_OBJECT_0 ? 0 : 6;
}
