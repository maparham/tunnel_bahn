package wstunnel

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"
)

// DialFunc dials the underlying TCP carrier. The caller supplies a protect()ed dialer
// so the raw socket egresses directly and does not route back into the tunnel.
type DialFunc func(ctx context.Context, network, addr string) (net.Conn, error)

type Config struct {
	WSURL       string // full ws:// or wss:// URL including the /<path>/events suffix
	ForwardHost string // wstunnel forward target host (the local WG relay listen host)
	ForwardPort int    // wstunnel forward target port
	TLSConfig   *tls.Config
}

// Relay carries UDP datagrams to a wstunnel v10 server as unmasked WebSocket binary
// frames. It dials lazily on the first Send.
type Relay struct {
	cfg   Config
	dial  DialFunc
	inbox chan []byte

	once sync.Once
	err  error

	writeMu sync.Mutex

	done chan struct{} // closed by Close to break the reconnect backoff promptly

	stateMu       sync.Mutex
	conn          net.Conn
	br            *bufio.Reader
	closed        bool
	readStarted   bool
	dialAttempted bool
	dialErr       error
}

func NewRelay(cfg Config, dial DialFunc) *Relay {
	return &Relay{cfg: cfg, dial: dial, inbox: make(chan []byte, 256), done: make(chan struct{})}
}

func (r *Relay) ensure(ctx context.Context) error {
	r.once.Do(func() {
		r.err = r.open(ctx)
		// Publish the outcome under stateMu so DialErr can read it race-free from
		// another goroutine (the readiness gate) while WG drives this dial.
		r.stateMu.Lock()
		r.dialAttempted = true
		r.dialErr = r.err
		r.stateMu.Unlock()
		if r.err == nil {
			go r.readLoop()
		}
	})
	return r.err
}

// DialErr reports the result of the one-shot carrier dial: nil if the dial has not
// been attempted yet or succeeded, or the dial error if it failed. WG's keepalive
// drives the first dial on device Up, so a readiness gate can poll this to fail fast
// when the server is unreachable instead of waiting out a handshake timeout.
func (r *Relay) DialErr() error {
	r.stateMu.Lock()
	defer r.stateMu.Unlock()
	if !r.dialAttempted {
		return nil
	}
	return r.dialErr
}

func (r *Relay) open(ctx context.Context) error {
	u, err := url.Parse(r.cfg.WSURL)
	if err != nil {
		return err
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		if u.Scheme == "wss" {
			port = "443"
		} else {
			port = "80"
		}
	}
	addr := net.JoinHostPort(host, port)

	conn, err := r.dial(ctx, "tcp", addr)
	if err != nil {
		return err
	}

	// Bound the TLS handshake + WS upgrade with an internal deadline. The driving
	// Send path passes context.Background() (no deadline), so without this a server
	// that completes the TCP dial but stalls mid-handshake would hang the WG send
	// goroutine forever, and DialErr would never learn of it (it stays nil until open
	// returns). Cleared once the upgrade completes. The deadline lives on the raw conn
	// and continues to apply through the tls.Client wrapper below.
	hsDeadline := time.Now().Add(15 * time.Second)
	if dl, ok := ctx.Deadline(); ok && dl.Before(hsDeadline) {
		hsDeadline = dl
	}
	_ = conn.SetDeadline(hsDeadline)

	if u.Scheme == "wss" || r.cfg.TLSConfig != nil {
		tlsCfg := r.cfg.TLSConfig
		if tlsCfg == nil {
			tlsCfg = &tls.Config{}
		}
		if tlsCfg.ServerName == "" {
			tlsCfg = tlsCfg.Clone()
			tlsCfg.ServerName = host
		}
		tconn := tls.Client(conn, tlsCfg)
		if err := tconn.HandshakeContext(ctx); err != nil {
			conn.Close()
			return err
		}
		conn = tconn
	}

	proto, err := BuildTunnelRequest(r.cfg.ForwardHost, r.cfg.ForwardPort, 30*time.Second)
	if err != nil {
		conn.Close()
		return err
	}

	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		conn.Close()
		return err
	}
	wsKey := base64.StdEncoding.EncodeToString(keyBytes)

	req := "GET " + u.RequestURI() + " HTTP/1.1\r\n" +
		"Host: " + addr + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + wsKey + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Protocol: " + proto + "\r\n" +
		"\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return err
	}

	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return err
	}
	if !strings.Contains(statusLine, " 101 ") {
		conn.Close()
		return fmt.Errorf("wstunnel: upgrade failed: %s", strings.TrimSpace(statusLine))
	}
	for { // drain remaining response headers up to the blank line
		line, err := br.ReadString('\n')
		if err != nil {
			conn.Close()
			return err
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}

	_ = conn.SetDeadline(time.Time{}) // clear the handshake deadline

	r.stateMu.Lock()
	if r.closed {
		// Close() ran while this dial was in flight. It saw a nil conn and could not
		// close it, so publishing now would leak a live connection (and start a
		// readLoop the caller believes is gone). Abort instead.
		r.stateMu.Unlock()
		conn.Close()
		return fmt.Errorf("wstunnel: closed during dial")
	}
	r.conn = conn
	r.br = br
	r.readStarted = true
	r.stateMu.Unlock()
	return nil
}

// readLoop supervises the carrier for the life of the relay: it pumps frames from the
// current connection and, when that connection drops, transparently re-dials and resumes
// (like the SSH transport's reconnect loop) instead of tearing the tunnel down. WG
// tolerates the gap and re-handshakes over the fresh carrier via its persistent
// keepalive. It exits, closing inbox, only when the relay is Closed.
func (r *Relay) readLoop() {
	defer close(r.inbox)
	for {
		r.stateMu.Lock()
		br := r.br
		closed := r.closed
		r.stateMu.Unlock()
		if closed {
			return
		}
		if br == nil {
			if !r.reconnect() {
				return // Closed before the carrier could be re-established.
			}
			continue
		}

		r.pump(br)

		// pump returned: the carrier errored or the peer sent a close frame. Drop this
		// connection; the top of the loop re-dials unless we've been Closed.
		r.stateMu.Lock()
		if r.conn != nil {
			_ = r.conn.Close()
		}
		r.conn = nil
		r.br = nil
		r.stateMu.Unlock()
	}
}

// pump reads and dispatches frames from one carrier until it errors or a close frame
// arrives, then returns so the supervisor can decide whether to reconnect.
func (r *Relay) pump(br *bufio.Reader) {
	var buf []byte
	tmp := make([]byte, 65536)
	for {
		for {
			op, payload, consumed, ok, err := decodeFrame(buf)
			if err != nil {
				return // malformed framing: the stream is desynced, drop the carrier
			}
			if !ok {
				break
			}
			buf = buf[consumed:]
			switch op {
			case opBinary, opText, opContinuation:
				if len(payload) > 0 {
					select {
					case r.inbox <- payload:
					default: // drop if the consumer is slow
					}
				}
			case opPing:
				_ = r.writeFrame(opPong, payload)
			case opClose:
				return
			}
		}
		n, err := br.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return
		}
	}
}

// reconnect re-dials the carrier with exponential backoff, publishing the fresh conn via
// open(). Returns false if the relay is Closed before a connection is re-established.
// This runs only after the first dial already succeeded, so it never masks an initial
// "server unreachable" failure (that surfaces through DialErr/WaitReady).
func (r *Relay) reconnect() bool {
	backoff := 100 * time.Millisecond
	for {
		r.stateMu.Lock()
		closed := r.closed
		r.stateMu.Unlock()
		if closed {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		err := r.open(ctx) // sets r.conn/r.br on success, or aborts if Closed mid-dial
		cancel()
		if err == nil {
			return true
		}
		select {
		case <-r.done:
			return false
		case <-time.After(backoff):
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func (r *Relay) writeFrame(op byte, payload []byte) error {
	r.stateMu.Lock()
	c := r.conn
	r.stateMu.Unlock()
	if c == nil {
		return fmt.Errorf("wstunnel: not connected")
	}
	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	_, err := c.Write(encodeFrame(op, payload))
	return err
}

// Send lazily opens the WebSocket on the first call, then writes the datagram as one
// unmasked binary frame.
func (r *Relay) Send(ctx context.Context, datagram []byte) error {
	if err := r.ensure(ctx); err != nil {
		return err
	}
	return r.writeFrame(opBinary, datagram)
}

// Recv delivers inbound datagrams. The channel is closed when the relay shuts down.
func (r *Relay) Recv() <-chan []byte { return r.inbox }

func (r *Relay) Close() error {
	r.stateMu.Lock()
	if r.closed {
		r.stateMu.Unlock()
		return nil
	}
	r.closed = true
	c := r.conn
	started := r.readStarted
	r.stateMu.Unlock()

	close(r.done) // wake any reconnect backoff so the supervisor exits promptly

	if !started {
		// No supervisor ever started (the first dial never succeeded, or Send was never
		// called), so nothing else will close inbox. Close it here so consumers ranging
		// over Recv() (e.g. the WGWS forwarder) unblock instead of leaking. A started
		// readLoop always closes inbox itself on exit, so this can't double-close.
		close(r.inbox)
	}
	if c != nil {
		return c.Close() // unblocks pump; readLoop then sees closed and closes inbox
	}
	return nil
}
