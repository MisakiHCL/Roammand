#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

# Shared helpers for Apple release scripts. This file must be sourced.

apple_require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Apple release operations require macOS\n' >&2
    return 1
  fi
}

apple_load_signing_config() {
  local config="${1:-$ROOT_DIR/apps/client_flutter/apple/Signing.local.xcconfig}"
  local mode

  if [[ ! -f "$config" ]]; then
    printf 'local Apple signing configuration is missing\n' >&2
    return 1
  fi
  if [[ "$config" == "$ROOT_DIR/apps/client_flutter/apple/Signing.local.xcconfig" ]] &&
    ! git -C "$ROOT_DIR" check-ignore -q "$config"; then
    printf 'local Apple signing configuration is not ignored\n' >&2
    return 1
  fi

  mode="$(stat -f '%Lp' "$config")"
  if [[ "$mode" != "600" ]]; then
    printf 'local Apple signing configuration must have mode 0600\n' >&2
    return 1
  fi

  APPLE_TEAM_ID="$(awk '
    $1 == "ROAMMAND_APPLE_TEAM_ID" && $2 == "=" && NF == 3 {
      count += 1
      value = $3
    }
    END { if (count == 1) print value }
  ' "$config")"
  APPLE_BUNDLE_ID="$(awk '
    $1 == "ROAMMAND_APPLE_BUNDLE_ID" && $2 == "=" && NF == 3 {
      count += 1
      value = $3
    }
    END { if (count == 1) print value }
  ' "$config")"

  if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    printf 'local Apple Team ID is invalid\n' >&2
    return 1
  fi
  if [[ ! "$APPLE_BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]; then
    printf 'local Apple bundle ID is invalid\n' >&2
    return 1
  fi
}

apple_find_identity_hash() {
  local certificate_type="$1"
  local policy="$2"
  local identities matches count identity_override=""

  identities="$(security find-identity -v -p "$policy" 2>/dev/null || true)"
  matches="$(printf '%s\n' "$identities" | awk \
    -v certificate_type="$certificate_type" \
    -v team="$APPLE_TEAM_ID" '
      index($0, "\"" certificate_type ":") > 0 &&
      index($0, "(" team ")") > 0 &&
      $2 ~ /^[0-9A-Fa-f]{40}$/ {
        print $2
      }
    ')"
  case "$certificate_type" in
    'Developer ID Application')
      identity_override="${ROAMMAND_APPLE_APPLICATION_IDENTITY_SHA1:-}"
      ;;
    'Developer ID Installer')
      identity_override="${ROAMMAND_APPLE_INSTALLER_IDENTITY_SHA1:-}"
      ;;
  esac
  if [[ -n "$identity_override" ]]; then
    identity_override="$(printf '%s' "$identity_override" | tr '[:lower:]' '[:upper:]')"
    if [[ ! "$identity_override" =~ ^[0-9A-F]{40}$ ]] ||
      ! printf '%s\n' "$matches" | awk -v expected="$identity_override" '
        toupper($0) == expected { found += 1 }
        END { exit found != 1 }
      '; then
      printf 'configured %s identity is not a matching valid Keychain identity\n' \
        "$certificate_type" >&2
      return 1
    fi
    printf '%s\n' "$identity_override"
    return 0
  fi
  count="$(printf '%s\n' "$matches" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$count" -ne 1 ]]; then
    printf 'expected exactly one matching %s identity in Keychain\n' \
      "$certificate_type" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

apple_verify_code_signature() {
  local target="$1"
  local expected_identifier="${2:-}"
  local details entitlements

  if ! codesign --verify --strict "$target" >/dev/null 2>&1; then
    return 1
  fi
  details="$(codesign -dvvv "$target" 2>&1 || true)"
  if [[ "$details" != *"TeamIdentifier=$APPLE_TEAM_ID"* ]] ||
    [[ "$details" != *runtime* ]] ||
    [[ "$details" == *'Signature=adhoc'* ]]; then
    return 1
  fi
  if [[ -n "$expected_identifier" ]] &&
    [[ "$details" != *"Identifier=$expected_identifier"* ]]; then
    return 1
  fi
  entitlements="$(codesign -d --entitlements :- "$target" 2>&1 || true)"
  if [[ "$entitlements" == *'com.apple.security.get-task-allow'* ]]; then
    return 1
  fi
}

apple_verify_installer_signature() {
  local package="$1"
  local details

  details="$(pkgutil --check-signature "$package" 2>&1 || true)"
  if [[ "$details" != *'Developer ID Installer:'* ]] ||
    [[ "$details" != *"($APPLE_TEAM_ID)"* ]] ||
    [[ "$details" != *'Signed with a trusted timestamp'* ]]; then
    return 1
  fi
}
