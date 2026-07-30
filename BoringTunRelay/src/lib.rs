//! Userspace TCP relay via smoltcp for XPC-injected app-tunnel flows.

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::{tcp, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{
    IpAddress, IpCidr, IpEndpoint, IpProtocol, Ipv4Address, Ipv4Packet, TcpPacket, UdpPacket,
};
use std::collections::{HashMap, VecDeque};
use std::ffi::c_char;
use std::ptr;
use std::time::Instant as StdInstant;

// Per-flow smoltcp TCP socket buffers. Critically, these ALSO set the TCP window: smoltcp 0.12
// derives the RFC 1323 window-scale shift directly from the buffer size
// (`remote_win_shift = log2(buf) - 16`, socket/tcp.rs) and advertises it in the SYN it sends as
// the active opener. So a buffer > 64 KiB AUTO-ENABLES window scaling — no extra config needed.
// The old 64 KiB value gave shift 0 (no scaling) → a hard 64 KiB window → single-flow throughput
// capped at ~window/RTT (≈3.5 Mbit/s @ 150 ms, ≈10 Mbit/s @ 50 ms) regardless of link speed, which
// is why we were far slower than the official WireGuard client (it reuses the kernel's auto-tuned
// multi-MB window). 1 MiB → shift 4 → ~1 MiB window (≈56 Mbit/s @ 150 ms, ≈168 Mbit/s @ 50 ms).
// Cost: smoltcp allocates each buffer up front per socket, so every flow costs RX+TX = 2 MiB even
// when short-lived (a page load opening dozens of connections briefly allocates dozens × 2 MiB).
// macOS system extensions are not hard memory-capped, but if many-concurrent-flow pressure shows
// up, dial these down to 512 KiB (shift 3, ~512 KiB window) — still ~8x the old window.
const TCP_RX_BUF: usize = 1024 * 1024;
const TCP_TX_BUF: usize = 1024 * 1024;
const EPHEMERAL_PORT_MIN: u16 = 49152;
const EPHEMERAL_PORT_MAX: u16 = 60999;
const MAX_DRAIN_ITEMS: usize = 32;
const MAX_DRAIN_BLOB: usize = 256 * 1024;
/// Upper bound on app->server bytes buffered per flow while smoltcp's tx window (TCP_TX_BUF) is
/// full. The proxy ships payloads fire-and-forget (no per-byte ack), so a temporarily slow
/// tunnel would otherwise grow this without limit. 4 MiB is generous headroom for normal
/// bursts (e.g. a page load firing dozens of requests with large cookies at once); exceeding
/// it means the app is uploading faster than the tunnel can drain for a sustained period, at
/// which point tearing the flow down is preferable to unbounded memory growth.
const MAX_FLOW_TX_BUF: usize = 4 * 1024 * 1024;
/// Per-flow `pending_tx` high-water at which `send_tcp` returns `Transient` (backpressure). The bytes
/// are still accepted (no loss); the signal tells the relay server to PAUSE reading the UDS, which
/// fills the proxy's write buffer and ultimately throttles the source app's own TCP send window. This
/// keeps `pending_tx` from ever climbing to `MAX_FLOW_TX_BUF` (the fail-closed cap that was tearing
/// sustained uploads down). Well below the cap so a flow is never killed for merely being busy.
const TX_BACKPRESSURE_HIGH: usize = 512 * 1024;
// Per-flow smoltcp UDP packet buffers. Sized for interactive datagram traffic (DNS, QUIC
// handshakes, NTP): each direction holds up to N datagrams / B payload bytes; a full buffer
// DROPS the datagram — correct UDP semantics, the app retransmits at its own layer.
const UDP_RX_PACKETS: usize = 64;
const UDP_RX_BUF: usize = 128 * 1024;
const UDP_TX_PACKETS: usize = 32;
const UDP_TX_BUF: usize = 64 * 1024;

struct RelayDevice {
    rx_queue: VecDeque<Vec<u8>>,
    tx_queue: VecDeque<Vec<u8>>,
}

impl RelayDevice {
    fn push_rx(&mut self, packet: Vec<u8>) {
        if self.rx_queue.len() < 128 {
            self.rx_queue.push_back(packet);
        }
    }
}

impl Device for RelayDevice {
    type RxToken<'a> = RelayRxToken<'a>;
    type TxToken<'a> = RelayTxToken<'a>;

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.max_transmission_unit = 1380;
        caps.medium = Medium::Ip;
        caps
    }

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        if self.rx_queue.is_empty() {
            return None;
        }
        Some((
            RelayRxToken {
                queue: &mut self.rx_queue,
            },
            RelayTxToken {
                queue: &mut self.tx_queue,
            },
        ))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(RelayTxToken {
            queue: &mut self.tx_queue,
        })
    }
}

struct RelayRxToken<'a> {
    queue: &'a mut VecDeque<Vec<u8>>,
}

impl RxToken for RelayRxToken<'_> {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        let packet = self.queue.pop_front().expect("rx token");
        f(&packet)
    }
}

struct RelayTxToken<'a> {
    queue: &'a mut VecDeque<Vec<u8>>,
}

impl TxToken for RelayTxToken<'_> {
    fn consume<R, F>(self, max_len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut buffer = vec![0u8; max_len];
        let result = f(&mut buffer);
        let len = Ipv4Packet::new_checked(&buffer)
            .map(|p| p.total_len() as usize)
            .unwrap_or(max_len)
            .min(max_len);
        buffer.truncate(len);
        if !buffer.is_empty() {
            self.queue.push_back(buffer);
        }
        result
    }
}

struct FlowEntry {
    handle: SocketHandle,
    local_port: u16,
    pending_rx: VecDeque<Vec<u8>>,
    /// App->server bytes accepted from the proxy but not yet handed to smoltcp because its
    /// tx window (TCP_TX_BUF) was full (or the TCP handshake hadn't completed). Drained in order by
    /// `pump_tx` on every poll, so no byte is ever dropped and stream order is preserved.
    pending_tx: Vec<u8>,
    /// `Some(remote)` marks a UDP flow (the socket behind `handle` is `udp::Socket`, every
    /// datagram is sent to `remote`); `None` marks TCP. Guards every `sockets.get::<T>` cast —
    /// downcasting a handle to the wrong socket type panics inside smoltcp.
    udp_remote: Option<IpEndpoint>,
}

pub struct TunnelbahnRelayBridge {
    tunnel_ip: Ipv4Address,
    device: RelayDevice,
    iface: Interface,
    sockets: SocketSet<'static>,
    flows: HashMap<u64, FlowEntry>,
    port_to_flow: HashMap<u16, u64>,
    /// UDP local-port → flow map, separate from `port_to_flow` (TCP) because inbound intercept
    /// must match ports per-protocol: a TCP segment to a UDP flow's port is NOT ours.
    udp_port_to_flow: HashMap<u16, u64>,
    next_port: u16,
    /// Monotonic anchor for smoltcp time. Must NOT be wall clock: a backward NTP step or
    /// sleep/wake correction would regress smoltcp's Instant and freeze every
    /// retransmission/RTO timer until wall time caught back up.
    started_at: StdInstant,
    /// Flow IDs whose remote peer closed and whose pending_rx was fully delivered; drained by
    /// `tunnelbahn_relay_drain_closed` (same poll-then-drain pattern as `pending_rx`).
    closed_flows: Vec<u64>,
    /// Reusable scratch buffers for the per-poll hot path (flow-id snapshot and TCP recv),
    /// avoiding a heap allocation per poll / per received segment.
    flow_ids_scratch: Vec<u64>,
    rx_scratch: Vec<u8>,
}

impl TunnelbahnRelayBridge {
    fn now(&self) -> Instant {
        Instant::from_millis(self.started_at.elapsed().as_millis() as i64)
    }

    fn poll_stack(&mut self) {
        let now = self.now();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        // Hand any buffered app->server bytes to sockets whose tx window (or handshake) just
        // opened, then poll again so the freshly-queued bytes egress as packets this tick.
        self.pump_all_tx();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        self.collect_tcp_rx();
    }

    /// Push as much of a flow's `pending_tx` into smoltcp's tx buffer as currently fits,
    /// in order. `send_slice` returns how many bytes it accepted; only those are removed
    /// from the buffer, so the unsent remainder is retried on the next poll.
    fn pump_tx(&mut self, flow_id: u64) {
        let Some(entry) = self.flows.get_mut(&flow_id) else {
            return;
        };
        if entry.udp_remote.is_some() || entry.pending_tx.is_empty() {
            return;
        }
        let socket = self.sockets.get_mut::<tcp::Socket>(entry.handle);
        if !socket.may_send() {
            return;
        }
        if let Ok(n) = socket.send_slice(&entry.pending_tx) {
            if n > 0 {
                entry.pending_tx.drain(0..n);
            }
        }
    }

    fn pump_all_tx(&mut self) {
        let mut flow_ids = std::mem::take(&mut self.flow_ids_scratch);
        flow_ids.clear();
        flow_ids.extend(self.flows.keys().copied());
        for flow_id in flow_ids.iter().copied() {
            self.pump_tx(flow_id);
        }
        self.flow_ids_scratch = flow_ids;
    }

    fn collect_tcp_rx(&mut self) {
        let mut flow_ids = std::mem::take(&mut self.flow_ids_scratch);
        flow_ids.clear();
        flow_ids.extend(self.flows.keys().copied());
        for flow_id in flow_ids.iter().copied() {
            let Some(entry) = self.flows.get_mut(&flow_id) else {
                continue;
            };
            let handle = entry.handle;
            if entry.udp_remote.is_some() {
                // UDP flow: surface each received datagram as one pending_rx chunk (preserving
                // datagram boundaries end-to-end). No close-state machinery — UDP flows live
                // until the proxy explicitly closes them.
                let socket = self.sockets.get_mut::<udp::Socket>(handle);
                while socket.can_recv() {
                    match socket.recv_slice(&mut self.rx_scratch) {
                        Ok((n, _meta)) => {
                            entry.pending_rx.push_back(self.rx_scratch[..n].to_vec());
                        }
                        Err(_) => break,
                    }
                }
                continue;
            }
            let socket = self.sockets.get_mut::<tcp::Socket>(handle);
            while socket.can_recv() {
                // recv into the persistent scratch, copying only the delivered bytes into an
                // owned Vec — avoids an 8 KiB zero-filled allocation per received segment.
                if let Ok(n) = socket.recv_slice(&mut self.rx_scratch) {
                    if n == 0 {
                        break;
                    }
                    entry.pending_rx.push_back(self.rx_scratch[..n].to_vec());
                } else {
                    break;
                }
            }
            // Remote closed (FIN/RST, i.e. CloseWait-or-later — SynSent/SynReceived are excluded
            // because a still-connecting socket also can't recv). Retire the flow only once every
            // received byte has been handed upward (pending_rx drained by drain_rx) and nothing
            // remains to transmit, so a close event can never outrun the final rx bytes.
            let remote_closed = !socket.may_recv()
                && !matches!(socket.state(), tcp::State::SynSent | tcp::State::SynReceived);
            let tx_flushed =
                !socket.may_send() || (entry.pending_tx.is_empty() && socket.send_queue() == 0);
            if remote_closed && entry.pending_rx.is_empty() && tx_flushed {
                if let Some(e) = self.flows.remove(&flow_id) {
                    self.port_to_flow.remove(&e.local_port);
                    self.sockets.remove(e.handle);
                }
                self.closed_flows.push(flow_id);
            }
        }
        self.flow_ids_scratch = flow_ids;
    }

    fn alloc_port(&mut self) -> Option<u16> {
        for _ in 0..(EPHEMERAL_PORT_MAX - EPHEMERAL_PORT_MIN + 1) {
            let port = self.next_port;
            self.next_port = if port >= EPHEMERAL_PORT_MAX {
                EPHEMERAL_PORT_MIN
            } else {
                port + 1
            };
            if !self.port_to_flow.contains_key(&port) && !self.udp_port_to_flow.contains_key(&port)
            {
                return Some(port);
            }
        }
        None
    }

    pub fn new(tunnel_ip: Ipv4Address, _mtu: u16) -> Self {
        let mut device = RelayDevice {
            rx_queue: VecDeque::new(),
            tx_queue: VecDeque::new(),
        };
        let config = Config::new(smoltcp::wire::HardwareAddress::Ip);
        let mut iface = Interface::new(config, &mut device, Instant::from_millis(0));
        iface.update_ip_addrs(|addrs| {
            addrs.push(IpCidr::new(IpAddress::Ipv4(tunnel_ip), 32)).ok();
        });

        Self {
            tunnel_ip,
            device,
            iface,
            sockets: SocketSet::new(vec![]),
            flows: HashMap::new(),
            port_to_flow: HashMap::new(),
            udp_port_to_flow: HashMap::new(),
            next_port: EPHEMERAL_PORT_MIN,
            started_at: StdInstant::now(),
            closed_flows: Vec::new(),
            flow_ids_scratch: Vec::new(),
            rx_scratch: vec![0u8; 8192],
        }
    }

    pub fn should_intercept_inbound(&self, packet: &[u8]) -> bool {
        let Ok(ip) = Ipv4Packet::new_checked(packet) else {
            return false;
        };
        if ip.dst_addr() != self.tunnel_ip {
            return false;
        }
        let proto = ip.next_header();
        let payload = ip.payload();
        match proto {
            IpProtocol::Tcp => TcpPacket::new_checked(payload)
                .ok()
                .map(|t| self.port_to_flow.contains_key(&t.dst_port()))
                .unwrap_or(false),
            IpProtocol::Udp => UdpPacket::new_checked(payload)
                .ok()
                .map(|u| self.udp_port_to_flow.contains_key(&u.dst_port()))
                .unwrap_or(false),
            _ => false,
        }
    }

    pub fn feed_rx_ip(&mut self, packet: &[u8]) -> bool {
        if !self.should_intercept_inbound(packet) {
            return false;
        }
        self.device.push_rx(packet.to_vec());
        self.poll_stack();
        true
    }

    pub fn open_tcp(&mut self, flow_id: u64, remote_ip: Ipv4Address, remote_port: u16) -> bool {
        if self.flows.contains_key(&flow_id) {
            return false;
        }
        let Some(local_port) = self.alloc_port() else {
            return false;
        };

        let rx_buffer = tcp::SocketBuffer::new(vec![0u8; TCP_RX_BUF]);
        let tx_buffer = tcp::SocketBuffer::new(vec![0u8; TCP_TX_BUF]);
        let mut socket = tcp::Socket::new(rx_buffer, tx_buffer);
        let remote_endpoint = IpEndpoint::new(IpAddress::Ipv4(remote_ip), remote_port);
        socket.set_keep_alive(None);
        // smoltcp defaults to CongestionControl::None (no slow-start/backoff). Cubic is the same
        // algorithm macOS/Linux use; it mainly governs the upload path (smoltcp is the sender there)
        // and makes loss recovery behave on lossy/long-haul links instead of blindly refilling the
        // window. Requires the `socket-tcp-cubic` feature; its f64 math is fine on desktop FPUs.
        socket.set_congestion_control(tcp::CongestionControl::Cubic);

        let handle = self.sockets.add(socket);
        {
            let socket = self.sockets.get_mut::<tcp::Socket>(handle);
            if socket.connect(self.iface.context(), remote_endpoint, local_port).is_err() {
                self.sockets.remove(handle);
                return false;
            }
        }

        self.port_to_flow.insert(local_port, flow_id);
        self.flows.insert(
            flow_id,
            FlowEntry {
                handle,
                local_port,
                pending_rx: VecDeque::new(),
                pending_tx: Vec::new(),
                udp_remote: None,
            },
        );
        self.poll_stack();
        true
    }

    /// Opens a UDP "flow": one bound local port whose datagrams all go to `remote`. Mirrors the
    /// proxy's per-destination `UDPFlowRelay` keying (one relay flow per app-flow × remote).
    pub fn open_udp(&mut self, flow_id: u64, remote_ip: Ipv4Address, remote_port: u16) -> bool {
        if self.flows.contains_key(&flow_id) {
            return false;
        }
        let Some(local_port) = self.alloc_port() else {
            return false;
        };

        let rx_buffer = udp::PacketBuffer::new(
            vec![udp::PacketMetadata::EMPTY; UDP_RX_PACKETS],
            vec![0u8; UDP_RX_BUF],
        );
        let tx_buffer = udp::PacketBuffer::new(
            vec![udp::PacketMetadata::EMPTY; UDP_TX_PACKETS],
            vec![0u8; UDP_TX_BUF],
        );
        let mut socket = udp::Socket::new(rx_buffer, tx_buffer);
        if socket.bind(local_port).is_err() {
            return false;
        }

        let handle = self.sockets.add(socket);
        self.udp_port_to_flow.insert(local_port, flow_id);
        self.flows.insert(
            flow_id,
            FlowEntry {
                handle,
                local_port,
                pending_rx: VecDeque::new(),
                pending_tx: Vec::new(),
                udp_remote: Some(IpEndpoint::new(IpAddress::Ipv4(remote_ip), remote_port)),
            },
        );
        self.poll_stack();
        true
    }

    /// Sends one datagram on a UDP flow. A full tx buffer silently DROPS the datagram (UDP
    /// semantics — the app's own protocol retransmits); only a missing/non-UDP flow returns false.
    pub fn send_udp(&mut self, flow_id: u64, data: &[u8]) -> bool {
        let Some(entry) = self.flows.get_mut(&flow_id) else {
            return false;
        };
        let Some(remote) = entry.udp_remote else {
            return false;
        };
        let socket = self.sockets.get_mut::<udp::Socket>(entry.handle);
        let _ = socket.send_slice(data, remote);
        self.poll_stack();
        true
    }

    pub fn close_flow(&mut self, flow_id: u64) {
        let Some(entry) = self.flows.remove(&flow_id) else {
            return;
        };
        self.port_to_flow.remove(&entry.local_port);
        self.udp_port_to_flow.remove(&entry.local_port);
        self.sockets.remove(entry.handle);
        self.poll_stack();
    }

    /// Accepts app->server bytes for `flow_id`, queuing them in order behind anything still
    /// waiting for tx-window space, then pumping as much as fits into smoltcp.
    ///
    /// `Ok` = bytes were buffered/sent (none dropped). `Permanent` = flow missing, socket in a
    /// terminal state (will never send again), or the per-flow buffer cap was hit — caller should
    /// push flowClosedPush to tear the source-app flow down. `Transient` = bytes were accepted
    /// (none dropped) but `pending_tx` crossed `TX_BACKPRESSURE_HIGH`; the caller should PAUSE
    /// feeding (pause UDS reads) until smoltcp drains — this is the tunnel-side upload backpressure
    /// signal, and `PacketTunnelRelayServer` relies on it (do not remove the branch). Pre-handshake
    /// bytes are still buffered here and drained by `pump_tx`, so `Transient` never means "retry
    /// these bytes" — the bytes are already held; it only means "stop sending more for now".
    ///
    /// Critically, the previous implementation called `send_slice` and discarded its return
    /// value; `send_slice` only accepts what fits in the tx buffer (TCP_TX_BUF), so a near-full window
    /// silently truncated the byte stream and corrupted the connection. Buffering the remainder
    /// here is what prevents that.
    pub fn send_tcp(&mut self, flow_id: u64, data: &[u8]) -> SendTcpResult {
        {
            let Some(entry) = self.flows.get_mut(&flow_id) else {
                return SendTcpResult::Permanent;
            };
            // A UDP flow's handle downcast to tcp::Socket would panic inside smoltcp.
            if entry.udp_remote.is_some() {
                return SendTcpResult::Permanent;
            }
            let socket = self.sockets.get::<tcp::Socket>(entry.handle);
            // Buffer while connecting (SynSent/SynReceived) or open (may_send covers
            // Established + CloseWait); refuse only when the socket can never send again.
            let can_accept = socket.may_send()
                || matches!(
                    socket.state(),
                    tcp::State::SynSent | tcp::State::SynReceived
                );
            if !can_accept {
                return SendTcpResult::Permanent;
            }
            // Hard safety cap. With the backpressure below pacing the proxy this should never be hit;
            // if it is (e.g. a wedged tunnel that never drains), fail closed rather than balloon memory.
            if entry.pending_tx.len().saturating_add(data.len()) > MAX_FLOW_TX_BUF {
                return SendTcpResult::Permanent;
            }
            entry.pending_tx.extend_from_slice(data);
        }
        // pump_all_tx + egress poll happen inside poll_stack.
        self.poll_stack();
        // Backpressure: the bytes ARE accepted (no loss). But if this flow's still-queued tx now sits
        // above the high-water mark, smoltcp/the network can't drain as fast as the proxy is feeding —
        // return Transient so the relay server pauses reading the UDS (which backpressures the proxy and
        // the source app) instead of letting pending_tx climb to MAX_FLOW_TX_BUF and tearing the flow
        // down. This is the end-to-end completion of the upload-fails fix.
        let pending = self
            .flows
            .get(&flow_id)
            .map(|e| e.pending_tx.len())
            .unwrap_or(0);
        if pending >= TX_BACKPRESSURE_HIGH {
            SendTcpResult::Transient
        } else {
            SendTcpResult::Ok
        }
    }

    pub fn drain_rx(
        &mut self,
        items: &mut [RelayRxItem],
        blob: &mut [u8],
    ) -> u32 {
        self.poll_stack();
        let mut item_count = 0usize;
        let mut blob_off = 0usize;
        for (flow_id, entry) in self.flows.iter_mut() {
            while let Some(chunk) = entry.pending_rx.pop_front() {
                if item_count >= items.len() || blob_off + chunk.len() > blob.len() {
                    entry.pending_rx.push_front(chunk);
                    break;
                }
                items[item_count] = RelayRxItem {
                    flow_id: *flow_id,
                    offset: blob_off as u32,
                    len: chunk.len() as u32,
                };
                blob[blob_off..blob_off + chunk.len()].copy_from_slice(&chunk);
                blob_off += chunk.len();
                item_count += 1;
            }
        }
        item_count as u32
    }
}

/// Internal tristate for `send_tcp`, mapped to i32 at the FFI boundary (1 / 0 / -1).
/// `Ok` = accepted, room remains. `Transient` = accepted, but `pending_tx` crossed the backpressure
/// high-water — the caller should pause feeding (pause UDS reads) until smoltcp drains. `Permanent` =
/// flow unknown or socket terminal; tear the flow down.
pub enum SendTcpResult {
    Ok,
    Transient,
    Permanent,
}

#[repr(C)]
pub struct RelayRxItem {
    pub flow_id: u64,
    pub offset: u32,
    pub len: u32,
}

fn parse_ipv4(s: *const c_char) -> Option<Ipv4Address> {
    if s.is_null() {
        return None;
    }
    let cstr = unsafe { std::ffi::CStr::from_ptr(s) };
    let octets: Vec<u8> = cstr
        .to_str()
        .ok()?
        .split('.')
        .map(|p| p.parse().ok())
        .collect::<Option<Vec<_>>>()?;
    if octets.len() != 4 {
        return None;
    }
    Some(Ipv4Address::new(octets[0], octets[1], octets[2], octets[3]))
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_new(
    tunnel_ipv4: *const c_char,
    mtu: u16,
) -> *mut TunnelbahnRelayBridge {
    let Some(ip) = parse_ipv4(tunnel_ipv4) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(TunnelbahnRelayBridge::new(ip, mtu)))
}

/// Per-flow smoltcp TCP receive-buffer size in bytes. This equals the advertised TCP window
/// (smoltcp derives the window-scale shift from it), so logging it at startup is a content-level
/// proof of WHICH relay build is actually running: 65536 = old 64 KiB cap (no scaling), 1048576 =
/// the window-scaling build. No bridge instance needed — it's a compile-time constant.
#[no_mangle]
pub extern "C" fn tunnelbahn_relay_tcp_window_bytes() -> u32 {
    TCP_RX_BUF as u32
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_free(bridge: *mut TunnelbahnRelayBridge) {
    if !bridge.is_null() {
        drop(Box::from_raw(bridge));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_should_intercept_rx(
    bridge: *const TunnelbahnRelayBridge,
    packet: *const u8,
    len: u32,
) -> i32 {
    let Some(bridge) = bridge.as_ref() else {
        return 0;
    };
    if packet.is_null() || len == 0 {
        return 0;
    }
    let slice = std::slice::from_raw_parts(packet, len as usize);
    i32::from(bridge.should_intercept_inbound(slice))
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_feed_rx_ip(
    bridge: *mut TunnelbahnRelayBridge,
    packet: *const u8,
    len: u32,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return -1;
    };
    if packet.is_null() || len == 0 {
        return -1;
    }
    let slice = std::slice::from_raw_parts(packet, len as usize);
    i32::from(bridge.feed_rx_ip(slice))
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_poll_tx_ip(
    bridge: *mut TunnelbahnRelayBridge,
    out: *mut u8,
    cap: u32,
    out_len: *mut u32,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return -1;
    };
    if out.is_null() || out_len.is_null() {
        return -1;
    }
    // Only run the (expensive) stack poll when the tx queue is empty: one poll fills the queue
    // with everything currently egressable, so the caller's drain loop pops packet-by-packet
    // without re-running iface.poll/pump/collect once per packet. When the queue drains, the
    // next call polls again and returns 0 if nothing new emerged, ending the loop.
    if bridge.device.tx_queue.is_empty() {
        bridge.poll_stack();
    }
    // Peek before popping: popping first and then failing the capacity check would drop the
    // packet and corrupt the TCP stream. On -2 the required size is reported via out_len so
    // the caller can grow its buffer and retry; the packet stays queued.
    let Some(pkt_len) = bridge.device.tx_queue.front().map(Vec::len) else {
        *out_len = 0;
        return 0;
    };
    if pkt_len > cap as usize {
        *out_len = pkt_len as u32;
        return -2;
    }
    let Some(pkt) = bridge.device.tx_queue.pop_front() else {
        *out_len = 0;
        return 0;
    };
    std::ptr::copy_nonoverlapping(pkt.as_ptr(), out, pkt.len());
    *out_len = pkt.len() as u32;
    1
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_open_tcp(
    bridge: *mut TunnelbahnRelayBridge,
    flow_id: u64,
    remote_ipv4: *const c_char,
    remote_port: u16,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return 0;
    };
    let Some(remote) = parse_ipv4(remote_ipv4) else {
        return 0;
    };
    i32::from(bridge.open_tcp(flow_id, remote, remote_port))
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_open_udp(
    bridge: *mut TunnelbahnRelayBridge,
    flow_id: u64,
    remote_ipv4: *const c_char,
    remote_port: u16,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return 0;
    };
    let Some(remote) = parse_ipv4(remote_ipv4) else {
        return 0;
    };
    i32::from(bridge.open_udp(flow_id, remote, remote_port))
}

/// Returns 1 if the flow exists and is UDP (the datagram was queued OR dropped-on-full — UDP
/// semantics, never an error), -1 if the flow is unknown or not UDP.
#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_send_udp(
    bridge: *mut TunnelbahnRelayBridge,
    flow_id: u64,
    data: *const u8,
    len: u32,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return -1;
    };
    if data.is_null() || len == 0 {
        return -1;
    }
    let slice = std::slice::from_raw_parts(data, len as usize);
    if bridge.send_udp(flow_id, slice) {
        1
    } else {
        -1
    }
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_close(
    bridge: *mut TunnelbahnRelayBridge,
    flow_id: u64,
) {
    if let Some(bridge) = bridge.as_mut() {
        bridge.close_flow(flow_id);
    }
}

/// Returns 1 if the bytes were accepted/buffered without loss (`SendTcpResult::Ok`), or -1 if
/// the flow does not exist, the socket is in a terminal state, or the per-flow tx buffer cap
/// was hit (`SendTcpResult::Permanent`) — in which case the proxy tears the flow down. 0
/// (`Transient`) means the bytes WERE accepted but `pending_tx` crossed the backpressure
/// high-water mark: the caller should pause feeding until smoltcp drains (the tunnel-side upload
/// backpressure signal `PacketTunnelRelayServer.applyReadBackpressure` depends on — do not drop
/// it). A null bridge / null data / zero len is reported as `Permanent`.
#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_send_tcp(
    bridge: *mut TunnelbahnRelayBridge,
    flow_id: u64,
    data: *const u8,
    len: u32,
) -> i32 {
    let Some(bridge) = bridge.as_mut() else {
        return -1;
    };
    if data.is_null() || len == 0 {
        return -1;
    }
    let slice = std::slice::from_raw_parts(data, len as usize);
    match bridge.send_tcp(flow_id, slice) {
        SendTcpResult::Ok => 1,
        SendTcpResult::Transient => 0,
        SendTcpResult::Permanent => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_drain_rx(
    bridge: *mut TunnelbahnRelayBridge,
    items: *mut RelayRxItem,
    max_items: u32,
    blob: *mut u8,
    blob_cap: u32,
) -> u32 {
    let Some(bridge) = bridge.as_mut() else {
        return 0;
    };
    if items.is_null() || blob.is_null() || max_items == 0 || blob_cap == 0 {
        return 0;
    }
    let items_slice =
        std::slice::from_raw_parts_mut(items, max_items.min(MAX_DRAIN_ITEMS as u32) as usize);
    let blob_slice =
        std::slice::from_raw_parts_mut(blob, blob_cap.min(MAX_DRAIN_BLOB as u32) as usize);
    bridge.drain_rx(items_slice, blob_slice)
}

/// Pops up to `max` flow IDs whose remote peer closed (FIN/RST) after all their received bytes
/// were surfaced via `tunnelbahn_relay_drain_rx` (see `collect_tcp_rx`). Call AFTER drain_rx so
/// a close event never precedes the flow's final payload bytes.
#[no_mangle]
pub unsafe extern "C" fn tunnelbahn_relay_drain_closed(
    bridge: *mut TunnelbahnRelayBridge,
    out: *mut u64,
    max: u32,
) -> u32 {
    let Some(bridge) = bridge.as_mut() else {
        return 0;
    };
    if out.is_null() || max == 0 {
        return 0;
    }
    let n = bridge.closed_flows.len().min(max as usize);
    let out_slice = std::slice::from_raw_parts_mut(out, n);
    for (i, flow_id) in bridge.closed_flows.drain(..n).enumerate() {
        out_slice[i] = flow_id;
    }
    n as u32
}

#[cfg(test)]
mod udp_tests {
    use super::*;
    use smoltcp::wire::{IpProtocol, Ipv4Packet, UdpPacket};

    const TUNNEL_IP: Ipv4Address = Ipv4Address::new(10, 9, 0, 2);
    const REMOTE_IP: Ipv4Address = Ipv4Address::new(1, 1, 1, 1);

    fn new_bridge() -> TunnelbahnRelayBridge {
        TunnelbahnRelayBridge::new(TUNNEL_IP, 1380)
    }

    /// Pull every queued outbound IP packet out of the stack (mirrors poll_tx_ip's drain loop).
    fn drain_tx(b: &mut TunnelbahnRelayBridge) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            if b.device.tx_queue.is_empty() {
                b.poll_stack();
            }
            match b.device.tx_queue.pop_front() {
                Some(p) => out.push(p),
                None => break,
            }
        }
        out
    }

    /// Build an inbound IPv4/UDP packet remote:sport -> tunnel_ip:dport with `payload`.
    fn build_udp_ip(sport: u16, dport: u16, payload: &[u8]) -> Vec<u8> {
        use smoltcp::wire::{Ipv4Repr, UdpRepr};
        let udp_repr = UdpRepr { src_port: sport, dst_port: dport };
        let ip_repr = Ipv4Repr {
            src_addr: REMOTE_IP,
            dst_addr: TUNNEL_IP,
            next_header: IpProtocol::Udp,
            payload_len: udp_repr.header_len() + payload.len(),
            hop_limit: 64,
        };
        let mut buf = vec![0u8; ip_repr.buffer_len() + udp_repr.header_len() + payload.len()];
        let mut ipv4 = Ipv4Packet::new_unchecked(&mut buf);
        ip_repr.emit(&mut ipv4, &smoltcp::phy::ChecksumCapabilities::default());
        let mut udp = UdpPacket::new_unchecked(ipv4.payload_mut());
        udp_repr.emit(
            &mut udp,
            &IpAddress::Ipv4(REMOTE_IP),
            &IpAddress::Ipv4(TUNNEL_IP),
            payload.len(),
            |b| b.copy_from_slice(payload),
            &smoltcp::phy::ChecksumCapabilities::default(),
        );
        buf
    }

    #[test]
    fn open_and_send_emits_udp_packet_to_remote() {
        let mut b = new_bridge();
        assert!(b.open_udp(7, REMOTE_IP, 53));
        let query = b"hello-dns-query";
        assert!(b.send_udp(7, query));

        let pkts = drain_tx(&mut b);
        let found = pkts.iter().find_map(|p| {
            let ip = Ipv4Packet::new_checked(p.as_slice()).ok()?;
            if ip.next_header() != IpProtocol::Udp {
                return None;
            }
            let udp = UdpPacket::new_checked(ip.payload()).ok()?;
            Some((ip.src_addr(), ip.dst_addr(), udp.dst_port(), udp.payload().to_vec()))
        });
        let (src, dst, dport, payload) = found.expect("no UDP packet egressed");
        assert_eq!(src, TUNNEL_IP);
        assert_eq!(dst, REMOTE_IP);
        assert_eq!(dport, 53);
        assert_eq!(payload, query);
    }

    #[test]
    fn inbound_udp_response_surfaces_on_flow() {
        let mut b = new_bridge();
        assert!(b.open_udp(9, REMOTE_IP, 53));
        assert!(b.send_udp(9, b"q"));
        // Find the local (ephemeral) port the flow bound.
        let sport = drain_tx(&mut b)
            .iter()
            .find_map(|p| {
                let ip = Ipv4Packet::new_checked(p.as_slice()).ok()?;
                let udp = UdpPacket::new_checked(ip.payload()).ok()?;
                if ip.next_header() == IpProtocol::Udp { Some(udp.src_port()) } else { None }
            })
            .expect("no egress to learn local port");

        let response = b"dns-answer-bytes";
        let ip_pkt = build_udp_ip(53, sport, response);
        assert!(b.feed_rx_ip(&ip_pkt), "response should be intercepted");

        let mut items: Vec<RelayRxItem> =
            (0..8).map(|_| RelayRxItem { flow_id: 0, offset: 0, len: 0 }).collect();
        let mut blob = vec![0u8; 4096];
        let n = b.drain_rx(&mut items, &mut blob) as usize;
        assert_eq!(n, 1, "exactly one datagram should surface");
        assert_eq!(items[0].flow_id, 9);
        let start = items[0].offset as usize;
        let end = start + items[0].len as usize;
        assert_eq!(&blob[start..end], response);
    }

    #[test]
    fn send_tcp_on_udp_flow_is_permanent_not_panic() {
        let mut b = new_bridge();
        assert!(b.open_udp(11, REMOTE_IP, 53));
        assert!(matches!(b.send_tcp(11, b"x"), SendTcpResult::Permanent));
    }

    #[test]
    fn send_udp_on_missing_flow_fails() {
        let mut b = new_bridge();
        assert!(!b.send_udp(999, b"x"));
    }

    #[test]
    fn tcp_and_udp_share_port_namespace_no_collision() {
        let mut b = new_bridge();
        assert!(b.open_tcp(1, REMOTE_IP, 443));
        assert!(b.open_udp(2, REMOTE_IP, 53));
        // Distinct local ports allocated across both maps.
        let tcp_port = b.flows[&1].local_port;
        let udp_port = b.flows[&2].local_port;
        assert_ne!(tcp_port, udp_port);
    }
}
