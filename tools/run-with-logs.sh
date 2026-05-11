#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/.build/DerivedData"
APP="$DD/Build/Products/Debug/TunnelBahn.app/Contents/MacOS/TunnelBahn"

echo "[run-with-logs] cleaning build outputs under repo…"
rm -rf "$DD" "$ROOT/build" "$ROOT/.derived"

echo "[run-with-logs] building (Debug) → $DD …"
(
  cd "$ROOT"
  xcodebuild \
    -project TunnelBahn.xcodeproj \
    -scheme TunnelBahn \
    -configuration Debug \
    -derivedDataPath "$DD" \
    -allowProvisioningUpdates \
    build
)

echo "[run-with-logs] refreshing sudo credentials (needed for wg/route/pf fallback)…"
sudo -v

echo "[run-with-logs] launching app (stdout/stderr → this terminal)…"
exec "$APP"
