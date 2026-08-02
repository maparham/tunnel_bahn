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

	stateMu sync.Mutex
	conn    net.Conn
	br      *bufio.Reader
	closed  bool
}

func NewRelay(cfg Config, dial DialFunc) *Relay {
	return &Relay{cfg: cfg, dial: dial, inbox: make(chan []byte, 256)}
}

func (r *Relay) ensure(ctx context.Context) error {
	r.once.Do(func() {
		r.err = r.open(ctx)
		if r.err == nil {
			go r.readLoop()
		}
	})
	return r.err
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

	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
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
	r.conn = conn
	r.br = br
	r.stateMu.Unlock()
	return nil
}

func (r *Relay) readLoop() {
	defer close(r.inbox)
	var buf []byte
	tmp := make([]byte, 65536)
	for {
		for {
			op, payload, consumed, ok := decodeFrame(buf)
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
		n, err := r.br.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			return
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
	r.stateMu.Unlock()
	if c != nil {
		return c.Close() // unblocks readLoop, which closes inbox
	}
	return nil
}
