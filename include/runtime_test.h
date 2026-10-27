#pragma once
#include "runtime_status.h"
struct CdfRuntimeStage {DWORD loaded,state,error;WCHAR geo[8];ULONGLONG creation;};
inline CdfRuntimeStage CdfReadRuntimeStage(){
    CdfRuntimeStage result{};HMODULE provider=GetModuleHandleW(L"CdfTimeZone64.dll");
    if(!provider)provider=GetModuleHandleW(L"CdfClaudeTimeZoneTest64.dll");
    if(provider){result.loaded=1;const auto fn=reinterpret_cast<CdfRuntimeQuery>(GetProcAddress(provider,"CdfRuntimeQueryStatus"));CdfRuntimeStatus s{};if(fn&&fn(&s,sizeof(s))==0){result.state=s.state;result.error=s.error_code;}}
    GetUserDefaultGeoName(result.geo,8);FILETIME creation{},exit{},kernel{},user{};
    if(GetProcessTimes(GetCurrentProcess(),&creation,&exit,&kernel,&user))result.creation=(static_cast<ULONGLONG>(creation.dwHighDateTime)<<32)|creation.dwLowDateTime;
    return result;
}
