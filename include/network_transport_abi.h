#pragma once
#include <stdint.h>
#ifdef _WIN32
#define CDF_NET_CALL __stdcall
#else
#define CDF_NET_CALL
#endif
// Pointers and buffers are owned by the caller. No Go pointers cross this ABI.
typedef int(CDF_NET_CALL *CdfAuthorizeSocket)(uintptr_t socket, uint32_t kind);
typedef int64_t(CDF_NET_CALL *CdfRealUtcTicks)(void);
typedef int(CDF_NET_CALL *CdfConfigureUpstream)(const uint8_t *, uint16_t);
typedef struct CdfNetworkHostApi {
  uint32_t size;
  uint32_t version;
  CdfAuthorizeSocket authorize_socket;
  CdfRealUtcTicks real_utc_ticks;
  CdfConfigureUpstream configure_upstream;
} CdfNetworkHostApi;
// kind 1: the single numeric upstream; 2: private loopback listener;
// kind 3: accepted bridge stream. These are per-handle capabilities.
typedef int(CDF_NET_CALL *CdfTransportStartFn)(const CdfNetworkHostApi *,
                                               const uint16_t *,
                                               const uint16_t *);
typedef int(CDF_NET_CALL *CdfTransportOpenFn)(const char *, uint16_t, uint16_t,
                                              uint32_t, const char *,
                                              uint16_t *);
typedef int(CDF_NET_CALL *CdfTransportDnsFn)(const uint8_t *, uint32_t,
                                             uint8_t *, uint32_t, uint32_t *);
typedef void(CDF_NET_CALL *CdfTransportStopFn)(void);
typedef void(CDF_NET_CALL *CdfTransportReleaseFn)(uint16_t, uint32_t);
