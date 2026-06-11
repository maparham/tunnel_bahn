#!/usr/bin/env bash
# Verify a TunnelBahn .app is signed for direct (non–App Store) distribution.
set -euo pipefail

APP="${1:-/Applications/TunnelBahn.app}"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found: $APP" >&2
  exit 1
fi

echo "=== TunnelBahn build verification ==="
echo "Path: $APP"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "Version: $version ($build)"
echo ""

fail=0

sig="$(codesign -dvv "$APP" 2>&1 || true)"
authority="$(printf '%s\n' "$sig" | awk -F= '/^Authority=/{print $2; exit}')"
flags="$(printf '%s\n' "$sig" | awk -F'flags=' '/^CodeDirectory/{print $2; exit}' | awk '{print $1}')"
echo "Main app authority: $authority"
echo "Main app flags:     $flags"
echo ""

if [[ "$authority" == *"Developer ID Application"* ]]; then
  echo "✓ Signed with Developer ID Application"
else
  echo "✗ WRONG CERTIFICATE — expected Developer ID Application"
  echo "  Got: $authority"
  echo "  Apple Distribution / Apple Development cannot launch from /Applications."
  fail=1
fi

if [[ "$flags" == *"runtime"* ]]; then
  echo "✓ Hardened Runtime enabled"
else
  echo "⚠ Hardened Runtime not enabled (flags=$flags)"
fi

echo ""
echo "=== System Extensions ==="
for ext in "$APP"/Contents/Library/SystemExtensions/*.systemextension; do
  [[ -d "$ext" ]] || continue
  name="$(basename "$ext")"
  ext_sig="$(codesign -dvv "$ext" 2>&1 || true)"
  ext_auth="$(printf '%s\n' "$ext_sig" | awk -F= '/^Authority=/{print $2; exit}')"
  if [[ "$ext_auth" == *"Developer ID Application"* ]]; then
    echo "✓ $name"
  else
    echo "✗ $name — $ext_auth"
    fail=1
  fi
  if [[ -f "$ext/Contents/embedded.provisionprofile" ]]; then
    profile_name="$(security cms -D -i "$ext/Contents/embedded.provisionprofile" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || echo unknown)"
    if [[ "$profile_name" == *"Store"* ]]; then
      echo "  ✗ App Store provisioning profile embedded: $profile_name"
      fail=1
    fi
  fi
done

echo ""
echo "=== codesign --verify ==="
if codesign --verify --deep --strict --verbose=2 "$APP" 2>&1; then
  echo "✓ Signature structurally valid"
else
  echo "✗ Signature invalid"
  fail=1
fi

echo ""
echo "=== Gatekeeper ==="
if spctl_out="$(spctl -a -vv "$APP" 2>&1)"; then
  echo "✓ Gatekeeper accepted"
  echo "$spctl_out"
elif [[ "$spctl_out" == *"Unnotarized Developer ID"* ]]; then
  echo "⚠ Developer ID OK but NOT NOTARIZED — macOS may refuse to launch"
  echo "$spctl_out"
  fail=1
elif [[ "$spctl_out" == *"Apple Distribution"* ]]; then
  echo "✗ Gatekeeper rejected (App Store certificate on direct install)"
  echo "$spctl_out"
  fail=1
else
  echo "✗ Gatekeeper rejected"
  echo "$spctl_out"
  fail=1
fi

echo ""
if stapler validate "$APP" 2>&1 | grep -q "stapled"; then
  echo "✓ Notarization ticket stapled"
else
  echo "⚠ No stapled notarization ticket"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  echo "RESULT: OK — ready for direct distribution"
else
  echo "RESULT: FAILED — re-export via Xcode: Archive → Distribute App → Developer ID → enable Notarization"
  echo "       Do NOT choose App Store Connect."
fi

exit "$fail"
