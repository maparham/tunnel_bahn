#!/bin/bash
# verify-udp-egress.sh — settle open finding #1: does a routed app's UDP actually
# go through the WireGuard tunnel, or does it leak out the physical interface?
#
# WHY THIS TEST IS VALID
#   A correctly-tunneled UDP flow is encapsulated by WireGuard: the PHYSICAL
#   interface (en0/Wi-Fi/Ethernet) only ever sees ENCRYPTED packets addressed to
#   the WG *server endpoint*; the plaintext to the public destination rides inside
#   the utun device. A LEAK has the opposite fingerprint — plaintext UDP to the
#   public destination appears DIRECTLY on the physical interface, bypassing WG.
#   So: plaintext UDP to $DEST seen on the physical iface  ==>  LEAK.
#
# HOW TO RUN  (needs sudo for packet capture)
#   1. Connect the tunnel with a FULL-tunnel profile (AllowedIPs 0.0.0.0/0),
#      Settings -> Unmatched apps = Bypass VPN.
#   2. Mark exactly ONE app "Route via VPN" (e.g. a browser or a CLI you control).
#   3. Run:   sudo tools/verify-udp-egress.sh 1.1.1.1
#   4. When it says "GENERATE TRAFFIC NOW", from the ROUTED app send UDP to $DEST
#      (e.g. load an HTTP/3 site, or `dig @1.1.1.1 example.com` if the routed app
#      is your shell). Then, as the OUT-OF-LIST control, do the same from a
#      NON-routed app — it SHOULD appear on the physical interface (proves the
#      capture works and that routing actually narrows).
#
# INTERPRETING THE VERDICT
#   routed-app UDP on physical iface  = 0  AND  seen on utun  = LEAK-FREE (pass)
#   routed-app UDP on physical iface  > 0                     = LEAK (fail, hold release)
#   control (non-routed) UDP on physical iface > 0           = sanity OK
set -uo pipefail

DEST="${1:-1.1.1.1}"
DURATION="${2:-25}"

if [ "$(id -u)" != "0" ]; then
  echo "error: packet capture needs root — re-run with sudo" >&2
  exit 1
fi

# Physical interface = the one carrying the default route.
PHYS="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
PHYS="${PHYS:-en0}"
UTUNS="$(ifconfig -l | tr ' ' '\n' | grep '^utun')"

echo "=== UDP egress probe ==="
echo "destination : $DEST"
echo "physical    : $PHYS"
echo "utun ifaces : ${UTUNS:-<none — is the tunnel up?>}"
echo "capture     : ${DURATION}s"
echo

CAPDIR="$(mktemp -d)"
FILTER="udp and host $DEST"

# Start capture on the physical interface (the leak detector).
tcpdump -n -i "$PHYS" -w "$CAPDIR/phys.pcap" "$FILTER" >/dev/null 2>&1 &
PHYS_PID=$!

# Start capture on every utun (positive confirmation of tunneling).
UTUN_PIDS=()
for u in $UTUNS; do
  tcpdump -n -i "$u" -w "$CAPDIR/$u.pcap" "$FILTER" >/dev/null 2>&1 &
  UTUN_PIDS+=($!)
done

sleep 1
echo ">>> GENERATE TRAFFIC NOW: send UDP to $DEST from the ROUTED app, then from a non-routed control app."
echo "    (capturing for ${DURATION}s...)"
sleep "$DURATION"

kill "$PHYS_PID" "${UTUN_PIDS[@]}" 2>/dev/null
wait 2>/dev/null

phys_count=$(tcpdump -n -r "$CAPDIR/phys.pcap" 2>/dev/null | wc -l | tr -d ' ')
utun_total=0
for u in $UTUNS; do
  c=$(tcpdump -n -r "$CAPDIR/$u.pcap" 2>/dev/null | wc -l | tr -d ' ')
  utun_total=$((utun_total + c))
done

echo
echo "=== RESULT ==="
echo "plaintext UDP to $DEST on $PHYS (physical) : $phys_count packet(s)"
echo "plaintext UDP to $DEST on utun (tunnel)    : $utun_total packet(s)"
echo
if [ "$phys_count" -gt 0 ]; then
  echo "VERDICT: LEAK — routed-app UDP is (or a non-routed control is) reaching $DEST"
  echo "         directly on the physical interface. If this traffic came from the"
  echo "         ROUTED app, finding #1 is CONFIRMED — DO NOT publish the release."
  echo "         Re-run and generate traffic ONLY from the routed app to disambiguate"
  echo "         from the control."
else
  echo "VERDICT: no plaintext UDP to $DEST on the physical interface."
  if [ "$utun_total" -gt 0 ]; then
    echo "         Seen on utun instead => routed-app UDP is TUNNELED. Finding #1 looks clear."
  else
    echo "         Nothing seen anywhere — traffic may not have been generated, or the"
    echo "         routed app didn't actually send to $DEST. Re-run and confirm the app hit $DEST."
  fi
fi
echo
echo "pcaps kept at: $CAPDIR"
