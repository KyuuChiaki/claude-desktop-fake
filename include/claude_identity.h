#pragma once
#include <Windows.h>
#include <winternl.h>
#include <cstddef>
#include "runtime_compat.h"

namespace cdf::claude {
enum class Reason : DWORD {
    NotChecked = 0,
    Matched = 1,
    ManifestMissing = 2,
    ManifestInvalid = 3,
    ProcessImageUnavailable = 4,
    ImageFileUnavailable = 5,
    ImageNotListed = 6,
    FileIdentityMismatch = 7
};

struct IdentityStatus {
    DWORD size, version, state, reason, error_code, image_count;
    LONG native_status;
    DWORD reserved;
    ULONGLONG volume_serial;
    BYTE file_id[16];
    ULONGLONG image_size;
    LONGLONG last_write_time;
    WCHAR signer[64];
    WCHAR current_image_path[520];
    WCHAR matched_image_path[520];
};
static_assert(sizeof(IdentityStatus) == 2280);
static_assert(offsetof(IdentityStatus, current_image_path) == 200);

bool MatchesCurrentImage();
struct RuntimeBinding { DWORD version;WCHAR type[16],adapter_id[96],policy[16];BYTE binding_hash[32]; };
void QueryRuntimeBinding(RuntimeBinding& output);
bool ReadRuntimeBinding(compat::Binding& output,DWORD& error);
void QueryIdentityStatus(IdentityStatus& output);
}
