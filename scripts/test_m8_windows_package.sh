#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if command -v xmllint >/dev/null; then
  xmllint --noout packaging/windows/RoammandPrivilegedBridge.xml
fi
rg -q '<account>LocalSystem</account>' packaging/windows/RoammandPrivilegedBridge.xml
rg -q '<startType>automatic</startType>' packaging/windows/RoammandPrivilegedBridge.xml
rg -q '<interactive>false</interactive>' packaging/windows/RoammandPrivilegedBridge.xml
rg -q 'Program Files\\Roammand' packaging/windows scripts/*m8_windows.ps1
rg -q 'ProgramData.*Roammand' scripts/install_m8_windows.ps1
rg -q 'Roammand Privileged Bridge' packaging/windows/RoammandPrivilegedBridge.xml scripts/install_m8_windows.ps1
rg -q 'sc\.exe failure' scripts/install_m8_windows.ps1
rg -q -- '--features native-webrtc' scripts/package_m8_windows.ps1
rg -q 'bridge-owner-sid\.txt' scripts/install_m8_windows.ps1
rg -q 'bridge-install-secret\.bin' scripts/install_m8_windows.ps1
rg -q 'Identity\.User\.Value' scripts/install_m8_windows.ps1
rg -q 'WhatIf' scripts/install_m8_windows.ps1 scripts/uninstall_m8_windows.ps1
rg -q 'preserv.*identity.*grant' scripts/uninstall_m8_windows.ps1
rg -q 'package_m8_windows\.ps1' scripts/package_windows.ps1
rg -q 'check_m8_windows_package\.ps1' scripts/check_windows_package.ps1
rg -q 'install_m8_windows\.ps1' scripts/install_windows.ps1
rg -q 'uninstall_m8_windows\.ps1' scripts/uninstall_windows.ps1
if rg -ni '(private[_ -]?key|seed|turn[_ -]?password|certificate|/Users/|interactive=true|cmd\.exe|powershell\.exe -command)' \
  packaging/windows scripts/*m8_windows.ps1; then
  printf 'Windows package contains forbidden credential, local path, or interactive service setting\n' >&2
  exit 1
fi

if command -v pwsh >/dev/null; then
  readonly TEMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TEMP_DIR"' EXIT
  mkdir -p "$TEMP_DIR/app"
  printf 'app\n' >"$TEMP_DIR/app/roammand.exe"
  printf 'host\n' >"$TEMP_DIR/host.exe"
  printf '%s\n' 'fn main() {}' >"$TEMP_DIR/role_fixture.rs"
  rustc "$TEMP_DIR/role_fixture.rs" -o "$TEMP_DIR/bridge.exe"
  cp "$TEMP_DIR/bridge.exe" "$TEMP_DIR/helper.exe"
  pwsh -NoProfile -File scripts/package_windows.ps1 \
    -Output "$TEMP_DIR/package" -AppDirectory "$TEMP_DIR/app" \
    -HostAgent "$TEMP_DIR/host.exe" -Bridge "$TEMP_DIR/bridge.exe" \
    -SessionHelper "$TEMP_DIR/helper.exe"
  pwsh -NoProfile -File scripts/check_windows_package.ps1 -Package "$TEMP_DIR/package"
  pwsh -NoProfile -File scripts/install_windows.ps1 -Package "$TEMP_DIR/package" -WhatIf
  pwsh -NoProfile -File scripts/uninstall_windows.ps1 -WhatIf
fi

printf 'M8 Windows package contract ok\n'
