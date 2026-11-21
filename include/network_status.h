#pragma once
#include <stdint.h>
enum CdfNetworkState : uint32_t {
  CdfNetworkHandshake = 1,
  CdfNetworkAttached = 2,
  CdfNetworkPolicyReady = 4,
  CdfNetworkHooksReady = 8,
  CdfNetworkTransportReady = 16,
  CdfNetworkIPv4Only = 32,
  CdfNetworkFailed = 0x80000000u
};
struct CdfNetworkStatus {
  uint32_t size, version, state, error_stage, error_code, verifier_flags;
  uint32_t installed_hooks, socket_count;
  uint64_t connect_calls, proxied_connections, dns_queries, denied_calls,
      native_denials, dynamic_lookups;
  uint32_t transport_starts, last_native_ioctl;
  uint64_t native_calls;
  uint32_t last_connect_input_size, last_connect_ioctl;
  uint8_t last_connect_input[96];
  uint32_t denied_ioctl, denied_input_size;
  uint8_t denied_input[64];
  uint64_t api_calls[32];
  uint32_t last_api, argument1, argument2, argument3;
};
static_assert(sizeof(CdfNetworkStatus) == 544);
struct CdfNetworkPolicy {
  uint32_t magic, version, size, reserved;
  uint16_t transport_path[512], profile_path[512], interface_guid[40];
  uint8_t transport_sha256[32], profile_sha256[32];
};
static_assert(sizeof(CdfNetworkPolicy) == 2208);
