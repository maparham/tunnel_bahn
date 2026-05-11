/* Stable C ABI implemented in `BoringTunBridge` (Rust) on top of Cloudflare BoringTun. */

#ifndef tunnelbahn_wg_ffi_h
#define tunnelbahn_wg_ffi_h

#include <stdint.h>
#include <stdlib.h>

typedef struct TunnelbahnWgResult {
    uint32_t op;
    size_t size;
} TunnelbahnWgResult;

enum {
    TUNNELBAHN_WG_DONE = 0,
    TUNNELBAHN_WG_WRITE_TO_NETWORK = 1,
    TUNNELBAHN_WG_ERROR = 2,
    TUNNELBAHN_WG_WRITE_TO_TUNNEL_IPV4 = 4,
    TUNNELBAHN_WG_WRITE_TO_TUNNEL_IPV6 = 6,
};

void *tunnelbahn_wg_tunnel_new(const char *static_private,
                                const char *server_static_public,
                                const char *preshared_key,
                                uint16_t keep_alive,
                                uint32_t index);

void tunnelbahn_wg_tunnel_free(void *tunnel);

TunnelbahnWgResult tunnelbahn_wg_write(const void *tunnel,
                                      const uint8_t *src,
                                      uint32_t src_len,
                                      uint8_t *dst,
                                      uint32_t dst_len);

TunnelbahnWgResult tunnelbahn_wg_read(const void *tunnel,
                                     const uint8_t *src,
                                     uint32_t src_len,
                                     uint8_t *dst,
                                     uint32_t dst_len);

TunnelbahnWgResult tunnelbahn_wg_tick(const void *tunnel, uint8_t *dst, uint32_t dst_len);

TunnelbahnWgResult tunnelbahn_wg_force_handshake(const void *tunnel, uint8_t *dst, uint32_t dst_len);

#endif /* tunnelbahn_wg_ffi_h */
