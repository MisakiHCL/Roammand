#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly FORBIDDEN_SELECTOR='buttonPressed:'

usage() {
  printf 'Usage: %s PATH_TO_APP_OR_XCARCHIVE_OR_IPA\n' "$(basename "$0")" >&2
}

fail() {
  printf 'iOS private API scan error: %s\n' "$1" >&2
  exit 2
}

if [[ "$#" -ne 1 ]]; then
  usage
  exit 2
fi

artifact="${1%/}"
[[ -n "$artifact" ]] || fail 'artifact path must not be empty'
[[ -e "$artifact" ]] || fail "artifact does not exist: $artifact"

for tool in file find grep mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

readonly WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/roammand-ios-private-api.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

scan_root=''
ipa_display_prefix=''
case "$artifact" in
  *.app)
    [[ -d "$artifact" ]] || fail ".app artifact is not a directory: $artifact"
    scan_root="$artifact"
    ;;
  *.xcarchive)
    [[ -d "$artifact" ]] || fail ".xcarchive artifact is not a directory: $artifact"
    applications_dir="$artifact/Products/Applications"
    [[ -d "$applications_dir" ]] ||
      fail ".xcarchive has no Products/Applications directory: $artifact"
    shopt -s nullglob
    archive_apps=("$applications_dir"/*.app)
    shopt -u nullglob
    [[ "${#archive_apps[@]}" -gt 0 ]] ||
      fail ".xcarchive contains no application bundle: $artifact"
    scan_root="$artifact"
    ;;
  *.ipa)
    [[ -f "$artifact" ]] || fail ".ipa artifact is not a regular file: $artifact"
    command -v unzip >/dev/null 2>&1 || fail 'required tool is unavailable: unzip'
    extracted_ipa="$WORK_DIR/extracted-ipa"
    mkdir -p "$extracted_ipa"
    if ! unzip -qq "$artifact" -d "$extracted_ipa"; then
      fail "could not extract .ipa artifact: $artifact"
    fi
    payload_dir="$extracted_ipa/Payload"
    [[ -d "$payload_dir" ]] || fail ".ipa contains no Payload directory: $artifact"
    shopt -s nullglob
    ipa_apps=("$payload_dir"/*.app)
    shopt -u nullglob
    [[ "${#ipa_apps[@]}" -gt 0 ]] ||
      fail ".ipa contains no application bundle: $artifact"
    scan_root="$extracted_ipa"
    ipa_display_prefix="$artifact!/"
    ;;
  *)
    fail "unsupported artifact type (expected .app, .xcarchive, or .ipa): $artifact"
    ;;
esac

readonly FILE_LIST="$WORK_DIR/files"
find "$scan_root" -type f -print0 >"$FILE_LIST"

scanned_count=0
hit_count=0
declare -a hit_paths=()

while IFS= read -r -d '' candidate; do
  if ! file_description="$(LC_ALL=C file -b "$candidate")"; then
    fail "could not identify file type: $candidate"
  fi
  case "$file_description" in
    *Mach-O*) ;;
    *) continue ;;
  esac

  scanned_count=$((scanned_count + 1))
  # Search the literal byte sequence. Objective-C metadata inspection alone
  # misses selectors stored only in a Mach-O __TEXT.__cstring section.
  if LC_ALL=C grep -aFq -- "$FORBIDDEN_SELECTOR" "$candidate"; then
    hit_count=$((hit_count + 1))
    if [[ -n "$ipa_display_prefix" ]]; then
      hit_paths+=("${ipa_display_prefix}${candidate#"$scan_root"/}")
    else
      hit_paths+=("$candidate")
    fi
  else
    grep_status="$?"
    if [[ "$grep_status" -gt 1 ]]; then
      fail "could not scan Mach-O file: $candidate"
    fi
  fi
done <"$FILE_LIST"

if [[ "$scanned_count" -eq 0 ]]; then
  fail "artifact contains no Mach-O files: $artifact"
fi

if [[ "$hit_count" -gt 0 ]]; then
  printf 'Forbidden ReplayKit selector %s found in %d Mach-O file(s):\n' \
    "$FORBIDDEN_SELECTOR" "$hit_count" >&2
  for hit_path in "${hit_paths[@]}"; do
    printf '  %s\n' "$hit_path" >&2
  done
  printf 'Scanned %d Mach-O file(s); iOS private API scan failed.\n' \
    "$scanned_count" >&2
  exit 1
fi

printf 'iOS private API scan passed: %d Mach-O file(s), 0 occurrences of %s\n' \
  "$scanned_count" "$FORBIDDEN_SELECTOR"
