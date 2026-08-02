package wstunnel

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestBuildTunnelRequestShape(t *testing.T) {
	hdr, err := BuildTunnelRequest("127.0.0.1", 51840, 30*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(hdr, "v1, authorization.bearer.") {
		t.Fatalf("bad prefix: %q", hdr)
	}
	tokenStr := strings.TrimPrefix(hdr, "v1, authorization.bearer.")

	// Server decodes without verifying the signature; mirror that here.
	parser := jwt.NewParser()
	claims := jwt.MapClaims{}
	_, _, err = parser.ParseUnverified(tokenStr, claims)
	if err != nil {
		t.Fatal(err)
	}
	if claims["r"] != "127.0.0.1" {
		t.Fatalf("r claim: want 127.0.0.1, got %v", claims["r"])
	}
	if claims["rp"].(float64) != 51840 {
		t.Fatalf("rp claim: want 51840, got %v", claims["rp"])
	}
	p, _ := json.Marshal(claims["p"])
	if !strings.Contains(string(p), `"Udp"`) {
		t.Fatalf("p claim missing Udp: %s", p)
	}
}
