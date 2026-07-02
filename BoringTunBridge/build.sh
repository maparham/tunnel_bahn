#!/bin/bash
set -e

# Xcode build phases inherit a stripped PATH; ensure cargo is findable.
export PATH="$HOME/.cargo/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY_DIR="$(cd "$SCRIPT_DIR/../BoringTunRelay" && pwd)"
cd "$SCRIPT_DIR"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

echo "Building BoringTun Bridge for macOS (MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET})..."

cargo build --release --target aarch64-apple-darwin
cargo build --release --target x86_64-apple-darwin

cargo build --release --target aarch64-apple-darwin --manifest-path "$RELAY_DIR/Cargo.toml"
cargo build --release --target x86_64-apple-darwin --manifest-path "$RELAY_DIR/Cargo.toml"

mkdir -p ../Frameworks
mkdir -p out

lipo -create \
    target/aarch64-apple-darwin/release/libboringtun_bridge.a \
    target/x86_64-apple-darwin/release/libboringtun_bridge.a \
    -output out/libboringtun_wg.a

lipo -create \
    "$RELAY_DIR/target/aarch64-apple-darwin/release/libtunnelbahn_relay.a" \
    "$RELAY_DIR/target/x86_64-apple-darwin/release/libtunnelbahn_relay.a" \
    -output out/libtunnelbahn_relay.a

# -no_warning_for_no_symbols silences libtool warnings on the empty
# codegen-unit object files (.rcgu.o) that Rust emits inside its static
# archives — those have no public symbols by design and are harmless.
libtool -static -no_warning_for_no_symbols \
    -o ../Frameworks/libboringtun_bridge.a \
    out/libboringtun_wg.a out/libtunnelbahn_relay.a

echo "✅ Universal library created at: ../Frameworks/libboringtun_bridge.a (WireGuard + smoltcp relay)"
