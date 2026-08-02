package core

import (
	"net"
	"sync/atomic"
)

// counters accumulates tunneled inner-payload bytes for the status notification.
// Rx is server->app (download); Tx is app->server (upload). One instance per session.
type counters struct {
	rx atomic.Uint64
	tx atomic.Uint64
}

func (c *counters) Rx() int64 { return int64(c.rx.Load()) }
func (c *counters) Tx() int64 { return int64(c.tx.Load()) }

// wrapConn counts a coreProxy tunnel-branch TCP conn. On the proxy conn,
// Write is app->server (TX) and Read is server->app (RX).
func (c *counters) wrapConn(inner net.Conn) net.Conn {
	return &countingConn{Conn: inner, c: c}
}

type countingConn struct {
	net.Conn
	c *counters
}

func (cc *countingConn) Read(p []byte) (int, error) {
	n, err := cc.Conn.Read(p)
	if n > 0 {
		cc.c.rx.Add(uint64(n))
	}
	return n, err
}

func (cc *countingConn) Write(p []byte) (int, error) {
	n, err := cc.Conn.Write(p)
	if n > 0 {
		cc.c.tx.Add(uint64(n))
	}
	return n, err
}

// wrapPacketConn counts a coreProxy tunnel-branch UDP conn. WriteTo is TX, ReadFrom is RX.
func (c *counters) wrapPacketConn(inner net.PacketConn) net.PacketConn {
	return &countingPacketConn{PacketConn: inner, c: c}
}

type countingPacketConn struct {
	net.PacketConn
	c *counters
}

func (cp *countingPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, addr, err := cp.PacketConn.ReadFrom(p)
	if n > 0 {
		cp.c.rx.Add(uint64(n))
	}
	return n, addr, err
}

func (cp *countingPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	n, err := cp.PacketConn.WriteTo(p, addr)
	if n > 0 {
		cp.c.tx.Add(uint64(n))
	}
	return n, err
}
