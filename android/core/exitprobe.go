package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"time"

	"tunnelbahn/core/transport"
)

// ipinfoHost is the geo provider queried through the tunnel. Unauthenticated /json is
// sufficient for personal use; swapping providers touches only these two constants.
const (
	ipinfoHost = "ipinfo.io"
	ipinfoURL  = "https://ipinfo.io/json"
)

type ipInfo struct {
	IP      string `json:"ip"`
	City    string `json:"city"`
	Country string `json:"country"`
}

func parseIPInfo(body []byte) (ip, city, country string, err error) {
	var v ipInfo
	if err = json.Unmarshal(body, &v); err != nil {
		return "", "", "", err
	}
	return v.IP, v.City, v.Country, nil
}

// runExitProbe fetches the exit IP + geo once, through the transport (so it reflects the
// real server egress and never bypasses the VPN), retrying a few times on failure. It is
// launched as a goroutine and returns when it succeeds, exhausts retries, or ctx is done.
func runExitProbe(ctx context.Context, tr transport.Transport, sink EventSink) {
	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			// Dial the carrier through the tunnel transport, then real TLS to ipinfo.
			DialTLSContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
				ap, err := resolveIPInfoAddrPort(ctx, addr)
				if err != nil {
					return nil, err
				}
				raw, err := tr.DialTCP(ctx, ap)
				if err != nil {
					return nil, err
				}
				// addr is always ipinfoHost:443 (our own fixed URL), so pin SNI to the host.
				tlsConn := tls.Client(raw, &tls.Config{ServerName: ipinfoHost})
				if err := tlsConn.HandshakeContext(ctx); err != nil {
					raw.Close()
					return nil, err
				}
				return tlsConn, nil
			},
		},
	}

	backoff := time.Second
	for attempt := 0; attempt < 3; attempt++ {
		if ctx.Err() != nil {
			return
		}
		if tryExitProbe(ctx, client, sink) {
			return
		}
		if attempt == 2 {
			return // retries exhausted; do not idle in a trailing backoff nobody waits on
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
			backoff *= 2
		}
	}
}

func tryExitProbe(ctx context.Context, client *http.Client, sink EventSink) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ipinfoURL, nil)
	if err != nil {
		return false
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "TunnelBahn-Android/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return false
	}
	ip, city, country, err := parseIPInfo(body)
	if err != nil || ip == "" {
		return false
	}
	if sink != nil {
		sink.OnExitInfo(ip, city, country)
	}
	return true
}

// resolveIPInfoAddrPort turns the ipinfo host:port into a netip.AddrPort for the
// transport's DialTCP. Only the A-record lookup uses the default resolver (metadata,
// not the payload); the probe response itself still egresses through the tunnel.
func resolveIPInfoAddrPort(ctx context.Context, addr string) (netip.AddrPort, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		host, port = ipinfoHost, "443"
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
	if err != nil {
		return netip.AddrPort{}, err
	}
	if len(ips) == 0 {
		return netip.AddrPort{}, &net.DNSError{Err: "no A record", Name: host}
	}
	p, err := strconv.Atoi(port)
	if err != nil {
		return netip.AddrPort{}, err
	}
	return netip.AddrPortFrom(ips[0], uint16(p)), nil
}
