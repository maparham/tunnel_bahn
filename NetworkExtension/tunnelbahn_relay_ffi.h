/* smoltcp relay bridge C ABI (implemented in BoringTunBridge/src/relay_bridge.rs) */

#ifndef tunnelbahn_relay_ffi_h
#define tunnelbahn_relay_ffi_h

#include <stdint.h>
#include <stdlib.h>

typedef struct TunnelbahnRelayBridge TunnelbahnRelayBridge; /* opaque (Rust) */

typedef struct TunnelbahnRelayRxItem {
    uint64_t flow_id;
    uint32_t offset;
    uint32_t len;
} TunnelbahnRelayRxItem;

TunnelbahnRelayBridge *tunnelbahn_relay_new(const char *tunnel_ipv4, uint16_t mtu);
void tunnelbahn_relay_free(TunnelbahnRelayBridge *bridge);

/// Per-flow smoltcp TCP receive buffer / advertised window in bytes. Logged at startup as a
/// content-level check of which relay build is live: 65536 = old 64 KiB cap, 1048576 = scaling build.
uint32_t tunnelbahn_relay_tcp_window_bytes(void);

/// 1 if inbound decrypted IP should be fed to smoltcp (dst = tunnel IP, tracked port).
int tunnelbahn_relay_should_intercept_rx(const TunnelbahnRelayBridge *bridge,
                                         const uint8_t *packet,
                                         uint32_t len);

/// Feed inbound IP to smoltcp. Returns 1 if consumed.
int tunnelbahn_relay_feed_rx_ip(TunnelbahnRelayBridge *bridge,
                                const uint8_t *packet,
                                uint32_t len);

/// Poll smoltcp for next outbound IP to encrypt. Returns 1 if packet written, 0 if none, -2 if
/// cap too small — in which case *out_len is set to the required size and the packet stays
/// queued (not consumed), so the caller can grow its buffer and retry.
int tunnelbahn_relay_poll_tx_ip(TunnelbahnRelayBridge *bridge,
                                uint8_t *out,
                                uint32_t cap,
                                uint32_t *out_len);

int tunnelbahn_relay_open_tcp(TunnelbahnRelayBridge *bridge,
                              uint64_t flow_id,
                              const char *remote_ipv4,
                              uint16_t remote_port);

/// Opens a UDP flow: one bound local port whose datagrams all go to remote_ipv4:remote_port.
/// Returns 1 on success.
int tunnelbahn_relay_open_udp(TunnelbahnRelayBridge *bridge,
                              uint64_t flow_id,
                              const char *remote_ipv4,
                              uint16_t remote_port);

/// Sends one datagram on a UDP flow. Returns 1 if the flow exists and is UDP (queued, or
/// dropped-on-full — UDP semantics), -1 if the flow is unknown or not UDP.
int tunnelbahn_relay_send_udp(TunnelbahnRelayBridge *bridge,
                              uint64_t flow_id,
                              const uint8_t *data,
                              uint32_t len);

void tunnelbahn_relay_close(TunnelbahnRelayBridge *bridge, uint64_t flow_id);

/// Tristate. 1 = bytes accepted (buffered/sent), room remains. 0 = bytes WERE accepted
/// (none dropped — do NOT resend them) but the flow's pending tx crossed the backpressure
/// high-water mark; caller must PAUSE feeding this link (pause UDS reads) until smoltcp
/// drains. Pre-handshake (SynSent / SynReceived) bytes are buffered and return 1 unless
/// the high-water mark is crossed. -1 = flow missing, per-flow tx cap exceeded, or socket
/// is in a terminal state (Closed / Closing / FinWait* / TimeWait / LastAck / Listen) and
/// will never accept more bytes; caller should push a flowClosedPush back to the proxy
/// rather than retry.
int tunnelbahn_relay_send_tcp(TunnelbahnRelayBridge *bridge,
                              uint64_t flow_id,
                              const uint8_t *data,
                              uint32_t len);

uint32_t tunnelbahn_relay_drain_rx(TunnelbahnRelayBridge *bridge,
                                   TunnelbahnRelayRxItem *items,
                                   uint32_t max_items,
                                   uint8_t *blob,
                                   uint32_t blob_cap);

/// Pops up to `max` flow IDs whose remote peer closed (FIN/RST) after all their received bytes
/// were surfaced via tunnelbahn_relay_drain_rx. Call AFTER drain_rx so a close event never
/// precedes the flow's final payload bytes.
uint32_t tunnelbahn_relay_drain_closed(TunnelbahnRelayBridge *bridge,
                                       uint64_t *out,
                                       uint32_t max);

#endif /* tunnelbahn_relay_ffi_h */
