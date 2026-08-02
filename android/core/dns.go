package core

import (
	"context"
	"encoding/binary"
	"io"
	"net/netip"

	"tunnelbahn/core/transport"
)

// ResolveOverTCP forwards a raw DNS query as DNS-over-TCP (RFC 7766: 2-byte
// big-endian length prefix) to resolver:53 through the transport, and returns the
// raw response payload with the length prefix stripped.
//
// Routing DNS through the tunnel over TCP defeats the Iranian gateway's UDP/53
// poisoning: the resolver is reached at the tunnel exit, not the local network.
func ResolveOverTCP(ctx context.Context, tr transport.Transport, resolver netip.AddrPort, query []byte) ([]byte, error) {
	conn, err := tr.DialTCP(ctx, resolver)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	msg := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(msg[:2], uint16(len(query)))
	copy(msg[2:], query)
	if _, err := conn.Write(msg); err != nil {
		return nil, err
	}

	var lenBuf [2]byte
	if _, err := io.ReadFull(conn, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(lenBuf[:])
	resp := make([]byte, n)
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}
