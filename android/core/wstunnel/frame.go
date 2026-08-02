package wstunnel

import "encoding/binary"

// WebSocket opcodes (RFC 6455 §5.2).
const (
	opContinuation byte = 0x0
	opText         byte = 0x1
	opBinary       byte = 0x2
	opClose        byte = 0x8
	opPing         byte = 0x9
	opPong         byte = 0xA
)

// encodeFrame builds a single WebSocket frame with FIN=1 and the mask bit CLEARED.
//
// This is deliberate and load-bearing: wstunnel runs with websocket_mask_frame=false
// and does NOT unmask client frames, so an RFC-compliant masked frame arrives scrambled
// and the WG handshake never completes (see Shared/WGTCPWrapperRelay.swift). We emit
// unmasked frames exactly as wstunnel's own client does.
func encodeFrame(opcode byte, payload []byte) []byte {
	out := make([]byte, 0, len(payload)+10)
	out = append(out, 0x80|(opcode&0x0f)) // FIN + opcode
	n := len(payload)
	switch {
	case n < 126:
		out = append(out, byte(n)) // mask bit = 0
	case n < 65536:
		out = append(out, 126, byte(n>>8), byte(n))
	default:
		out = append(out, 127)
		var b [8]byte
		binary.BigEndian.PutUint64(b[:], uint64(n))
		out = append(out, b[:]...)
	}
	out = append(out, payload...)
	return out
}

// decodeFrame decodes one frame from the front of buf. It returns the opcode, the
// payload, the number of bytes consumed, and ok=false if a full frame is not yet
// buffered. It unmasks if the peer ever sets the mask bit (the server won't, but the
// read path stays tolerant).
func decodeFrame(buf []byte) (opcode byte, payload []byte, consumed int, ok bool) {
	if len(buf) < 2 {
		return 0, nil, 0, false
	}
	opcode = buf[0] & 0x0f
	masked := buf[1]&0x80 != 0
	length := int(buf[1] & 0x7f)
	off := 2
	switch length {
	case 126:
		if len(buf) < off+2 {
			return 0, nil, 0, false
		}
		length = int(buf[off])<<8 | int(buf[off+1])
		off += 2
	case 127:
		if len(buf) < off+8 {
			return 0, nil, 0, false
		}
		length = 0
		for i := 0; i < 8; i++ {
			length = length<<8 | int(buf[off+i])
		}
		off += 8
	}
	var mask [4]byte
	if masked {
		if len(buf) < off+4 {
			return 0, nil, 0, false
		}
		copy(mask[:], buf[off:off+4])
		off += 4
	}
	if len(buf) < off+length {
		return 0, nil, 0, false
	}
	payload = make([]byte, length)
	copy(payload, buf[off:off+length])
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, payload, off + length, true
}
