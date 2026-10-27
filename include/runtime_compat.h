#pragma once
#include <Windows.h>
#include <cstddef>

namespace cdf::compat {
enum Role : ULONG {
    DefaultLocale, PublicLocale, StringCtor, NodeNavigatorCall, HandleScopeCtor,
    TryCatchCtor, TryCatchDtor, HandleScopeDtor, CurrentContext, NewString,
    Compile, Run, Utf8Length, WriteUtf8, RoleCount
};
enum Match : ULONG { None, ExactImage, EngineReuse, AbiResolved, NativeImage };
enum Failure : ULONG {
    Ok, InvalidPe, UnsupportedWindows, UnknownRuntime, MissingSite, AmbiguousSite,
    AbiMismatch, InvalidFuse, BindingMissing, BindingInvalid, BindingStale,
    CaptureUnavailable, MemoryChanged, UnsupportedSymbols
};
inline constexpr ULONG binding_magic=0x36464443, binding_version=1, max_sections=32;
struct SiteBinding {
    ULONG rva, function_rva, function_size, reserved;
    BYTE code_sha256[32];
};
struct Binding {
    ULONG magic,version,size,catalog_revision,machine,windows_build,match,abi_index;
    ULONG engine_index,image_size,timestamp,capture_ready;
    BYTE catalog_sha256[32],image_sha256[32],engine_sha256[32];
    WCHAR runtime_version[64];
    SiteBinding sites[RoleCount];
};
static_assert(sizeof(Binding)==944);
struct Section {ULONG rva,virtual_size,raw,raw_size,flags;char name[8];};
struct Image {
    const BYTE* data;SIZE_T size;ULONG pe,image_size,timestamp,section_count;
    Section sections[max_sections];
    bool Open(const BYTE* bytes,SIZE_T length);
    const BYTE* At(ULONG rva,SIZE_T length) const;
    bool Export(const char* name) const;
    bool Function(ULONG rva,ULONG& begin,ULONG& length) const;
};
struct Result { Binding binding;ULONG failure,failed_role,candidates;bool runtime; };
bool Resolve(const Image& image,bool capture,bool allow_scan,Result& output);
bool ValidateBinding(const Image& image,const Binding& binding,bool capture,Result& output);
bool ValidateMapped(const BYTE* image,ULONG size,const Binding& binding,bool capture,ULONG& role);
void Sha(const BYTE* bytes,SIZE_T length,BYTE (&out)[32]);
bool Equal(const BYTE* a,const BYTE* b,SIZE_T length);
const WCHAR* RoleName(ULONG role);
const WCHAR* AbiName(ULONG index);
const WCHAR* EngineName(ULONG index);
const WCHAR* EngineVersion(ULONG index);
void BindingName(const Binding& binding,WCHAR (&output)[96]);
const char* FailureName(ULONG failure);
ULONG CatalogRevision();
const BYTE* CatalogHash();
ULONG EngineCount();
}
