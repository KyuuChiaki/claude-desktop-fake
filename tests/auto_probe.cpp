#include <Windows.h>
#include <cstdio>

// A bounded, inert child used only by the monitor's termination tests.
int main() {
    std::printf("{\"pid\":%lu}\n", GetCurrentProcessId());
    std::fflush(stdout);
    Sleep(30000);
    return 0;
}
