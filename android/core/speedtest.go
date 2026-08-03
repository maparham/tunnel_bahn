package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"tunnelbahn/core/transport"
)

const (
	stHost = "speed.cloudflare.com"

	stLatencyAttempts   = 9 // first discarded as warmup
	stMinLatencySuccess = 5
	stDownloadStreams   = 4
	stUploadStreams     = 2
	stSampleInterval    = 250 * time.Millisecond
)

// URLs are vars (not consts) so tests can point them at a local server.
var (
	stLatencyURL  = "https://speed.cloudflare.com/__down?bytes=0"
	stDownloadURL = "https://speed.cloudflare.com/__down?bytes=50000000"
	stUploadURL   = "https://speed.cloudflare.com/__up"
)

// overrideSpeedTestURLs points the endpoints at base for tests; call restore to undo.
func overrideSpeedTestURLs(base string) func() {
	l, d, u := stLatencyURL, stDownloadURL, stUploadURL
	stLatencyURL = base + "/__down?bytes=0"
	stDownloadURL = base + "/__down?bytes=50000000"
	stUploadURL = base + "/__up"
	return func() { stLatencyURL, stDownloadURL, stUploadURL = l, d, u }
}

func io_CopyDiscard(r io.Reader) { _, _ = io.Copy(io.Discard, r) }

// stUploadLadder: bodies start small so slow paths complete several per window, and
// grow so fast paths are not request-rate bound; the cap bounds the prebuilt buffer.
var stUploadLadder = []int{256 * 1024, 1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024}

func stInitialUploadBytes() int { return stUploadLadder[0] }

// stNextUploadBytes returns the next rung above completed, staying at the cap once reached.
func stNextUploadBytes(after int) int {
	for _, s := range stUploadLadder {
		if s > after {
			return s
		}
	}
	return stUploadLadder[len(stUploadLadder)-1]
}

// stWindow: high-RTT paths spend seconds in TCP slow start, dragging the whole-window
// average down; a longer window dilutes the ramp.
func stWindow(medianMs float64) time.Duration {
	if medianMs >= 400 {
		return 16 * time.Second
	}
	return 8 * time.Second
}

// SpeedTestSink streams progress to the Android layer. Methods take only gomobile-safe types.
type SpeedTestSink interface {
	OnPhase(name string)
	OnLatencySummary(medianMs, jitterMs float64)
	OnSample(phase string, offsetSeconds float64, bytes int64)
	OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64)
	OnError(msg string)
}

// dialTLSFunc returns a ready TLS connection to addr ("host:port").
type dialTLSFunc func(ctx context.Context, addr string) (net.Conn, error)

// tunnelDialTLS dials Cloudflare through the transport, mirroring exitprobe.go: resolve
// the A-record with the default resolver (metadata only), dial via the transport, then TLS.
func tunnelDialTLS(tr transport.Transport) dialTLSFunc {
	return func(ctx context.Context, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			host, port = stHost, "443"
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", host)
		if err != nil {
			return nil, err
		}
		if len(ips) == 0 {
			return nil, fmt.Errorf("no A record for %s", host)
		}
		p, err := strconv.Atoi(port)
		if err != nil {
			return nil, err
		}
		raw, err := tr.DialTCP(ctx, netip.AddrPortFrom(ips[0], uint16(p)))
		if err != nil {
			return nil, err
		}
		tlsConn := tls.Client(raw, &tls.Config{ServerName: host})
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		return tlsConn, nil
	}
}

// directDialTLS dials with a plain dialer; the app is disallowed from its own tun, so this
// egresses directly (no protect needed).
func directDialTLS() dialTLSFunc {
	d := &net.Dialer{Timeout: 15 * time.Second}
	return func(ctx context.Context, addr string) (net.Conn, error) {
		raw, err := d.DialContext(ctx, "tcp", addr)
		if err != nil {
			return nil, err
		}
		host, _, err := net.SplitHostPort(addr)
		if err != nil {
			host = stHost
		}
		tlsConn := tls.Client(raw, &tls.Config{ServerName: host})
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, err
		}
		return tlsConn, nil
	}
}

func newSpeedTestClient(dial dialTLSFunc) *http.Client {
	return &http.Client{
		// No overall timeout: transfer requests run for the whole window, bounded by ctx.
		Transport: &http.Transport{
			DialTLSContext:     func(ctx context.Context, _, addr string) (net.Conn, error) { return dial(ctx, addr) },
			DisableCompression: true,
		},
	}
}

// runSpeedTest runs latency -> download -> upload over dial, streaming progress to sink.
// A returned error is delivered via sink.OnError EXCEPT on cancellation (mirrors macOS's
// silent `catch is CancellationError`), so an auto-cancel's own message is not clobbered.
func runSpeedTest(ctx context.Context, dial dialTLSFunc, sink SpeedTestSink) error {
	client := newSpeedTestClient(dial)
	defer client.CloseIdleConnections()

	// reportErr surfaces a phase error unless it is a cancellation.
	reportErr := func(err error) error {
		if !errors.Is(err, context.Canceled) {
			sink.OnError(err.Error())
		}
		return err
	}

	sink.OnPhase("latency")
	med, jit, err := measureLatency(ctx, client, sink)
	if err != nil {
		return reportErr(err)
	}
	sink.OnLatencySummary(med, jit)
	window := stWindow(med)

	sink.OnPhase("download")
	dl, err := measureTransfer(ctx, client, "download", window, sink)
	if err != nil {
		return reportErr(err)
	}

	sink.OnPhase("upload")
	ul, err := measureTransfer(ctx, client, "upload", window, sink)
	if err != nil {
		return reportErr(err)
	}

	sink.OnResult(dl, ul, med, jit)
	return nil
}

func measureLatency(ctx context.Context, client *http.Client, sink SpeedTestSink) (float64, float64, error) {
	var samples []float64
	var lastErr error
	for attempt := 1; attempt <= stLatencyAttempts; attempt++ {
		if ctx.Err() != nil {
			return 0, 0, ctx.Err()
		}
		rctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		t0 := time.Now()
		req, _ := http.NewRequestWithContext(rctx, http.MethodGet, stLatencyURL, nil)
		resp, err := client.Do(req)
		if err != nil {
			cancel()
			if ctx.Err() != nil {
				return 0, 0, ctx.Err()
			}
			lastErr = err
			continue
		}
		io_CopyDiscard(resp.Body)
		resp.Body.Close()
		cancel()
		ms := float64(time.Since(t0).Microseconds()) / 1000.0
		if attempt > 1 { // discard first as TLS/connection warmup
			samples = append(samples, ms)
			sink.OnSample("latency", 0, int64(ms)) // during "latency", bytes carries round-trip ms
		}
	}
	if len(samples) < stMinLatencySuccess {
		if lastErr != nil {
			return 0, 0, lastErr
		}
		return 0, 0, fmt.Errorf("latency probes failed")
	}
	m, _ := median(samples)
	j, _ := jitter(samples)
	return m, j, nil
}

// measureTransfer runs parallel streams for the window, sampling credited bytes every
// 0.25s. Streams restart on completion to stay saturated. Upload credits a body only on a
// clean 2xx completion. Returns the whole-window average Mbps.
func measureTransfer(ctx context.Context, client *http.Client, phase string, window time.Duration, sink SpeedTestSink) (float64, error) {
	var counted atomic.Int64
	var badStatus atomic.Int32 // first non-2xx status; 0 = none

	wctx, cancel := context.WithTimeout(ctx, window)
	defer cancel()

	var body []byte
	streams := stDownloadStreams
	if phase == "upload" {
		streams = stUploadStreams
		body = make([]byte, stUploadLadder[len(stUploadLadder)-1])
		_, _ = rand.Read(body) // incompressible so transparent compression cannot inflate the rate
	}

	start := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < streams; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			completed := -1
			for wctx.Err() == nil {
				if phase == "download" {
					if bad := doDownload(wctx, client, &counted); bad != 0 {
						badStatus.CompareAndSwap(0, int32(bad))
						return
					}
				} else {
					size := stInitialUploadBytes()
					if completed >= 0 {
						size = stNextUploadBytes(completed)
					}
					ok, bad := doUpload(wctx, client, body[:size])
					if bad != 0 {
						badStatus.CompareAndSwap(0, int32(bad))
						return
					}
					if ok {
						counted.Add(int64(size))
						completed = size
					}
				}
			}
		}()
	}

	sampleDone := make(chan struct{})
	go func() {
		defer close(sampleDone)
		t := time.NewTicker(stSampleInterval)
		defer t.Stop()
		for {
			select {
			case <-wctx.Done():
				return
			case <-t.C:
				sink.OnSample(phase, time.Since(start).Seconds(), counted.Load())
			}
		}
	}()

	wg.Wait()
	<-sampleDone
	elapsed := time.Since(start).Seconds()

	if bad := badStatus.Load(); bad != 0 {
		return 0, fmt.Errorf("server rejected the request (HTTP %d)", bad)
	}
	if ctx.Err() != nil { // external cancel, not the window deadline
		return 0, ctx.Err()
	}
	total := counted.Load()
	if total <= 0 {
		if phase == "download" {
			return 0, fmt.Errorf("no data received")
		}
		return 0, fmt.Errorf("no upload completed within the measurement window")
	}
	return throughputMbps(total, elapsed), nil
}

// doDownload streams one response body into counted. Returns a non-zero HTTP status on a
// non-2xx response, else 0. Transport/cancel errors return 0 (the stream just restarts).
func doDownload(ctx context.Context, client *http.Client, counted *atomic.Int64) int {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, stDownloadURL, nil)
	resp, err := client.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		io_CopyDiscard(resp.Body)
		return resp.StatusCode
	}
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			counted.Add(int64(n))
		}
		if err != nil {
			return 0
		}
	}
}

// doUpload POSTs body and reports whether it completed cleanly (2xx). Returns a non-zero
// status on a non-2xx response.
func doUpload(ctx context.Context, client *http.Client, body []byte) (bool, int) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, stUploadURL, bytes.NewReader(body))
	req.ContentLength = int64(len(body))
	resp, err := client.Do(req)
	if err != nil {
		return false, 0
	}
	defer resp.Body.Close()
	io_CopyDiscard(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return false, resp.StatusCode
	}
	return true, 0
}

// DirectSpeedTest runs the engine over a plain (bypass) dialer, independent of any session.
type DirectSpeedTest struct {
	mu     sync.Mutex
	cancel context.CancelFunc
}

func NewDirectSpeedTest() *DirectSpeedTest { return &DirectSpeedTest{} }

func (d *DirectSpeedTest) Run(sink SpeedTestSink) error {
	ctx, cancel := context.WithCancel(context.Background())
	d.mu.Lock()
	d.cancel = cancel
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		d.cancel = nil
		d.mu.Unlock()
		cancel()
	}()
	return runSpeedTest(ctx, directDialTLS(), sink)
}

func (d *DirectSpeedTest) Cancel() {
	d.mu.Lock()
	c := d.cancel
	d.mu.Unlock()
	if c != nil {
		c()
	}
}
