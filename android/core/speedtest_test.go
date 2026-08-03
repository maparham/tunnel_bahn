package core

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestUploadLadder(t *testing.T) {
	if stInitialUploadBytes() != 256*1024 {
		t.Fatalf("initial = %d", stInitialUploadBytes())
	}
	if stNextUploadBytes(256*1024) != 1024*1024 {
		t.Fatal("256K -> 1M")
	}
	if stNextUploadBytes(4*1024*1024) != 16*1024*1024 {
		t.Fatal("4M -> 16M")
	}
	if stNextUploadBytes(16*1024*1024) != 16*1024*1024 {
		t.Fatal("cap stays at 16M")
	}
	if stNextUploadBytes(99*1024*1024) != 16*1024*1024 {
		t.Fatal("above cap stays at 16M")
	}
}

func TestWindow(t *testing.T) {
	if stWindow(399) != 8*time.Second {
		t.Fatal("below threshold -> 8s")
	}
	if stWindow(400) != 16*time.Second {
		t.Fatal("at threshold -> 16s")
	}
}

// stubSink records the final result and any error for assertions.
type stubSink struct {
	mu     sync.Mutex
	result *[4]float64
	errMsg string
	phases []string
}

func (s *stubSink) OnPhase(n string) { s.mu.Lock(); s.phases = append(s.phases, n); s.mu.Unlock() }
func (s *stubSink) OnLatencySummary(m, j float64) {}
func (s *stubSink) OnSample(phase string, off float64, b int64) {}
func (s *stubSink) OnResult(d, u, m, j float64) {
	s.mu.Lock()
	s.result = &[4]float64{d, u, m, j}
	s.mu.Unlock()
}
func (s *stubSink) OnError(msg string) { s.mu.Lock(); s.errMsg = msg; s.mu.Unlock() }

// newLocalCloudflare fakes the three Cloudflare endpoints over TLS so runSpeedTest can be
// exercised end to end without the network.
func newLocalCloudflare() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/__down", func(w http.ResponseWriter, r *http.Request) {
		// bytes=0 -> latency ping; bytes=N -> stream N zero bytes.
		n := 0
		if v := r.URL.Query().Get("bytes"); v != "" {
			// small body keeps the test fast; the engine streams whatever arrives.
			if v == "50000000" {
				n = 1 << 20 // 1 MiB per request is plenty for accounting
			}
		}
		w.WriteHeader(200)
		if n > 0 {
			w.Write(make([]byte, n))
		}
	})
	mux.HandleFunc("/__up", func(w http.ResponseWriter, r *http.Request) {
		io_CopyDiscard(r.Body)
		w.WriteHeader(200)
	})
	return httptest.NewTLSServer(mux)
}

func TestRunSpeedTestAccounting(t *testing.T) {
	srv := newLocalCloudflare()
	defer srv.Close()

	// Point the engine's URLs at the local server for this test.
	restore := overrideSpeedTestURLs(srv.URL)
	defer restore()

	// dialTLS that trusts the test server's cert and ignores the real host.
	dial := func(ctx context.Context, addr string) (net.Conn, error) {
		return tls.Dial("tcp", srv.Listener.Addr().String(),
			&tls.Config{InsecureSkipVerify: true})
	}

	sink := &stubSink{}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	if err := runSpeedTest(ctx, dial, sink); err != nil {
		t.Fatalf("runSpeedTest: %v", err)
	}
	if sink.result == nil {
		t.Fatal("no result emitted")
	}
	if sink.result[0] <= 0 || sink.result[1] <= 0 {
		t.Fatalf("download/upload must be > 0, got %v", sink.result)
	}
}
