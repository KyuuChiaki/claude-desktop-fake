#pragma once
#include <Windows.h>
namespace cdf {
struct Sha256 {
    ULONG state[8],used;ULONGLONG bytes;BYTE block[64];
    void Init();void Update(const BYTE* input,SIZE_T size);void Finish(BYTE (&output)[32]);
};
}
