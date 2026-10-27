#include <cstring>
// Compiler-emitted aggregate copies must not introduce a CRT dependency.
#pragma function(memcpy, memset)
extern "C" void* __cdecl memcpy(void* destination, const void* source, std::size_t size) {
    auto* d = static_cast<volatile unsigned char*>(destination);
    const auto* s = static_cast<const volatile unsigned char*>(source);
    while (size--) *d++ = *s++;
    return destination;
}
extern "C" void* __cdecl memset(void* destination, int value, std::size_t size) {
    auto* d = static_cast<volatile unsigned char*>(destination);
    while (size--) *d++ = static_cast<unsigned char>(value);
    return destination;
}
