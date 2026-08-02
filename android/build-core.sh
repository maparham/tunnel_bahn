#!/usr/bin/env bash
# Builds the gomobile AAR from the Go core.
# Requires: Go, an Android SDK with an NDK, and ANDROID_NDK_HOME (or ANDROID_HOME
# with an ndk/ subdir) pointing at it.
set -euo pipefail

cd "$(dirname "$0")/core"

# Java is needed for gomobile's javac step. Prefer an explicit JAVA_HOME, else fall
# back to the JDK bundled with Android Studio.
if [[ -z "${JAVA_HOME:-}" ]]; then
  jbr="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [[ -x "$jbr/bin/javac" ]]; then
    JAVA_HOME="$jbr"
  fi
fi
export JAVA_HOME
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"
echo "Using JAVA_HOME: ${JAVA_HOME:-<none>}"

# Resolve an NDK if the caller did not set ANDROID_NDK_HOME.
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  if [[ -d "$sdk/ndk" ]]; then
    ANDROID_NDK_HOME="$sdk/ndk/$(ls "$sdk/ndk" | sort -V | tail -1)"
  fi
fi
export ANDROID_NDK_HOME
echo "Using NDK: ${ANDROID_NDK_HOME:-<none>}"

go install golang.org/x/mobile/cmd/gomobile@latest
go install golang.org/x/mobile/cmd/gobind@latest
export PATH="$(go env GOPATH)/bin:$PATH"

gomobile init

mkdir -p ../app/libs
gomobile bind -target=android -androidapi 24 -javapkg tunnelbahn -o ../app/libs/libtunnelbahn.aar ./mobile

echo "built android/app/libs/libtunnelbahn.aar"
unzip -l ../app/libs/libtunnelbahn.aar | grep -E 'classes.jar|arm64-v8a' || true
