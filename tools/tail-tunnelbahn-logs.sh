#!/bin/sh
# Stream TunnelBahn unified logs. Use /usr/bin/log (zsh may shadow `log`).
# Run while exercising the app: connect VPN, use Chrome/Firefox, disconnect.
#
# Quick triage (one line per connect / extension start):
#   ... | grep -E 'APPSPLIT_CONNECT_SUMMARY|APPSPLIT_EXT_SUMMARY'
#
# Usage:
#   ./tools/tail-tunnelbahn-logs.sh
#   ./tools/tail-tunnelbahn-logs.sh show   # last 10 minutes, no stream

set -e
PRED='subsystem == "com.tunnelbahn.mac" OR subsystem == "com.tunnelbahn.mac.networkextension" OR subsystem == "com.tunnelbahn.mac.transparentproxy"'

if [ "${1:-}" = "show" ]; then
  exec /usr/bin/log show --last 10m --style compact --predicate "$PRED"
fi

exec /usr/bin/log stream --style compact --level debug --predicate "$PRED"
