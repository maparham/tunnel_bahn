#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building BoringTun Bridge for macOS..."

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
