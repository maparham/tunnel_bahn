#!/bin/bash
# Forces every NON-ARCHIVE build to stamp the system extension with a strictly-increasing
# CFBundleVersion, so macOS always treats the rebuilt extension as NEWER and replaces the running
# one. Without this, a rebuild that keeps the same version is (per macOS rules) frequently ignored:
# the previously-activated extension keeps serving OLD code and you unknowingly test a stale binary.
# `systemextensionsctl developer on` would also solve this, but it requires SIP disabled.
#
# Wired as a POST-build "Run Script" phase — it runs after the Info.plist is already copied into the
# built bundle but before code signing, so it edits the BUILT PRODUCT only. The source Info.plist
# (and git) stay clean; signing then seals the bumped value.
#
# Skipped during `archive` (ACTION=install) so App Store / distribution builds keep the committed
# CFBundleVersion and you stay in control of release version numbers.
set -euo pipefail

# Xcode build phases inherit a stripped PATH.
export PATH="/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

if [ "${ACTION:-build}" = "install" ]; then
    echo "autobump: archive/install action — keeping committed CFBundleVersion"
    exit 0
fi

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST" ]; then
    echo "autobump: built Info.plist not found at $PLIST — skipping" >&2
    exit 0
fi

# Local-timezone date-time stamp (YYYYMMDDHHMMSS) — human-readable (you can see exactly when the
# build was made) AND strictly monotonic across rebuilds, the property SIP-blocked developer mode
# can't give us. 14 digits is well within CFBundleVersion's real limit (18 characters, per Apple —
# NOT the signed-32-bit ceiling previously assumed here), and it is numerically larger than the prior
# `date +%s` epoch values, so it supersedes already-installed builds with no reset. Second granularity
# makes a same-second collision between two rebuilds effectively impossible.
BUMP="$(date +%Y%m%d%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUMP}" "$PLIST"
echo "autobump: CFBundleVersion -> ${BUMP} in ${INFOPLIST_PATH}"
