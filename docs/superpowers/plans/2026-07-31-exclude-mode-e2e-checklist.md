# Exclude-Mode Routing — Manual E2E Checklist

Profile: app-tunnel, WireGuard transport, one routed test app (e.g. a browser).
Setup: import a small bulk CIDR group containing a known-direct test range
(e.g. 5.22.0.0/16 or any reachable host you control), select
"Tunnel all except selected".

1. Connect. Log check (Console.app, subsystem com.tunnelbahn.mac.transparentproxy):
   `buildIncludedNetworkRules: exclude mode — catch-all TCP+UDP` and
   `[FIRSTRUN-DIAG] ... mode=exclude`.
2. From the routed app, hit a NON-listed site (e.g. https://ifconfig.me):
   shown IP must be the WG server's (tunneled).
3. Hit an IP inside the excluded range: log shows
   `decision=exclude-direct remote=<ip>`, and traffic egresses en0 (direct).
4. Add a domain rule (e.g. digikala.com), reconnect, visit it from the routed app:
   `[APPSPLIT_SNI] decision=direct reason=sni`.
5. DNS with "Resolve DNS locally" OFF: `nslookup example.com` from the routed app —
   no leak to the local resolver (query rides the tunnel; check WG server or
   tcpdump port 53 on en0 shows nothing from the app). Scope note: the redirect
   applies to queries aimed at LOCAL/private resolvers (the system default). An app
   hardcoding a public non-excluded resolver (e.g. 8.8.8.8) tunnels to it; one
   hardcoding an EXCLUDED resolver goes direct BY DESIGN (the user listed it) —
   that is correct behavior, not a leak.
6. Toggle "Resolve DNS locally" ON, reconnect: the same lookup now reaches the
   local resolver directly.
7. Regression (include mode): switch the profile back to "Tunnel selected
   destinations", reconnect, verify listed-IP-tunnels / unlisted-IP-direct
   still behaves as before.
8. Non-routed apps: verify an app outside the profile is entirely unaffected
   in both modes.
