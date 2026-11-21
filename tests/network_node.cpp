#include "network_status.h"
#include <Windows.h>
using Env = void *;
using Value = void *;
using Info = void *;
using Status = int;
using Callback = Value (*)(Env, Info);
template <class T> T Napi(const char *name) {
  return reinterpret_cast<T>(GetProcAddress(GetModuleHandleW(nullptr), name));
}
Value Sample(Env env, Info) {
  CdfNetworkStatus state{};
  const auto module = GetModuleHandleW(L"CdfNetwork64.dll");
  if (module) {
    using Query = DWORD(WINAPI *)(CdfNetworkStatus *, DWORD);
    const auto query = reinterpret_cast<Query>(
        GetProcAddress(module, "CdfNetworkQueryStatus"));
    if (query)
      query(&state, sizeof(state));
  }
  auto object = Napi<Status (*)(Env, Value *)>("napi_create_object");
  auto number = Napi<Status (*)(Env, double, Value *)>("napi_create_double");
  auto property = Napi<Status (*)(Env, Value, const char *, Value)>(
      "napi_set_named_property");
  if (!object || !number || !property)
    return nullptr;
  Value result = nullptr;
  if (object(env, &result))
    return nullptr;
  const char *names[] = {"state",      "errorStage",   "errorCode",
                         "hooks",      "connectCalls", "proxiedConnections",
                         "dnsQueries", "nativeDenials"};
  const double values[] = {static_cast<double>(state.state),
                           static_cast<double>(state.error_stage),
                           static_cast<double>(state.error_code),
                           static_cast<double>(state.installed_hooks),
                           static_cast<double>(state.connect_calls),
                           static_cast<double>(state.proxied_connections),
                           static_cast<double>(state.dns_queries),
                           static_cast<double>(state.native_denials)};
  for (unsigned i = 0; i < 8; ++i) {
    Value value = nullptr;
    if (number(env, values[i], &value) ||
        property(env, result, names[i], value))
      return nullptr;
  }
  return result;
}
extern "C" __declspec(dllexport) Value napi_register_module_v1(Env env,
                                                               Value exports) {
  auto function =
      Napi<Status (*)(Env, const char *, size_t, Callback, void *, Value *)>(
          "napi_create_function");
  auto property = Napi<Status (*)(Env, Value, const char *, Value)>(
      "napi_set_named_property");
  if (!function || !property)
    return nullptr;
  Value sample = nullptr;
  if (function(env, "sample", 6, Sample, nullptr, &sample) ||
      property(env, exports, "sample", sample))
    return nullptr;
  return exports;
}
