#include "runtime_test.h"
namespace {CdfRuntimeStage early{};}
extern "C" __declspec(dllexport) const CdfRuntimeStage* CdfRuntimeEarlyStage(){return &early;}
BOOL WINAPI DllMain(HINSTANCE,DWORD reason,LPVOID){if(reason==DLL_PROCESS_ATTACH)early=CdfReadRuntimeStage();return TRUE;}
