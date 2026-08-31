// Package mobile is the gomobile-bound entry point. gomobile only emits proxy
// classes for types defined in the bound package itself, so the exported surface is
// declared concretely here and delegates to tunnelbahn/core via thin adapters.
package mobile

import (
	"context"
	"tunnelbahn/core"
)

// Protector wraps VpnService.protect(fd). Implemented in Kotlin.
type Protector interface {
	Protect(fd int) error
}

// EventSink receives connection lifecycle strings. Implemented in Kotlin.
type EventSink interface {
	OnState(state string)
	OnError(msg string)
	OnHostKey(line string)
	OnExitInfo(ip, city, country string)
}

// Session is the tunnel session facade.
type Session struct {
	inner *core.Session
}

// NewSession creates a new, unstarted session.
func NewSession() *Session { return &Session{inner: core.NewSession()} }

// Start builds the transport, opens the tun engine, and blocks until Stop.
func (s *Session) Start(tunFD int, configJSON string, prot Protector, sink EventSink) error {
	return s.inner.Start(tunFD, configJSON, protectorAdapter{prot}, sinkAdapter{sink})
}

// Stop tears the tunnel down and unblocks Start.
func (s *Session) Stop() { s.inner.Stop() }

// RxBytes/TxBytes report cumulative tunneled bytes (download/upload) for the poller.
func (s *Session) RxBytes() int64 { return s.inner.RxBytes() }
func (s *Session) TxBytes() int64 { return s.inner.TxBytes() }

type protectorAdapter struct{ p Protector }

func (a protectorAdapter) Protect(fd int) error { return a.p.Protect(fd) }

type sinkAdapter struct{ s EventSink }

func (a sinkAdapter) OnState(state string)  { a.s.OnState(state) }
func (a sinkAdapter) OnError(msg string)    { a.s.OnError(msg) }
func (a sinkAdapter) OnHostKey(line string) { a.s.OnHostKey(line) }
func (a sinkAdapter) OnExitInfo(ip, city, country string) {
	a.s.OnExitInfo(ip, city, country)
}

// SpeedTestSink receives speed-test progress. Implemented in Kotlin.
type SpeedTestSink interface {
	OnPhase(name string)
	OnLatencySummary(medianMs, jitterMs float64)
	OnSample(phase string, offsetSeconds float64, bytes int64)
	OnResult(downloadMbps, uploadMbps, medianLatencyMs, jitterMs float64)
	OnError(msg string)
}

type speedTestSinkAdapter struct{ s SpeedTestSink }

func (a speedTestSinkAdapter) OnPhase(n string)                      { a.s.OnPhase(n) }
func (a speedTestSinkAdapter) OnLatencySummary(m, j float64)         { a.s.OnLatencySummary(m, j) }
func (a speedTestSinkAdapter) OnSample(p string, o float64, b int64) { a.s.OnSample(p, o, b) }
func (a speedTestSinkAdapter) OnResult(d, u, m, j float64)           { a.s.OnResult(d, u, m, j) }
func (a speedTestSinkAdapter) OnError(msg string)                    { a.s.OnError(msg) }

// RunSpeedTest runs the tunnel-path speed test. Blocking; call off the main thread.
func (s *Session) RunSpeedTest(sink SpeedTestSink) error {
	return s.inner.RunTunnelSpeedTest(speedTestSinkAdapter{sink})
}

// CancelSpeedTest cancels an in-flight tunnel speed test.
func (s *Session) CancelSpeedTest() { s.inner.CancelSpeedTest() }

// DirectSpeedTest runs the direct-path speed test, independent of a session.
type DirectSpeedTest struct{ inner *core.DirectSpeedTest }

func NewDirectSpeedTest() *DirectSpeedTest { return &DirectSpeedTest{inner: core.NewDirectSpeedTest()} }

// Run runs the direct-path speed test. Blocking; call off the main thread.
func (d *DirectSpeedTest) Run(sink SpeedTestSink) error {
	return d.inner.Run(speedTestSinkAdapter{sink})
}

func (d *DirectSpeedTest) Cancel() { d.inner.Cancel() }

// LogText returns the diagnostic log as newline-separated lines, oldest first. The
// buffer lives in the core package rather than on a Session, so it still explains a
// connect attempt after that attempt failed and tore its session down.
func LogText() string { return core.LogText() }

// ClearLog empties the diagnostic log.
func ClearLog() { core.ClearLog() }

// Log appends one line from the Android layer, so service and UI lifecycle events
// interleave with the core's own lines in a single ordered view.
func Log(msg string) { core.Log(msg) }

// OriginInfo is the pre-VPN IP + geo, returned by ProbeOrigin. Fields are named Ip (not
// IP) so gomobile emits getIp()/getCity()/getCountry() and Kotlin sees .ip/.city/.country.
type OriginInfo struct {
	Ip      string
	City    string
	Country string
}

// ProbeOrigin fetches the device's real (pre-VPN) IP + geo. Blocking; call off the main
// thread. Returns an error the Kotlin side can catch and treat as "not yet known".
func ProbeOrigin() (*OriginInfo, error) {
	ip, city, country, err := core.ProbeOrigin(context.Background())
	if err != nil {
		return nil, err
	}
	return &OriginInfo{Ip: ip, City: city, Country: country}, nil
}
