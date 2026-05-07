/* Stable C ABI implemented in `BoringTunBridge` (Rust) on top of Cloudflare BoringTun. */

#ifndef appsplit_wg_ffi_h
#define appsplit_wg_ffi_h

#include <stdint.h>
#include <stdlib.h>

typedef struct AppsplitWgResult {
    uint32_t op;
    size_t size;
} AppsplitWgResult;

enum {
    APPSPLIT_WG_DONE = 0,
    APPSPLIT_WG_WRITE_TO_NETWORK = 1,
    APPSPLIT_WG_ERROR = 2,
    APPSPLIT_WG_WRITE_TO_TUNNEL_IPV4 = 4,
    APPSPLIT_WG_WRITE_TO_TUNNEL_IPV6 = 6,
};

void *appsplit_wg_tunnel_new(const char *static_private,
                              const char *server_static_public,
                              const char *preshared_key,
                              uint16_t keep_alive,
                              uint32_t index);

void appsplit_wg_tunnel_free(void *tunnel);

AppsplitWgResult appsplit_wg_write(const void *tunnel,
                                     const uint8_t *src,
                                     uint32_t src_len,
                                     uint8_t *dst,
                                     uint32_t dst_len);

AppsplitWgResult appsplit_wg_read(const void *tunnel,
                                  const uint8_t *src,
                                  uint32_t src_len,
                                  uint8_t *dst,
                                  uint32_t dst_len);

AppsplitWgResult appsplit_wg_tick(const void *tunnel, uint8_t *dst, uint32_t dst_len);

AppsplitWgResult appsplit_wg_force_handshake(const void *tunnel, uint8_t *dst, uint32_t dst_len);

#endif /* appsplit_wg_ffi_h */
