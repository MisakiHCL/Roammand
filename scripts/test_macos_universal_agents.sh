#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
  printf 'Universal macOS Agent test failed: %s\n' "$1" >&2
  exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail 'real Mach-O architecture checks require macOS'
fi

readonly FIXTURE_DIR="$TEMP_DIR/fixture repo"
readonly BIN_DIR="$TEMP_DIR/bin"
readonly OUTPUT_DIR="$FIXTURE_DIR/target/macos-universal/release"
readonly BINARIES=(
  roammand-host-agent
  roammand-privileged-bridge
  roammand-session-agent
)

mkdir -p "$FIXTURE_DIR/scripts" "$BIN_DIR"
cp "$ROOT_DIR/scripts/build_macos_universal_agents.sh" "$FIXTURE_DIR/scripts/"
printf 'int roammand_universal_fixture(void) { return 0; }\n' >"$TEMP_DIR/fixture.c"
for arch in arm64 x86_64; do
  /usr/bin/clang -arch "$arch" -mmacosx-version-min=14.4 -c \
    "$TEMP_DIR/fixture.c" -o "$TEMP_DIR/$arch.o"
  chmod 0755 "$TEMP_DIR/$arch.o"
done
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  case "$target" in
    aarch64-apple-darwin) arch=arm64 ;;
    x86_64-apple-darwin) arch=x86_64 ;;
  esac
  mkdir -p "$FIXTURE_DIR/target/$target/release"
  for binary in roammand-host-agent roammand-privileged-bridge; do
    cp "$TEMP_DIR/$arch.o" "$FIXTURE_DIR/target/$target/release/$binary"
  done
done

# Stub dependency resolution and Rust compilation; architecture operations use
# the system lipo on real Mach-O objects throughout the complete build script.
cat >"$BIN_DIR/rustup" <<'SH'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
printf '%s\n' aarch64-apple-darwin x86_64-apple-darwin
SH
cat >"$BIN_DIR/cargo" <<'SH'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
exit 0
SH
cat >"$FIXTURE_DIR/scripts/fetch_libwebrtc.sh" <<'SH'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
printf '%s/webrtc\n' "$ROAMMAND_UNIVERSAL_FIXTURE_DIR"
SH
cat >"$BIN_DIR/install" <<'SH'
#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
/usr/bin/install "$@"
# Inject a single thin artifact after all three outputs have been assembled,
# before the build's final architecture checks. The real lipo remains unstubbed.
output_dir="$ROAMMAND_UNIVERSAL_FIXTURE_DIR/target/macos-universal/release"
if [[ -n "$ROAMMAND_UNIVERSAL_THIN_BINARY" &&
      -f "$output_dir/roammand-session-agent" ]]; then
  cp "$ROAMMAND_UNIVERSAL_INPUT_DIR/$ROAMMAND_UNIVERSAL_THIN_ARCH.o" \
    "$output_dir/$ROAMMAND_UNIVERSAL_THIN_BINARY"
fi
SH
chmod 0755 "$BIN_DIR"/* "$FIXTURE_DIR/scripts"/*

run_fixture() {
  PATH="$BIN_DIR:$PATH" \
    ROAMMAND_UNIVERSAL_FIXTURE_DIR="$FIXTURE_DIR" \
    ROAMMAND_UNIVERSAL_INPUT_DIR="$TEMP_DIR" \
    ROAMMAND_UNIVERSAL_THIN_BINARY="$1" \
    ROAMMAND_UNIVERSAL_THIN_ARCH="$2" \
    "$FIXTURE_DIR/scripts/build_macos_universal_agents.sh"
}

if ! run_fixture '' '' >"$TEMP_DIR/build.log" 2>&1; then
  cat "$TEMP_DIR/build.log" >&2
  fail 'the build rejected valid arm64 and x86_64 inputs'
fi
for binary in "${BINARIES[@]}"; do
  [[ -x "$OUTPUT_DIR/$binary" ]] || fail "missing executable: $binary"
  /usr/bin/lipo "$OUTPUT_DIR/$binary" -verify_arch arm64
  /usr/bin/lipo "$OUTPUT_DIR/$binary" -verify_arch x86_64
done
cmp "$OUTPUT_DIR/roammand-privileged-bridge" \
  "$OUTPUT_DIR/roammand-session-agent"

for binary in "${BINARIES[@]}"; do
  for arch in arm64 x86_64; do
    rm -rf "$OUTPUT_DIR"
    if run_fixture "$binary" "$arch" >"$TEMP_DIR/build.log" 2>&1; then
      fail "the build accepted a $binary containing only $arch"
    fi
    /usr/bin/lipo "$OUTPUT_DIR/$binary" -verify_arch "$arch"
    case "$arch" in
      arm64) missing_arch=x86_64 ;;
      x86_64) missing_arch=arm64 ;;
    esac
    if /usr/bin/lipo "$OUTPUT_DIR/$binary" -verify_arch "$missing_arch" \
      >/dev/null 2>&1; then
      fail "the negative fixture still contains $missing_arch in $binary"
    fi
  done
done

printf 'Universal macOS Agent architecture checks ok\n'
