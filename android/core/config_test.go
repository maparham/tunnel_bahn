package core

import "testing"

const sampleSSHConfig = `{
  "transport": "ssh",
  "mode": "exclude",
  "includeCIDRs": [],
  "excludeCIDRs": ["10.0.0.0/8"],
  "resolver": "1.1.1.1:53",
  "ssh": {"addr":"1.2.3.4:443","user":"tb","privateKeyPEM":"-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----\n","hostKeyAuthorized":"ssh-ed25519 AAAA..."}
}`

func TestParseConfigSSH(t *testing.T) {
	c, err := parseConfig(sampleSSHConfig)
	if err != nil {
		t.Fatal(err)
	}
	if c.Transport != "ssh" {
		t.Fatalf("transport: %q", c.Transport)
	}
	if c.Mode != ModeExclude {
		t.Fatalf("mode: %v", c.Mode)
	}
	if len(c.ExcludeCIDRs) != 1 || c.ExcludeCIDRs[0].String() != "10.0.0.0/8" {
		t.Fatalf("excludeCIDRs: %v", c.ExcludeCIDRs)
	}
	if c.Resolver.String() != "1.1.1.1:53" {
		t.Fatalf("resolver: %v", c.Resolver)
	}
}

func TestParseConfigRejectsUnknownTransport(t *testing.T) {
	if _, err := parseConfig(`{"transport":"telepathy"}`); err == nil {
		t.Fatal("want error for unknown transport")
	}
}

func TestParseConfigRejectsBadCIDR(t *testing.T) {
	if _, err := parseConfig(`{"transport":"ssh","mode":"include","includeCIDRs":["999.1.1.1/8"]}`); err == nil {
		t.Fatal("want error for malformed CIDR")
	}
}
