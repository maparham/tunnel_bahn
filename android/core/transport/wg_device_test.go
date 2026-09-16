package transport

import (
	"strings"
	"testing"
)

func TestUapiConfigUsesEndpointAndKeepalive(t *testing.T) {
	cfg := WGConfig{PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t), Keepalive: 15}
	s, err := uapiConfig(cfg, "3.139.146.5:51820")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"endpoint=3.139.146.5:51820\n",
		"persistent_keepalive_interval=15\n",
		"allowed_ip=0.0.0.0/0\n",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("uapi missing %q:\n%s", want, s)
		}
	}
}

func TestUapiConfigDefaultsKeepaliveTo25(t *testing.T) {
	cfg := WGConfig{PrivateKey: randKeyB64(t), PeerPublicKey: randKeyB64(t)}
	s, err := uapiConfig(cfg, "127.0.0.1:51820")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(s, "persistent_keepalive_interval=25\n") {
		t.Fatalf("want default keepalive 25:\n%s", s)
	}
}
