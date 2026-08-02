package wstunnel

import (
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

type udpTimeout struct {
	Secs  int `json:"secs"`
	Nanos int `json:"nanos"`
}

// BuildTunnelRequest returns the full sec-websocket-protocol header value
// ("v1, authorization.bearer.<JWT>") for a wstunnel v10 UDP tunnel request.
// The server does not verify the JWT signature, so a random per-run secret is fine.
func BuildTunnelRequest(forwardHost string, forwardPort int, timeout time.Duration) (string, error) {
	claims := jwt.MapClaims{
		"id": uuid.NewString(),
		"p":  map[string]any{"Udp": map[string]any{"timeout": udpTimeout{Secs: int(timeout.Seconds()), Nanos: 0}}},
		"r":  forwardHost,
		"rp": forwardPort,
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString([]byte(uuid.NewString()))
	if err != nil {
		return "", err
	}
	return "v1, authorization.bearer." + signed, nil
}
