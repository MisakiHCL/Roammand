#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/dist/m8-macos"
APP_BUNDLE=""
HOST_AGENT=""
BRIDGE=""
SESSION_AGENT=""
WEBRTC_ARM64_LICENSE=""
WEBRTC_X64_LICENSE=""

while (($#)); do
  case "$1" in
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --app-bundle) APP_BUNDLE="$2"; shift 2 ;;
    --host-agent) HOST_AGENT="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --session-agent) SESSION_AGENT="$2"; shift 2 ;;
    --webrtc-arm64-license) WEBRTC_ARM64_LICENSE="$2"; shift 2 ;;
    --webrtc-x64-license) WEBRTC_X64_LICENSE="$2"; shift 2 ;;
    *) printf 'unknown macOS package option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$APP_BUNDLE$HOST_AGENT$BRIDGE$SESSION_AGENT" ]]; then
  if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    printf 'refusing release build from a dirty worktree\n' >&2
    exit 1
  fi
  ./scripts/build_macos_universal_agents.sh
  # Dependency resolution is explicit in `make bootstrap`; packaging reuses
  # the locked cache and must not depend on pub.dev being reachable.
  (cd apps/client_flutter && flutter build macos --release --no-pub)
  APP_BUNDLE="$ROOT_DIR/apps/client_flutter/build/macos/Build/Products/Release/roammand.app"
  HOST_AGENT="$ROOT_DIR/target/macos-universal/release/roammand-host-agent"
  BRIDGE="$ROOT_DIR/target/macos-universal/release/roammand-privileged-bridge"
  SESSION_AGENT="$ROOT_DIR/target/macos-universal/release/roammand-session-agent"
  WEBRTC_ARM64_LICENSE="$(./scripts/fetch_libwebrtc.sh webrtc-mac-arm64-release.zip)/LICENSE.md"
  WEBRTC_X64_LICENSE="$(./scripts/fetch_libwebrtc.sh webrtc-mac-x64-release.zip)/LICENSE.md"
elif [[ -z "$APP_BUNDLE" || -z "$HOST_AGENT" || -z "$BRIDGE" || -z "$SESSION_AGENT" ]]; then
  printf 'all four artifact overrides are required together\n' >&2
  exit 2
elif [[ -z "$WEBRTC_ARM64_LICENSE" || -z "$WEBRTC_X64_LICENSE" ]]; then
  printf 'both libwebrtc license overrides are required with artifact overrides\n' >&2
  exit 2
fi

for artifact in \
  "$APP_BUNDLE" \
  "$HOST_AGENT" \
  "$BRIDGE" \
  "$SESSION_AGENT" \
  "$WEBRTC_ARM64_LICENSE" \
  "$WEBRTC_X64_LICENSE"; do
  [[ -e "$artifact" ]] || { printf 'missing package artifact\n' >&2; exit 1; }
done
for license in "$WEBRTC_ARM64_LICENSE" "$WEBRTC_X64_LICENSE"; do
  [[ -f "$license" && -s "$license" ]] || {
    printf 'libwebrtc license must be a non-empty regular file\n' >&2
    exit 1
  }
done

output_name="$(basename "$OUTPUT_DIR")"
if [[ -z "$output_name" || "$output_name" == "/" || "$output_name" == "." || "$output_name" == ".." ]]; then
  printf 'unsafe macOS package output directory\n' >&2
  exit 2
fi
output_parent_input="$(dirname "$OUTPUT_DIR")"
install -d -m 0755 "$output_parent_input"
output_parent="$(cd "$output_parent_input" && pwd -P)"
OUTPUT_DIR="$output_parent/$output_name"
if [[ "$OUTPUT_DIR" == "/" ||
      "$OUTPUT_DIR" == "$ROOT_DIR" ||
      "$ROOT_DIR" == "$OUTPUT_DIR/"* ||
      -L "$OUTPUT_DIR" ]]; then
  printf 'unsafe macOS package output directory\n' >&2
  exit 2
fi

readonly OUTPUT_MARKER="$OUTPUT_DIR/.roammand-package-output"
if [[ -e "$OUTPUT_MARKER" && (! -f "$OUTPUT_MARKER" || -L "$OUTPUT_MARKER") ]]; then
  printf 'unsafe macOS package output marker\n' >&2
  exit 2
fi
if [[ -f "$OUTPUT_MARKER" && "$(sed -n '1p' "$OUTPUT_MARKER")" != "$OUTPUT_DIR" ]]; then
  printf 'macOS package output marker does not match its directory\n' >&2
  exit 2
fi
if [[ -e "$OUTPUT_DIR" && ! -d "$OUTPUT_DIR" ]]; then
  printf 'macOS package output must be a directory\n' >&2
  exit 2
fi
existing_package_output=false
if [[ -d "$OUTPUT_DIR/Applications/Roammand.app" &&
      -x "$OUTPUT_DIR/Library/PrivilegedHelperTools/roammand-host-agent" &&
      -f "$OUTPUT_DIR/Library/Application Support/Roammand/install-manifest.sha256" ]]; then
  existing_package_output=true
fi
if [[ -d "$OUTPUT_DIR" &&
      -n "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" &&
      ! -f "$OUTPUT_MARKER" &&
      "$existing_package_output" != true ]]; then
  printf 'refusing to replace an unmarked non-empty output directory\n' >&2
  exit 2
fi

rm -rf -- "$OUTPUT_DIR"
install -d -m 0755 \
  "$OUTPUT_DIR/Applications" \
  "$OUTPUT_DIR/Library/PrivilegedHelperTools" \
  "$OUTPUT_DIR/Library/LaunchAgents" \
  "$OUTPUT_DIR/Library/Application Support/Roammand/launchd" \
  "$OUTPUT_DIR/Library/Application Support/Roammand/licenses"
printf '%s\n' "$OUTPUT_DIR" >"$OUTPUT_MARKER"
chmod 0644 "$OUTPUT_MARKER"
cp -R "$APP_BUNDLE" "$OUTPUT_DIR/Applications/Roammand.app"
install -m 0755 "$HOST_AGENT" \
  "$OUTPUT_DIR/Library/PrivilegedHelperTools/roammand-host-agent"
install -m 0755 "$BRIDGE" \
  "$OUTPUT_DIR/Library/PrivilegedHelperTools/roammand-privileged-bridge"
readonly SESSION_AGENT_APP="$OUTPUT_DIR/Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app"
readonly SESSION_AGENT_BINARY="$SESSION_AGENT_APP/Contents/MacOS/roammand-session-agent"
readonly SESSION_AGENT_PLIST="$OUTPUT_DIR/Library/LaunchAgents/dev.roammand.SessionAgent.plist"
readonly PRIVILEGED_BRIDGE_PLIST="$OUTPUT_DIR/Library/Application Support/Roammand/launchd/com.hclgame.roammand.PrivilegedBridge.plist"
readonly ASSOCIATED_BUNDLE_IDENTIFIERS_KEY="AssociatedBundleIdentifiers"
install -d -m 0755 "$SESSION_AGENT_APP/Contents/MacOS"
install -m 0644 packaging/macos/session-agent/Info.plist \
  "$SESSION_AGENT_APP/Contents/Info.plist"
install -m 0755 "$SESSION_AGENT" "$SESSION_AGENT_BINARY"

app_info="$OUTPUT_DIR/Applications/Roammand.app/Contents/Info.plist"
app_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_info" 2>/dev/null || true)"
app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_info" 2>/dev/null || true)"
app_build="$(plutil -extract CFBundleVersion raw -o - "$app_info" 2>/dev/null || true)"
if [[ ! "$app_bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]] ||
  [[ ! "$app_version" =~ ^[0-9]+(\.[0-9]+)+$ ]] ||
  [[ ! "$app_build" =~ ^[0-9]+$ ]]; then
  printf 'staged macOS app metadata is invalid\n' >&2
  exit 1
fi
plutil -replace CFBundleIdentifier -string "$app_bundle_id.session-agent" \
  "$SESSION_AGENT_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$app_version" \
  "$SESSION_AGENT_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$app_build" \
  "$SESSION_AGENT_APP/Contents/Info.plist"
install -m 0644 packaging/macos/com.hclgame.roammand.PrivilegedBridge.plist \
  "$PRIVILEGED_BRIDGE_PLIST"
install -m 0644 packaging/macos/dev.roammand.SessionAgent.plist \
  "$SESSION_AGENT_PLIST"
for job_plist in "$SESSION_AGENT_PLIST" "$PRIVILEGED_BRIDGE_PLIST"; do
  plutil -insert "$ASSOCIATED_BUNDLE_IDENTIFIERS_KEY" -array "$job_plist"
  plutil -insert "${ASSOCIATED_BUNDLE_IDENTIFIERS_KEY}.0" \
    -string "$app_bundle_id" "$job_plist"
  if [[ "$(plutil -extract "${ASSOCIATED_BUNDLE_IDENTIFIERS_KEY}.0" \
    raw -o - "$job_plist" 2>/dev/null || true)" != "$app_bundle_id" ]]; then
    printf 'staged macOS background item association is invalid\n' >&2
    exit 1
  fi
done
install -m 0644 licenses/MPL-2.0.txt licenses/Apache-2.0.txt \
  "$OUTPUT_DIR/Library/Application Support/Roammand/licenses/"
install -m 0644 "$WEBRTC_ARM64_LICENSE" \
  "$OUTPUT_DIR/Library/Application Support/Roammand/licenses/libwebrtc-macos-arm64-LICENSE.md"
install -m 0644 "$WEBRTC_X64_LICENSE" \
  "$OUTPUT_DIR/Library/Application Support/Roammand/licenses/libwebrtc-macos-x86_64-LICENSE.md"
install -m 0755 scripts/uninstall_m8_macos.sh \
  "$OUTPUT_DIR/Library/Application Support/Roammand/uninstall-macos.sh"

./scripts/write_macos_package_manifest.sh "$OUTPUT_DIR" >/dev/null

printf 'staged macOS package directory\n'
