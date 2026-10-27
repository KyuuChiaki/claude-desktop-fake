#pragma once
#include "runtime_compat.h"
struct CdfRuntimeCompatibilityStatus {
    DWORD size,version,state,error_code,failure,failed_role,match,catalog_revision;
    DWORD core_ready,capture_ready,binding_loaded,site_count;
    BYTE image_sha256[32],engine_sha256[32],binding_sha256[32],catalog_sha256[32];
    WCHAR abi_id[64],engine_id[96];
    DWORD rvas[cdf::compat::RoleCount];
};
static_assert(sizeof(CdfRuntimeCompatibilityStatus)==552);
using CdfRuntimeCompatibilityQuery=DWORD(WINAPI*)(CdfRuntimeCompatibilityStatus*,DWORD);
