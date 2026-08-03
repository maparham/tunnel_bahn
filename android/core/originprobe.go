package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// ProbeOrigin fetches the device's real (pre-VPN) IP + geo over a plain direct socket.
// It is session-independent: the app's own sockets bypass the tunnel in every routing
// mode, so this returns the true carrier IP whether or not a tunnel is running. Blocking;
// call off the main thread. Reuses the ipinfo provider + parser shared with the exit probe.
func ProbeOrigin(ctx context.Context) (ip, city, country string, err error) {
	client := &http.Client{Timeout: 15 * time.Second}
	return probeOriginAt(ctx, ipinfoURL, client)
}

func probeOriginAt(ctx context.Context, url string, client *http.Client) (ip, city, country string, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", "", "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "TunnelBahn-Android/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return "", "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", "", fmt.Errorf("origin probe: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return "", "", "", err
	}
	ip, city, country, err = parseIPInfo(body)
	if err != nil {
		return "", "", "", err
	}
	if ip == "" {
		return "", "", "", fmt.Errorf("origin probe: empty ip")
	}
	return ip, city, country, nil
}
