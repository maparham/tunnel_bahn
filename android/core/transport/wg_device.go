package transport

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"

	"tunnelbahn/core/wstunnel"
)

// WGConfig configures a userspace WireGuard device. Shared by the plain-UDP (WG) and
// WireGuard-over-wstunnel (WGWS) transports.
type WGConfig struct {
	PrivateKey       string // standard-base64 32-byte key
	PeerPublicKey    string // standard-base64 32-byte key
	PeerPresharedKey string // optional standard-base64 32-byte key
	LocalAddrs       []netip.Addr
	DNS              []netip.Addr
	MTU              int
	Keepalive        int // persistent keepalive seconds; 0 => 25
	Relay            *wstunnel.Relay // WGWS only; nil for plain WG
}

const defaultKeepalive = 25

// newWGDevice creates the netstack TUN and the wireguard-go device over bind, applies
// the uapi config with the given peer endpoint, and brings the device up. On any
// failure it closes what it created and returns the error. It performs no network I/O.
func newWGDevice(cfg WGConfig, bind conn.Bind, endpoint string) (*device.Device, *netstack.Net, error) {
	tunDev, tnet, err := netstack.CreateNetTUN(cfg.LocalAddrs, cfg.DNS, mtuOrDefault(cfg.MTU))
	if err != nil {
		return nil, nil, err
	}
	dev := device.NewDevice(tunDev, bind, device.NewLogger(device.LogLevelError, "wg "))
	uapi, err := uapiConfig(cfg, endpoint)
	if err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err := dev.IpcSet(uapi); err != nil {
		dev.Close()
		return nil, nil, err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, nil, err
	}
	return dev, tnet, nil
}

// handshakeAge reports how long ago the peer's last handshake completed, read from the
// device's uapi "last_handshake_time_sec" line. ok is false until the first handshake.
func handshakeAge(dev *device.Device, now time.Time) (time.Duration, bool) {
	uapi, err := dev.IpcGet()
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(uapi, "\n") {
		v, found := strings.CutPrefix(line, "last_handshake_time_sec=")
		if !found {
			continue
		}
		sec, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil || sec == 0 {
			return 0, false
		}
		return now.Sub(time.Unix(sec, 0)), true
	}
	return 0, false
}

// waitHandshake blocks until the peer completes its first handshake (proving the
// tunnel actually reaches the server), or ctx is done. dialErr, if non-nil, is polled
// so a carrier that failed to dial surfaces immediately instead of idling until the
// deadline.
func waitHandshake(ctx context.Context, dev *device.Device, dialErr func() error) error {
	t := time.NewTicker(150 * time.Millisecond)
	defer t.Stop()
	for {
		if _, ok := handshakeAge(dev, time.Now()); ok {
			return nil
		}
		if dialErr != nil {
			if err := dialErr(); err != nil {
				return err
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
		}
	}
}

func mtuOrDefault(m int) int {
	if m <= 0 {
		return 1280
	}
	return m
}

func keepaliveOrDefault(k int) int {
	if k <= 0 {
		return defaultKeepalive
	}
	return k
}

// uapiConfig builds the wireguard-go IpcSet string. WG keys arrive standard-base64
// (the format the macOS profile stores) and must be converted to hex for uapi.
// endpoint must be a resolved ip:port; uapi does not accept hostnames.
func uapiConfig(cfg WGConfig, endpoint string) (string, error) {
	priv, err := keyHex(cfg.PrivateKey)
	if err != nil {
		return "", fmt.Errorf("private key: %w", err)
	}
	pub, err := keyHex(cfg.PeerPublicKey)
	if err != nil {
		return "", fmt.Errorf("peer public key: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	if cfg.PeerPresharedKey != "" {
		psk, err := keyHex(cfg.PeerPresharedKey)
		if err != nil {
			return "", fmt.Errorf("preshared key: %w", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	fmt.Fprintf(&b, "endpoint=%s\n", endpoint)
	fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", keepaliveOrDefault(cfg.Keepalive))
	fmt.Fprintf(&b, "allowed_ip=0.0.0.0/0\n")
	fmt.Fprintf(&b, "allowed_ip=::/0\n")
	return b.String(), nil
}

func keyHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("want 32-byte key, got %d", len(raw))
	}
	return hex.EncodeToString(raw), nil
}
