#pragma once
#include <Windows.h>
inline constexpr ULONG CdfCaptureCapacity=32,CdfCaptureTextCapacity=8192;
struct CdfCaptureSlot {
    volatile LONG sequence;DWORD state,thread_id,bytes;ULONGLONG context;
    char json[CdfCaptureTextCapacity];
};
struct CdfRuntimeCapture {
    DWORD size,version;volatile LONG count,failures,truncated;DWORD reserved;
    CdfCaptureSlot slots[CdfCaptureCapacity];
};
static_assert(sizeof(CdfCaptureSlot)==8216);
namespace cdf {
void CaptureContext(PVOID isolate,PVOID image);
bool RuntimeEnterCapture();void RuntimeLeaveCapture();
void CaptureCounts(DWORD& contexts,DWORD& failures,DWORD& truncated);
}
