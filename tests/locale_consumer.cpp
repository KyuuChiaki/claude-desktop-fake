#include "locale_observation.h"
namespace { cdf::test::LocaleObservation observation{}; }
#ifdef CDF_LATE_CONSUMER
#define CDF_LOCALE_EXPORT CdfLocaleLateSnapshot
#else
#define CDF_LOCALE_EXPORT CdfLocaleEarlySnapshot
#endif
extern "C" __declspec(dllexport) const cdf::test::LocaleObservation* WINAPI CDF_LOCALE_EXPORT() { return &observation; }
BOOL WINAPI DllMain(HINSTANCE,DWORD reason,LPVOID) {
    if (reason==DLL_PROCESS_ATTACH) cdf::test::CaptureLocale(observation);
    return TRUE;
}
