package core

import (
	"encoding/json"
	"fmt"
	"net/netip"
)

// sshParams / wgParams mirror the JSON the Kotlin layer emits from a Profile.
// Key material rides here because it cannot live in the Android Keystore directly.
type sshParams struct {
	Addr              string `json:"addr"`
	User              string `json:"user"`
	PrivateKeyPEM     string `json:"privateKeyPEM"`
	HostKeyAuthorized string `json:"hostKeyAuthorized"`
}

type wgParams struct {
	PrivateKey       string   `json:"privateKey"`
	PeerPublicKey    string   `json:"peerPublicKey"`
	PeerPresharedKey string   `json:"peerPresharedKey"`
	LocalAddrs       []string `json:"localAddrs"`
	DNS              []string `json:"dns"`
	MTU              int      `json:"mtu"`
	WSURL            string   `json:"wsURL"`
	ForwardHost      string   `json:"forwardHost"`
	ForwardPort      int      `json:"forwardPort"`
}

type rawConfig struct {
	Transport    string    `json:"transport"`
	Mode         string    `json:"mode"`
	IncludeCIDRs []string  `json:"includeCIDRs"`
	ExcludeCIDRs []string  `json:"excludeCIDRs"`
	Resolver     string    `json:"resolver"`
	SSH          sshParams `json:"ssh"`
	WG           wgParams  `json:"wg"`
}

// coreConfig is the parsed, validated form used by the Session.
type coreConfig struct {
	Transport    string
	Mode         Mode
	IncludeCIDRs []netip.Prefix
	ExcludeCIDRs []netip.Prefix
	Resolver     netip.AddrPort
	SSH          sshParams
	WG           wgParams
}

func parseConfig(s string) (*coreConfig, error) {
	var raw rawConfig
	if err := json.Unmarshal([]byte(s), &raw); err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}

	switch raw.Transport {
	case "ssh", "wgws":
	default:
		return nil, fmt.Errorf("config: unknown transport %q", raw.Transport)
	}

	var mode Mode
	switch raw.Mode {
	case "include", "":
		mode = ModeInclude
	case "exclude":
		mode = ModeExclude
	default:
		return nil, fmt.Errorf("config: unknown mode %q", raw.Mode)
	}

	inc, err := parsePrefixes(raw.IncludeCIDRs)
	if err != nil {
		return nil, fmt.Errorf("config: includeCIDRs: %w", err)
	}
	exc, err := parsePrefixes(raw.ExcludeCIDRs)
	if err != nil {
		return nil, fmt.Errorf("config: excludeCIDRs: %w", err)
	}

	var resolver netip.AddrPort
	if raw.Resolver != "" {
		resolver, err = netip.ParseAddrPort(raw.Resolver)
		if err != nil {
			return nil, fmt.Errorf("config: resolver: %w", err)
		}
	}

	return &coreConfig{
		Transport:    raw.Transport,
		Mode:         mode,
		IncludeCIDRs: inc,
		ExcludeCIDRs: exc,
		Resolver:     resolver,
		SSH:          raw.SSH,
		WG:           raw.WG,
	}, nil
}

func parsePrefixes(ss []string) ([]netip.Prefix, error) {
	out := make([]netip.Prefix, 0, len(ss))
	for _, s := range ss {
		p, err := netip.ParsePrefix(s)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// activeRuleSet returns the CIDR set that the Router should enforce for the active mode.
func (c *coreConfig) activeRuleSet() RuleSet {
	if c.Mode == ModeExclude {
		return RuleSet{CIDRs: c.ExcludeCIDRs}
	}
	return RuleSet{CIDRs: c.IncludeCIDRs}
}
