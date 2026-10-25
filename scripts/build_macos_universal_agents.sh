#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEPLOYMENT_TARGET="14.4"
readonly ARM_TARGET="aarch64-apple-darwin"
readonly INTEL_TARGET="x86_64-apple-darwin"
readonly OUTPUT_DIR="$ROOT_DIR/target/macos-universal/release"

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Universal macOS Agent builds require macOS\n' >&2
  exit 2
fi

installed_targets="$(rustup target list --installed)"
for target in "$ARM_TARGET" "$INTEL_TARGET"; do
  if ! printf '%s\n' "$installed_targets" | awk -v expected="$target" \
    '$0 == expected { found=1 } END { exit !found }'; then
    printf 'missing Rust target: %s; install it with rustup target add %s\n' \
      "$target" "$target" >&2
    exit 1
  fi
done

build_target() {
  local target="$1"
  local asset="$2"
  local webrtc_root

  webrtc_root="$("$ROOT_DIR/scripts/fetch_libwebrtc.sh" "$asset")"
  LK_CUSTOM_WEBRTC="$webrtc_root" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    cargo build --locked --release --target "$target" \
      -p roammand-host-agent --features native-webrtc
  LK_CUSTOM_WEBRTC="$webrtc_root" \
    MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    cargo build --locked --release --target "$target" \
      -p roammand-privileged-bridge --features native-webrtc
}

cd "$ROOT_DIR"
build_target "$ARM_TARGET" webrtc-mac-arm64-release.zip
build_target "$INTEL_TARGET" webrtc-mac-x64-release.zip

install -d -m 0755 "$OUTPUT_DIR"
lipo -create \
  "$ROOT_DIR/target/$ARM_TARGET/release/roammand-host-agent" \
  "$ROOT_DIR/target/$INTEL_TARGET/release/roammand-host-agent" \
  -output "$OUTPUT_DIR/roammand-host-agent"
lipo -create \
  "$ROOT_DIR/target/$ARM_TARGET/release/roammand-privileged-bridge" \
  "$ROOT_DIR/target/$INTEL_TARGET/release/roammand-privileged-bridge" \
  -output "$OUTPUT_DIR/roammand-privileged-bridge"
install -m 0755 "$OUTPUT_DIR/roammand-privileged-bridge" \
  "$OUTPUT_DIR/roammand-session-agent"

for binary in \
  "$OUTPUT_DIR/roammand-host-agent" \
  "$OUTPUT_DIR/roammand-privileged-bridge" \
  "$OUTPUT_DIR/roammand-session-agent"; do
  lipo "$binary" -verify_arch arm64
  lipo "$binary" -verify_arch x86_64
done

printf 'Universal macOS Agents built\n'
