#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && { DRY_RUN=true; shift; }
(($# == 0)) || { printf 'unknown macOS uninstall option\n' >&2; exit 2; }

if $DRY_RUN; then
  printf 'would remove Roammand, its services, system permissions, device identity, pairings, preferences, caches, runtime files, and logs; no changes made\n'
  exit 0
fi
[[ "$EUID" -eq 0 ]] || { printf 'administrator privileges are required; run with sudo or use --dry-run\n' >&2; exit 1; }

readonly SERVICE_DATA_DIR="/Library/Application Support/Roammand"
readonly SESSION_AGENT_APP="/Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app"
readonly SESSION_AGENT="$SESSION_AGENT_APP/Contents/MacOS/roammand-session-agent"
readonly HOST_AGENT="/Library/PrivilegedHelperTools/roammand-host-agent"
readonly APP="/Applications/Roammand.app"
readonly PACKAGE_RECEIPT_ID="dev.roammand.pkg"
readonly OWNER_ID_FILE="$SERVICE_DATA_DIR/bridge-owner-id"
readonly USER_HOME_ROOT="/Users"
readonly INSTALLED_APP_PATTERN='^/Applications/Roammand[.]app/Contents/MacOS/roammand([[:space:]]|$)'
readonly INSTALLED_HOST_AGENT_PATTERN='^/Library/PrivilegedHelperTools/roammand-host-agent([[:space:]]|$)'
readonly INSTALLED_BRIDGE_PATTERN='^/Library/PrivilegedHelperTools/roammand-privileged-bridge([[:space:]]|$)'
readonly INSTALLED_SESSION_AGENT_PATTERN='^/Applications/Roammand[.]app/Contents/Library/LoginItems/RoammandSessionAgent[.]app/Contents/MacOS/roammand-session-agent([[:space:]]|$)'
readonly LEGACY_SESSION_AGENT_PATTERN='^/Library/PrivilegedHelperTools/roammand-session-agent([[:space:]]|$)'
readonly BRIDGE_SERVICE="com.hclgame.roammand.PrivilegedBridge"
readonly LEGACY_BRIDGE_SERVICE="dev.roammand.PrivilegedBridge"

fail_cleanup() {
  printf 'unable to verify or completely remove Roammand local data and permissions\n' >&2
  exit 1
}

read_bundle_id() {
  /usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" \
    2>/dev/null || true
}

valid_bundle_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]
}

[[ -f "$OWNER_ID_FILE" && -d "$APP" && -d "$SESSION_AGENT_APP" && \
  -x "$HOST_AGENT" && -x "$SESSION_AGENT" ]] || fail_cleanup

OWNER_ID="$(/usr/bin/tr -d '[:space:]' <"$OWNER_ID_FILE")"
[[ "$OWNER_ID" =~ ^[0-9]+$ && "$OWNER_ID" != "0" ]] || fail_cleanup
OWNER_NAME="$(/usr/bin/id -nu "$OWNER_ID" 2>/dev/null || true)"
[[ "$OWNER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail_cleanup
OWNER_HOME="$(/usr/bin/dscl . -read "$USER_HOME_ROOT/$OWNER_NAME" NFSHomeDirectory \
  2>/dev/null | /usr/bin/sed -n 's/^NFSHomeDirectory: //p')"
[[ "$OWNER_HOME" == "$USER_HOME_ROOT"/* && -d "$OWNER_HOME/Library" && \
  ! -L "$OWNER_HOME" && ! -L "$OWNER_HOME/Library" && \
  "$(/usr/bin/stat -f '%u' "$OWNER_HOME" 2>/dev/null || true)" == "$OWNER_ID" ]] || \
  fail_cleanup

for parent in \
  "$OWNER_HOME/Library/Application Support" \
  "$OWNER_HOME/Library/Caches" \
  "$OWNER_HOME/Library/Preferences" \
  "$OWNER_HOME/Library/Saved Application State" \
  "$OWNER_HOME/Library/HTTPStorages" \
  "$OWNER_HOME/Library/WebKit" \
  "$OWNER_HOME/Library/Containers" \
  "$OWNER_HOME/Library/Logs"; do
  [[ ! -e "$parent" || (-d "$parent" && ! -L "$parent") ]] || fail_cleanup
done

APP_BUNDLE_ID="$(read_bundle_id "$APP")"
SESSION_BUNDLE_ID="$(read_bundle_id "$SESSION_AGENT_APP")"
valid_bundle_id "$APP_BUNDLE_ID" || fail_cleanup
[[ "$SESSION_BUNDLE_ID" == "$APP_BUNDLE_ID.session-agent" ]] || fail_cleanup

launchctl bootout "gui/$OWNER_ID/dev.roammand.SessionAgent" 2>/dev/null || true
launchctl bootout "gui/$OWNER_ID/dev.roammand.HostAgent" 2>/dev/null || true
launchctl bootout "system/$BRIDGE_SERVICE" 2>/dev/null || true
launchctl bootout "system/$LEGACY_BRIDGE_SERVICE" 2>/dev/null || true
/usr/bin/pkill -TERM -f "$INSTALLED_HOST_AGENT_PATTERN" 2>/dev/null || true
/usr/bin/pkill -TERM -f "$INSTALLED_BRIDGE_PATTERN" 2>/dev/null || true
/usr/bin/pkill -TERM -f "$INSTALLED_SESSION_AGENT_PATTERN" 2>/dev/null || true
/usr/bin/pkill -TERM -f "$LEGACY_SESSION_AGENT_PATTERN" 2>/dev/null || true
/usr/bin/pkill -TERM -f "$INSTALLED_APP_PATTERN" 2>/dev/null || true

for service in Accessibility ScreenCapture; do
  /usr/bin/tccutil reset "$service" "$SESSION_BUNDLE_ID" >/dev/null 2>&1 || fail_cleanup
  /usr/bin/tccutil reset "$service" "$APP_BUNDLE_ID" >/dev/null 2>&1 || fail_cleanup
done

/bin/launchctl asuser "$OWNER_ID" /usr/bin/sudo -u "$OWNER_NAME" -H \
  "$HOST_AGENT" macos-delete-host-identity >/dev/null 2>&1 || fail_cleanup
/bin/launchctl asuser "$OWNER_ID" /usr/bin/sudo -u "$OWNER_NAME" -H \
  /usr/bin/defaults delete "$APP_BUNDLE_ID" >/dev/null 2>&1 || true

rm -rf \
  "$OWNER_HOME/Library/Application Support/Roammand" \
  "$OWNER_HOME/Library/Application Support/Personal Remote Desktop" \
  "$OWNER_HOME/Library/Application Support/$APP_BUNDLE_ID" \
  "$OWNER_HOME/Library/Caches/Roammand" \
  "$OWNER_HOME/Library/Caches/Personal Remote Desktop" \
  "$OWNER_HOME/Library/Caches/$APP_BUNDLE_ID" \
  "$OWNER_HOME/Library/Saved Application State/$APP_BUNDLE_ID.savedState" \
  "$OWNER_HOME/Library/HTTPStorages/$APP_BUNDLE_ID" \
  "$OWNER_HOME/Library/WebKit/$APP_BUNDLE_ID" \
  "$OWNER_HOME/Library/Containers/$APP_BUNDLE_ID" \
  "$OWNER_HOME/Library/Logs/Roammand"
rm -f "$OWNER_HOME/Library/Preferences/$APP_BUNDLE_ID.plist"

pkgutil --forget "$PACKAGE_RECEIPT_ID" >/dev/null 2>&1 || true
rm -f "/Library/LaunchDaemons/$BRIDGE_SERVICE.plist" \
  "/Library/LaunchDaemons/$LEGACY_BRIDGE_SERVICE.plist" \
  "/Library/LaunchAgents/dev.roammand.HostAgent.plist" \
  "/Library/LaunchAgents/dev.roammand.SessionAgent.plist" \
  "/Library/PrivilegedHelperTools/roammand-host-agent" \
  "/Library/PrivilegedHelperTools/roammand-privileged-bridge" \
  "/Library/PrivilegedHelperTools/roammand-session-agent" \
  "/var/run/roammand/bridge.sock" \
  "/var/log/roammand-privileged-bridge.log"
rm -rf "/var/run/roammand" "$SERVICE_DATA_DIR" "$APP"
printf 'Roammand program files, local data, and system permissions were removed\n'
