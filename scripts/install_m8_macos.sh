#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/dist/m8-macos"
DRY_RUN=false
while (($#)); do
  case "$1" in
    --package) PACKAGE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) printf 'unknown macOS install option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

"$ROOT_DIR/scripts/check_m8_macos_package.sh" "$PACKAGE_DIR" >/dev/null
if $DRY_RUN; then
  printf 'would install verified app, GUI-managed Host Agent, daemon, session agent, launchd files, and manifest; no changes made\n'
  exit 0
fi
[[ "$EUID" -eq 0 ]] || { printf 'administrator privileges are required; run with sudo or use --dry-run\n' >&2; exit 1; }
readonly INSTALL_UID="${SUDO_UID:-}"
if [[ ! "$INSTALL_UID" =~ ^[0-9]+$ || "$INSTALL_UID" == "0" ]]; then
  printf 'run the installer with sudo from the Host owner account\n' >&2
  exit 1
fi

readonly SERVICE_DATA_DIR="/Library/Application Support/Roammand"
readonly INSTALL_SECRET="$SERVICE_DATA_DIR/bridge-install-secret.bin"
readonly OWNER_ID="$SERVICE_DATA_DIR/bridge-owner-id"
readonly BRIDGE_RUNTIME_DIR="/var/run/roammand"
readonly BRIDGE_SERVICE="com.hclgame.roammand.PrivilegedBridge"
readonly LEGACY_BRIDGE_SERVICE="dev.roammand.PrivilegedBridge"
readonly BRIDGE_SOURCE="$PACKAGE_DIR/Library/Application Support/Roammand/launchd/$BRIDGE_SERVICE.plist"
readonly BRIDGE_PLIST="/Library/LaunchDaemons/$BRIDGE_SERVICE.plist"
readonly LEGACY_BRIDGE_PLIST="/Library/LaunchDaemons/$LEGACY_BRIDGE_SERVICE.plist"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[[ -f "$BRIDGE_SOURCE" && -x "$LSREGISTER" ]] || {
  printf 'macOS bridge registration inputs are unavailable\n' >&2
  exit 1
}
launchctl bootout "system/$BRIDGE_SERVICE" 2>/dev/null || true
launchctl bootout "system/$LEGACY_BRIDGE_SERVICE" 2>/dev/null || true
launchctl bootout "gui/$INSTALL_UID/dev.roammand.HostAgent" 2>/dev/null || true
launchctl bootout "gui/$INSTALL_UID/dev.roammand.SessionAgent" 2>/dev/null || true
rm -f "/Library/LaunchAgents/dev.roammand.HostAgent.plist"
rm -f "/Library/PrivilegedHelperTools/roammand-session-agent"
rm -f "$BRIDGE_PLIST" "$LEGACY_BRIDGE_PLIST"
rm -rf "/Applications/Roammand.app" "$SERVICE_DATA_DIR"
cp -R "$PACKAGE_DIR/Applications/Roammand.app" "/Applications/Roammand.app"
install -d -o root -g wheel -m 0755 "/Library/PrivilegedHelperTools" \
  "/Library/LaunchDaemons" "/Library/LaunchAgents" \
  "$SERVICE_DATA_DIR/launchd" "$SERVICE_DATA_DIR/licenses" "$BRIDGE_RUNTIME_DIR"
install -o root -g wheel -m 0755 "$PACKAGE_DIR/Library/PrivilegedHelperTools/"* \
  "/Library/PrivilegedHelperTools/"
install -o root -g wheel -m 0644 "$PACKAGE_DIR/Library/LaunchAgents/"* \
  "/Library/LaunchAgents/"
install -o root -g wheel -m 0644 "$BRIDGE_SOURCE" \
  "$SERVICE_DATA_DIR/launchd/$BRIDGE_SERVICE.plist"
install -o root -g wheel -m 0644 \
  "$PACKAGE_DIR/Library/Application Support/Roammand/install-manifest.sha256" \
  "$SERVICE_DATA_DIR/install-manifest.sha256"
install -o root -g wheel -m 0644 \
  "$PACKAGE_DIR/Library/Application Support/Roammand/licenses/"* \
  "$SERVICE_DATA_DIR/licenses/"
install -o root -g wheel -m 0755 \
  "$PACKAGE_DIR/Library/Application Support/Roammand/uninstall-macos.sh" \
  "$SERVICE_DATA_DIR/uninstall-macos.sh"
umask 077
dd if=/dev/urandom of="$INSTALL_SECRET" bs=32 count=1 2>/dev/null
chown "$INSTALL_UID":wheel "$INSTALL_SECRET"
chmod 0400 "$INSTALL_SECRET"
printf '%s\n' "$INSTALL_UID" >"$OWNER_ID"
chown root:wheel "$OWNER_ID"
chmod 0444 "$OWNER_ID"
chown root:wheel "$BRIDGE_RUNTIME_DIR"
chmod 0755 "$BRIDGE_RUNTIME_DIR"
"$LSREGISTER" -f "/Applications/Roammand.app" >/dev/null 2>&1
install -o root -g wheel -m 0644 \
  "$SERVICE_DATA_DIR/launchd/$BRIDGE_SERVICE.plist" "$BRIDGE_PLIST"
launchctl bootstrap system "$BRIDGE_PLIST"
launchctl kickstart -k "system/$BRIDGE_SERVICE"
launchctl bootstrap "gui/$INSTALL_UID" "/Library/LaunchAgents/dev.roammand.SessionAgent.plist"
launchctl kickstart -k "gui/$INSTALL_UID/dev.roammand.SessionAgent"
printf 'macOS Host components installed; open Roammand to start its Host Agent\n'
