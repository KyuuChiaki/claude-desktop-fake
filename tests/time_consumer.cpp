#include "time_observation.h"
namespace { cdf::test::Observation observation{}; }
#ifdef CDF_LATE_CONSUMER
#define CDF_CONSUMER_EXPORT CdfLateSnapshot
#else
#define CDF_CONSUMER_EXPORT CdfEarlySnapshot
#endif
extern "C" __declspec(dllexport) const cdf::test::Observation* WINAPI CDF_CONSUMER_EXPORT() { return &observation; }
BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) cdf::test::Capture(observation);
    return TRUE;
}
