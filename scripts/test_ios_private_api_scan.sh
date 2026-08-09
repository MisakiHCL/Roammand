#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SCANNER="$ROOT_DIR/scripts/check_ios_private_api.sh"
readonly TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/roammand-ios-private-api-test.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

[[ -x "$SCANNER" ]] || {
  printf 'iOS private API scanner is missing or not executable\n' >&2
  exit 1
}

command -v xcrun >/dev/null 2>&1 || {
  printf 'xcrun is required to build Mach-O scanner fixtures\n' >&2
  exit 1
}
command -v zip >/dev/null 2>&1 || {
  printf 'zip is required to build the IPA scanner fixture\n' >&2
  exit 1
}
readonly CLANG="$(xcrun --find clang)"
readonly LIPO="$(xcrun --find lipo)"
readonly CLEAN_SOURCE="$TEMP_DIR/clean.c"
readonly FORBIDDEN_SOURCE="$TEMP_DIR/forbidden.c"
printf '%s\n' \
  '__attribute__((used)) static const char near_miss[] = "buttonPressed";' \
  'int main(void) { return near_miss[0] == 0; }' >"$CLEAN_SOURCE"
printf '%s\n' \
  '__attribute__((used)) static const char selector[] = "buttonPressed:";' \
  'int main(void) { return selector[0] == 0; }' >"$FORBIDDEN_SOURCE"

build_clean_macho() {
  local output="$1"
  local architecture="${2:-}"
  if [[ -n "$architecture" ]]; then
    "$CLANG" -arch "$architecture" -x c -c "$CLEAN_SOURCE" -o "$output"
  else
    "$CLANG" -x c -c "$CLEAN_SOURCE" -o "$output"
  fi
}

build_forbidden_macho() {
  local output="$1"
  local architecture="${2:-}"
  if [[ -n "$architecture" ]]; then
    "$CLANG" -arch "$architecture" -x c -c "$FORBIDDEN_SOURCE" -o "$output"
  else
    "$CLANG" -x c -c "$FORBIDDEN_SOURCE" -o "$output"
  fi
}

expect_pass() {
  local artifact="$1"
  "$SCANNER" "$artifact" >/dev/null
}

expect_private_api_failure() {
  local artifact="$1"
  local output=''
  local status=0
  if output="$($SCANNER "$artifact" 2>&1)"; then
    printf 'scanner accepted forbidden selector in %s\n' "$artifact" >&2
    exit 1
  else
    status="$?"
  fi
  [[ "$status" -eq 1 ]] || {
    printf 'scanner returned the wrong status for forbidden selector in %s\n' \
      "$artifact" >&2
    exit 1
  }
  [[ "$output" == *'buttonPressed:'* ]] || {
    printf 'scanner failure did not identify the forbidden selector\n' >&2
    exit 1
  }
}

expect_invalid_failure() {
  local artifact="$1"
  local output=''
  local status=0
  if output="$($SCANNER "$artifact" 2>&1)"; then
    printf 'scanner accepted invalid artifact %s\n' "$artifact" >&2
    exit 1
  else
    status="$?"
  fi
  [[ "$status" -eq 2 ]] || {
    printf 'scanner returned the wrong status for invalid artifact %s\n' \
      "$artifact" >&2
    exit 1
  }
  [[ "$output" == *'iOS private API scan error:'* ]] || {
    printf 'scanner did not explain why artifact input was invalid\n' >&2
    exit 1
  }
}

readonly CLEAN_APP="$TEMP_DIR/Clean Fixture.app"
mkdir -p "$CLEAN_APP/Frameworks/Clean Framework.framework"
build_clean_macho "$CLEAN_APP/Clean Fixture"
build_clean_macho "$CLEAN_APP/Frameworks/Clean Framework.framework/Clean Framework"
expect_pass "$CLEAN_APP"
expect_pass "$CLEAN_APP/"

readonly BAD_APP="$TEMP_DIR/Bad Framework Fixture.app"
mkdir -p "$BAD_APP/Frameworks/Bad Framework.framework"
build_clean_macho "$BAD_APP/Bad Framework Fixture"
build_clean_macho "$TEMP_DIR/clean-arm64.o" arm64
build_forbidden_macho "$TEMP_DIR/forbidden-x86_64.o" x86_64
"$LIPO" -create \
  "$TEMP_DIR/clean-arm64.o" \
  "$TEMP_DIR/forbidden-x86_64.o" \
  -output "$BAD_APP/Frameworks/Bad Framework.framework/Bad Framework"
expect_private_api_failure "$BAD_APP"

readonly BAD_ARCHIVE="$TEMP_DIR/Bad Extension Fixture.xcarchive"
readonly ARCHIVE_APP="$BAD_ARCHIVE/Products/Applications/Archive App.app"
mkdir -p "$ARCHIVE_APP/PlugIns/Share Extension.appex"
build_clean_macho "$ARCHIVE_APP/Archive App"
build_forbidden_macho "$ARCHIVE_APP/PlugIns/Share Extension.appex/Share Extension"
expect_private_api_failure "$BAD_ARCHIVE"

readonly IPA_ROOT="$TEMP_DIR/ipa source"
readonly IPA_APP="$IPA_ROOT/Payload/IPA Fixture.app"
readonly BAD_IPA="$TEMP_DIR/Bad IPA Fixture.ipa"
mkdir -p "$IPA_APP"
build_forbidden_macho "$IPA_APP/IPA Fixture"
(
  cd "$IPA_ROOT"
  zip -qry "$BAD_IPA" Payload
)
expect_private_api_failure "$BAD_IPA"

expect_invalid_failure "$TEMP_DIR/not-an-artifact"

readonly EMPTY_APP="$TEMP_DIR/Empty Fixture.app"
mkdir -p "$EMPTY_APP"
expect_invalid_failure "$EMPTY_APP"

readonly MALFORMED_IPA="$TEMP_DIR/Malformed Fixture.ipa"
printf 'not a zip archive\n' >"$MALFORMED_IPA"
expect_invalid_failure "$MALFORMED_IPA"

printf 'iOS private API scanner tests passed\n'
