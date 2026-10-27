#pragma once
#include "time_core.h"
#include "runtime_status.h"
#include "runtime_compat_status.h"
namespace cdf {
struct AdapterState {DWORD compatibility,error_stage,error_code,patch_count;WCHAR id[96],version[64];BYTE fingerprint[32];};
bool PrepareAdapter(const Config& config);
void QueryAdapter(AdapterState& output);
bool RollbackAdapter();
PVOID RuntimeAddress(compat::Role role);
}
