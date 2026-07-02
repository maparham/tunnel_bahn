#!/usr/bin/env bash
# Sign a TunnelBahn .app from an Xcode archive for Developer ID direct distribution.
#
# Xcode's Direct Distribution export is unreliable for Network Extension system
# extensions (see Apple Developer Forums thread 737894). This script re-signs
# embedded .systemextension bundles with Developer ID and the *-systemextension
# network entitlement variants required outside the Mac App Store.
#
# Usage:
#   tools/sign-for-direct-distribution.sh [path/to/TunnelBahn.app-or.xcarchive]
#
# After signing, notarize and staple before distributing:
#   ditto -c -k --keepParent /path/TunnelBahn.app TunnelBahn.zip
#   xcrun notarytool submit TunnelBahn.zip --apple-id ... --team-id 92G3VZAPVG --password ... --wait
#   xcrun stapler staple /path/TunnelBahn.app
#
# Verify:
#   tools/verify-build.sh /path/TunnelBahn.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Mahan Parham (92G3VZAPVG)}"
TMP_ENT="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_ENT"
}
trap cleanup EXIT

input="${1:-}"
if [[ -z "$input" ]]; then
  echo "usage: $0 <TunnelBahn.app | Something.xcarchive>" >&2
  exit 1
fi

resolve_app() {
  local path="$1"
  if [[ -d "$path/Contents/MacOS" ]]; then
    printf '%s' "$path"
    return
  fi
  if [[ -d "$path/Products/Applications/TunnelBahn.app" ]]; then
    printf '%s' "$path/Products/Applications/TunnelBahn.app"
    return
  fi
  echo "error: could not find TunnelBahn.app in $path" >&2
  exit 1
}

distribution_entitlements() {
  local src="$1"
  local dst="$2"
  sed \
    -e 's/<string>packet-tunnel-provider<\/string>/<string>packet-tunnel-provider-systemextension<\/string>/g' \
    -e 's/<string>app-proxy-provider<\/string>/<string>app-proxy-provider-systemextension<\/string>/g' \
    "$src" > "$dst"
}

src_app="$(resolve_app "$input")"
out="${2:-/tmp/TunnelBahn-DeveloperID.app}"

echo "Source: $src_app"
echo "Output: $out"
echo "Identity: $IDENTITY"

rm -rf "$out"
ditto "$src_app" "$out"

# App Store / development profiles must not remain embedded.
find "$out" -name 'embedded.provisionprofile' -delete

sign_target() {
  local target="$1"
  local entitlements="$2"
  echo "Signing $(basename "$target")..."
  codesign --force --timestamp --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$entitlements" \
    "$target"
}

sysex_dir="$out/Contents/Library/SystemExtensions"
app_ent="$TMP_ENT/TunnelBahn.entitlements"
tunnel_ent="$TMP_ENT/networkextension.entitlements"
proxy_ent="$TMP_ENT/transparentproxy.entitlements"

distribution_entitlements "$ROOT/TunnelBahn/TunnelBahn.entitlements" "$app_ent"
distribution_entitlements "$ROOT/NetworkExtension/NetworkExtension.entitlements" "$tunnel_ent"
distribution_entitlements "$ROOT/TransparentProxyExtension/TransparentProxyExtension.entitlements" "$proxy_ent"

sign_target "$sysex_dir/com.tunnelbahn.mac.networkextension.systemextension" "$tunnel_ent"
sign_target "$sysex_dir/com.tunnelbahn.mac.transparentproxy.systemextension" "$proxy_ent"
sign_target "$out" "$app_ent"

echo ""
echo "=== Verification ==="
codesign --verify --deep --strict --verbose=2 "$out"
"$ROOT/tools/verify-build.sh" "$out"

echo ""
echo "Signed app: $out"
echo "Next: notarize, staple, then pkg or copy to /Applications."
