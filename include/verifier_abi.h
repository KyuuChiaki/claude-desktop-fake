#pragma once

#include <Windows.h>
#include <cstddef>

// Loader/provider handshake ABI, not exposed by the public avrfsdk.h.
// Layout reference: https://github.com/reactos/reactos/blob/master/sdk/include/reactos/verifier.h
// Runtime validation on the target Windows build remains the compatibility check.
namespace cdf::verifier {
inline constexpr DWORD process_verifier = 4;
using DllCallback = void(NTAPI*)(PWSTR, PVOID, SIZE_T, PVOID);
using HeapFreeCallback = void(NTAPI*)(PVOID, SIZE_T);

struct ThunkDescriptor {
    PCHAR name;
    PVOID old_address;
    PVOID new_address;
};

struct DllDescriptor {
    PWSTR name;
    DWORD flags;
    PVOID address;
    ThunkDescriptor* thunks;
};

struct ProviderDescriptor {
    DWORD length;
    DllDescriptor* dlls;
    DllCallback dll_load;
    DllCallback dll_unload;
    PWSTR verifier_image;
    DWORD verifier_flags;
    DWORD verifier_debug;
    PVOID get_stack_trace;
    PVOID page_heap_create;
    PVOID page_heap_destroy;
    HeapFreeCallback heap_free;
};

static_assert(sizeof(void*) == 8, "Only AMD64 is supported in stage 1.");
static_assert(sizeof(ThunkDescriptor) == 24);
static_assert(sizeof(DllDescriptor) == 32);
static_assert(sizeof(ProviderDescriptor) == 80);
static_assert(offsetof(ProviderDescriptor, dlls) == 8);
static_assert(offsetof(ProviderDescriptor, dll_load) == 16);
static_assert(offsetof(ProviderDescriptor, verifier_image) == 32);
static_assert(offsetof(ProviderDescriptor, verifier_flags) == 40);
static_assert(offsetof(ProviderDescriptor, get_stack_trace) == 48);
static_assert(offsetof(ProviderDescriptor, heap_free) == 72);
}  // namespace cdf::verifier
