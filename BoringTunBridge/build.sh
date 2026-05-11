#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Must match `MACOSX_DEPLOYMENT_TARGET` in Xcode / `project.yml` (e.g. 14.0), or the linker
# warns that object files in this archive were built for a newer macOS than the extension links.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "Building BoringTun Bridge for macOS (MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET})..."

# Build for both architectures
cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

# Create universal binary
mkdir -p ../Frameworks
lipo -create \
    target/aarch64-apple-darwin/release/libboringtun_bridge.a \
    target/x86_64-apple-darwin/release/libboringtun_bridge.a \
    -output ../Frameworks/libboringtun_bridge.a

echo "✅ Universal library created at: ../Frameworks/libboringtun_bridge.a"
echo "Add this to your Xcode project's Link Binary With Libraries build phase"
