#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cd "$ROOT_DIR"

plutil -lint packaging/macos/*.plist packaging/macos/session-agent/Info.plist >/dev/null
rg -q '<string>com\.hclgame\.roammand\.PrivilegedBridge</string>' \
  packaging/macos/com.hclgame.roammand.PrivilegedBridge.plist
test ! -e packaging/macos/dev.roammand.PrivilegedBridge.plist
rg -q '<string>Aqua</string>' packaging/macos/dev.roammand.SessionAgent.plist
rg -q '<string>LoginWindow</string>' packaging/macos/dev.roammand.SessionAgent.plist
rg -q 'AssociatedBundleIdentifiers' scripts/package_m8_macos.sh
test ! -e packaging/macos/dev.roammand.HostAgent.plist
test "$(rg -c 'MACOSX_DEPLOYMENT_TARGET = 14\.4;' apps/client_flutter/macos/Runner.xcodeproj/project.pbxproj)" -eq 3
test "$(rg -c 'ENABLE_HARDENED_RUNTIME = YES;' apps/client_flutter/macos/Runner.xcodeproj/project.pbxproj)" -eq 1
rg -q 'build_macos_universal_agents\.sh' scripts/package_m8_macos.sh
rg -q -- '--target "\$target"' scripts/build_macos_universal_agents.sh
rg -q 'webrtc-mac-arm64-release\.zip' scripts/build_macos_universal_agents.sh
rg -q 'webrtc-mac-x64-release\.zip' scripts/build_macos_universal_agents.sh
rg -q 'webrtc-mac-arm64-release\.zip.*LICENSE\.md' scripts/package_m8_macos.sh
rg -q 'webrtc-mac-x64-release\.zip.*LICENSE\.md' scripts/package_m8_macos.sh
rg -q 'roammand-package-output' \
  scripts/package_m8_macos.sh \
  scripts/write_macos_package_manifest.sh \
  scripts/build_macos_pkg.sh
rg -q 'lipo -create' scripts/build_macos_universal_agents.sh
rg -q 'rustc-link-arg-bin=.*=-ObjC' crates/privileged-bridge/build.rs
rg -q 'stringForAbslStringView' scripts/check_m8_macos_package.sh
rg -q -- 'flutter build macos --release --no-pub' scripts/package_m8_macos.sh
rg -q -- '--options runtime' scripts/sign_macos_release.sh
rg -q -- '--timestamp' scripts/sign_macos_release.sh
rg -q 'Developer ID Application' scripts/sign_macos_release.sh
rg -q 'stage_macos_release_compliance\.sh' Makefile scripts/sign_macos_release.sh
rg -q -- '--require-compliance' \
  Makefile scripts/sign_macos_release.sh
rg -Fq 'check_m8_macos_package.sh' scripts/build_macos_pkg.sh
rg -q -- '--require-compliance' scripts/build_macos_pkg.sh
rg -q 'ROAMMAND_MACOS_SOURCE_REVISION' scripts/stage_macos_release_compliance.sh
rg -q 'ROAMMAND_MACOS_SOURCE_URL' scripts/stage_macos_release_compliance.sh
rg -Fq "readonly COPYRIGHT_HOLDER='ChengLong Hu'" \
  scripts/stage_macos_release_compliance.sh
rg -Fq "readonly REPOSITORY_URL='https://github.com/MisakiHCL/roammand'" \
  scripts/stage_macos_release_compliance.sh
rg -Fq '$REPOSITORY_URL/tree/$source_revision' \
  scripts/stage_macos_release_compliance.sh
rg -Fq -- '--copyright-holder "$COPYRIGHT_HOLDER"' \
  scripts/stage_macos_release_compliance.sh
rg -q 'Developer ID Installer' scripts/build_macos_pkg.sh
rg -q 'pkgbuild --analyze' scripts/build_macos_pkg.sh
rg -q 'BundleIsRelocatable' scripts/build_macos_pkg.sh
rg -q -- '--component-plist' scripts/build_macos_pkg.sh
rg -q 'notarytool submit' scripts/notarize_macos_pkg.sh
rg -q -- '--timeout 2h' scripts/notarize_macos_pkg.sh
rg -q 'stapler staple' scripts/notarize_macos_pkg.sh
rg -q 'spctl --assess --type install' scripts/notarize_macos_pkg.sh
rg -q -- '--keychain-profile' scripts/notarize_macos_pkg.sh
rg -q '/dev/console' packaging/macos/scripts/postinstall
rg -Fq '"$LSREGISTER" -f "$APP_PATH"' packaging/macos/scripts/postinstall
rg -Fq '/usr/bin/install -o root -g wheel -m 0644 "$DAEMON_SOURCE" "$DAEMON_PLIST"' \
  packaging/macos/scripts/postinstall
readonly APP_REGISTER_LINE="$(rg -n -F '"$LSREGISTER" -f "$APP_PATH"' \
  packaging/macos/scripts/postinstall | cut -d: -f1 | head -n 1)"
readonly DAEMON_INSTALL_LINE="$(rg -n -F '/usr/bin/install -o root -g wheel -m 0644 "$DAEMON_SOURCE" "$DAEMON_PLIST"' \
  packaging/macos/scripts/postinstall | cut -d: -f1)"
if [[ ! "$APP_REGISTER_LINE" =~ ^[0-9]+$ ||
      ! "$DAEMON_INSTALL_LINE" =~ ^[0-9]+$ ||
      "$APP_REGISTER_LINE" -ge "$DAEMON_INSTALL_LINE" ]]; then
  printf 'macOS installer exposes the daemon plist before registering the app\n' >&2
  exit 1
fi
rg -q 'dev\.roammand\.PrivilegedBridge' \
  packaging/macos/scripts/preinstall packaging/macos/scripts/postinstall \
  scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -q 'com\.hclgame\.roammand\.PrivilegedBridge' \
  packaging/macos/scripts/preinstall packaging/macos/scripts/postinstall \
  scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -Fq 'launchctl bootstrap "gui/$console_uid" "$AGENT_PLIST"' \
  packaging/macos/scripts/postinstall
rg -Fq 'launchctl kickstart -k "gui/$console_uid/dev.roammand.SessionAgent"' \
  packaging/macos/scripts/postinstall
if rg -qi 'sign out and in|注销并重新登录' \
  packaging/macos/scripts/postinstall scripts/install_m8_macos.sh docs/BUILDING.zh-CN.md; then
  printf 'macOS installation must not require a new login session\n' >&2
  exit 1
fi
if rg -q 'SUDO_UID' packaging/macos/scripts; then
  printf 'installer package scripts must not depend on a sudo shell\n' >&2
  exit 1
fi
plutil -lint packaging/macos/entitlements/*.entitlements >/dev/null
rg -q 'bridge-install-secret\.bin' scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -q 'bridge-owner-id' scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -q '/var/run/roammand' scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -q '/Applications/Roammand\.app' scripts/install_m8_macos.sh scripts/uninstall_m8_macos.sh
rg -q 'Application Support/Roammand' scripts/package_m8_macos.sh scripts/install_m8_macos.sh
rg -q 'uninstall-macos\.sh' scripts/package_m8_macos.sh scripts/install_m8_macos.sh
rg -q 'for service in Accessibility ScreenCapture' scripts/uninstall_m8_macos.sh
rg -q 'tccutil reset' scripts/uninstall_m8_macos.sh
rg -q 'macos-delete-host-identity' scripts/uninstall_m8_macos.sh crates/host-agent/src/main.rs
if rg -q '(private[_ -]?key|seed|signaling|turn[_ -]?password|/Users/|--shell|interactive service)' \
  packaging/macos/*.plist \
  packaging/macos/entitlements \
  packaging/macos/scripts \
  packaging/macos/session-agent \
  scripts/package_m8_macos.sh \
  scripts/install_m8_macos.sh \
  scripts/uninstall_m8_macos.sh; then
  printf 'macOS package contains forbidden privilege or local data\n' >&2
  exit 1
fi

mkdir -p "$TEMP_DIR/Roammand.app/Contents/MacOS"
printf 'app\n' >"$TEMP_DIR/Roammand.app/Contents/MacOS/roammand"
printf '%s\n' \
  '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict>' \
  '<key>CFBundleIdentifier</key><string>dev.roammand.controller</string>' \
  '<key>CFBundleShortVersionString</key><string>1.0.2</string>' \
  '<key>CFBundleVersion</key><string>5</string>' \
  '</dict></plist>' >"$TEMP_DIR/Roammand.app/Contents/Info.plist"
printf 'host\n' >"$TEMP_DIR/roammand-host-agent"
printf '#!/bin/sh\nexit 0\n' >"$TEMP_DIR/roammand-privileged-bridge"
printf '#!/bin/sh\nexit 0\n' >"$TEMP_DIR/roammand-session-agent"
printf 'arm64 libwebrtc license\n' >"$TEMP_DIR/libwebrtc-arm64-LICENSE.md"
printf 'x86_64 libwebrtc license\n' >"$TEMP_DIR/libwebrtc-x86_64-LICENSE.md"
chmod 0755 "$TEMP_DIR"/roammand-*

mkdir "$TEMP_DIR/unmarked-output"
printf 'keep\n' >"$TEMP_DIR/unmarked-output/keep.txt"
if ./scripts/package_m8_macos.sh \
  --output "$TEMP_DIR/unmarked-output" \
  --app-bundle "$TEMP_DIR/Roammand.app" \
  --host-agent "$TEMP_DIR/roammand-host-agent" \
  --bridge "$TEMP_DIR/roammand-privileged-bridge" \
  --session-agent "$TEMP_DIR/roammand-session-agent" \
  --webrtc-arm64-license "$TEMP_DIR/libwebrtc-arm64-LICENSE.md" \
  --webrtc-x64-license "$TEMP_DIR/libwebrtc-x86_64-LICENSE.md" \
  >/dev/null 2>&1; then
  printf 'macOS packager replaced an unmarked non-empty directory\n' >&2
  exit 1
fi
[[ -f "$TEMP_DIR/unmarked-output/keep.txt" ]] || {
  printf 'macOS packager damaged an unsafe output directory\n' >&2
  exit 1
}

if ./scripts/package_m8_macos.sh \
  --output "$TEMP_DIR/package-without-third-party-licenses" \
  --app-bundle "$TEMP_DIR/Roammand.app" \
  --host-agent "$TEMP_DIR/roammand-host-agent" \
  --bridge "$TEMP_DIR/roammand-privileged-bridge" \
  --session-agent "$TEMP_DIR/roammand-session-agent" >/dev/null 2>&1; then
  printf 'macOS packager accepted native WebRTC binaries without their licenses\n' >&2
  exit 1
fi

./scripts/package_m8_macos.sh \
  --output "$TEMP_DIR/package" \
  --app-bundle "$TEMP_DIR/Roammand.app" \
  --host-agent "$TEMP_DIR/roammand-host-agent" \
  --bridge "$TEMP_DIR/roammand-privileged-bridge" \
  --session-agent "$TEMP_DIR/roammand-session-agent" \
  --webrtc-arm64-license "$TEMP_DIR/libwebrtc-arm64-LICENSE.md" \
  --webrtc-x64-license "$TEMP_DIR/libwebrtc-x86_64-LICENSE.md"
if [[ -e "$TEMP_DIR/package/Library/LaunchDaemons" ]]; then
  printf 'macOS package exposes the daemon plist before app registration\n' >&2
  exit 1
fi
# Staging directories produced before the safety marker existed remain
# replaceable when their exact package layout and manifest identify them.
rm "$TEMP_DIR/package/.roammand-package-output"
./scripts/package_m8_macos.sh \
  --output "$TEMP_DIR/package" \
  --app-bundle "$TEMP_DIR/Roammand.app" \
  --host-agent "$TEMP_DIR/roammand-host-agent" \
  --bridge "$TEMP_DIR/roammand-privileged-bridge" \
  --session-agent "$TEMP_DIR/roammand-session-agent" \
  --webrtc-arm64-license "$TEMP_DIR/libwebrtc-arm64-LICENSE.md" \
  --webrtc-x64-license "$TEMP_DIR/libwebrtc-x86_64-LICENSE.md" \
  >/dev/null
# The marker must travel with the staged package. Moving the old output must
# not authorize deletion of unrelated content later created at its old path.
mv "$TEMP_DIR/package" "$TEMP_DIR/package-moved"
mkdir "$TEMP_DIR/package"
printf 'keep\n' >"$TEMP_DIR/package/keep.txt"
if ./scripts/package_m8_macos.sh \
  --output "$TEMP_DIR/package" \
  --app-bundle "$TEMP_DIR/Roammand.app" \
  --host-agent "$TEMP_DIR/roammand-host-agent" \
  --bridge "$TEMP_DIR/roammand-privileged-bridge" \
  --session-agent "$TEMP_DIR/roammand-session-agent" \
  --webrtc-arm64-license "$TEMP_DIR/libwebrtc-arm64-LICENSE.md" \
  --webrtc-x64-license "$TEMP_DIR/libwebrtc-x86_64-LICENSE.md" \
  >/dev/null 2>&1; then
  printf 'stale package marker authorized an unrelated directory\n' >&2
  exit 1
fi
[[ -f "$TEMP_DIR/package/keep.txt" ]] || {
  printf 'macOS packager damaged content after moving an old package\n' >&2
  exit 1
}
rm "$TEMP_DIR/package/keep.txt"
rmdir "$TEMP_DIR/package"
mv "$TEMP_DIR/package-moved" "$TEMP_DIR/package"
cmp "$TEMP_DIR/libwebrtc-arm64-LICENSE.md" \
  "$TEMP_DIR/package/Library/Application Support/Roammand/licenses/libwebrtc-macos-arm64-LICENSE.md"
cmp "$TEMP_DIR/libwebrtc-x86_64-LICENSE.md" \
  "$TEMP_DIR/package/Library/Application Support/Roammand/licenses/libwebrtc-macos-x86_64-LICENSE.md"
readonly BACKGROUND_JOB_PLISTS=(
  "Library/LaunchAgents/dev.roammand.SessionAgent.plist"
  "Library/Application Support/Roammand/launchd/com.hclgame.roammand.PrivilegedBridge.plist"
)
for path in "${BACKGROUND_JOB_PLISTS[@]}"; do
  test "$(plutil -extract AssociatedBundleIdentifiers.0 raw -o - \
    "$TEMP_DIR/package/$path")" = "dev.roammand.controller"
  if plutil -extract AssociatedBundleIdentifiers.1 raw -o - \
    "$TEMP_DIR/package/$path" >/dev/null 2>&1; then
    printf 'macOS background item has multiple app associations\n' >&2
    exit 1
  fi
done
./scripts/check_m8_macos_package.sh "$TEMP_DIR/package"
readonly SESSION_JOB_PLIST="$TEMP_DIR/package/Library/LaunchAgents/dev.roammand.SessionAgent.plist"
cp "$SESSION_JOB_PLIST" "$TEMP_DIR/valid-session-agent.plist"
plutil -remove AssociatedBundleIdentifiers "$SESSION_JOB_PLIST"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'macOS package checker accepted a background item without an app association\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-session-agent.plist" "$SESSION_JOB_PLIST"
plutil -replace AssociatedBundleIdentifiers.0 \
  -string dev.roammand.different "$SESSION_JOB_PLIST"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'macOS package checker accepted a mismatched background item association\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-session-agent.plist" "$SESSION_JOB_PLIST"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
readonly DAEMON_JOB_PLIST="$TEMP_DIR/package/Library/Application Support/Roammand/launchd/com.hclgame.roammand.PrivilegedBridge.plist"
cp "$DAEMON_JOB_PLIST" "$TEMP_DIR/valid-daemon.plist"
plutil -replace Label -string dev.roammand.PrivilegedBridge "$DAEMON_JOB_PLIST"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'macOS package checker accepted the cached legacy daemon label\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-daemon.plist" "$DAEMON_JOB_PLIST"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted missing compliance assets\n' >&2
  exit 1
fi
readonly COMPLIANCE_DIR="$TEMP_DIR/package/Library/Application Support/Roammand/licenses"
cat >"$COMPLIANCE_DIR/SBOM.spdx.json" <<'JSON'
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "Roammand macOS 1.0.2 build 5",
  "documentNamespace": "https://spdx.org/spdxdocs/roammand-fixture",
  "creationInfo": {
    "created": "2024-01-01T00:00:00Z",
    "creators": ["Tool: Roammand fixture"]
  },
  "packages": [
    {
      "SPDXID": "SPDXRef-Package-Roammand",
      "name": "Roammand",
      "versionInfo": "1.0.2",
      "supplier": "Person: ChengLong Hu",
      "originator": "Person: ChengLong Hu",
      "filesAnalyzed": true,
      "packageVerificationCode": {
        "packageVerificationCodeValue": "1111111111111111111111111111111111111111"
      },
      "licenseDeclared": "MPL-2.0",
      "licenseConcluded": "NOASSERTION",
      "copyrightText": "Copyright © ChengLong Hu",
      "sourceInfo": "https://github.com/MisakiHCL/roammand/tree/v1.0.2 at commit 1111111111111111111111111111111111111111; bundle dev.roammand.controller, build 5; validated source inputs; the SHA-256 value identifies the staged payload inventory, not a serialized .pkg file: 4444444444444444444444444444444444444444444444444444444444444444."
    }
  ],
  "files": [
    {
      "SPDXID": "SPDXRef-File-fixture",
      "checksums": [
        {
          "algorithm": "SHA1",
          "checksumValue": "2222222222222222222222222222222222222222"
        },
        {
          "algorithm": "SHA256",
          "checksumValue": "3333333333333333333333333333333333333333333333333333333333333333"
        }
      ]
    }
  ],
  "relationships": [
    {
      "spdxElementId": "SPDXRef-DOCUMENT",
      "relationshipType": "DESCRIBES",
      "relatedSpdxElement": "SPDXRef-Package-Roammand"
    },
    {
      "spdxElementId": "SPDXRef-Package-Roammand",
      "relationshipType": "CONTAINS",
      "relatedSpdxElement": "SPDXRef-File-fixture"
    }
  ]
}
JSON
printf '%s\n' \
  '# Roammand macOS Third-Party Notices' \
  '' \
  '- Product: Roammand 1.0.2 (build 5)' \
  '- Bundle identifier: `dev.roammand.controller`' \
  '- Source: https://github.com/MisakiHCL/roammand/tree/v1.0.2' \
  '- Source revision: `1111111111111111111111111111111111111111`' \
  '- Payload inventory SHA-256: `4444444444444444444444444444444444444444444444444444444444444444`' \
  '- Generated: 2024-01-01T00:00:00Z' \
  '- Project copyright holder: ChengLong Hu' \
  >"$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md"
printf '%s\n' \
  '# Roammand macOS Source Code Record' \
  '' \
  '- Product: Roammand 1.0.2 (build 5)' \
  '- Bundle identifier: `dev.roammand.controller`' \
  '- Copyright holder: ChengLong Hu' \
  '- Exact project source: https://github.com/MisakiHCL/roammand/tree/v1.0.2' \
  '- Exact Git commit: `1111111111111111111111111111111111111111`' \
  '- Payload inventory SHA-256: `4444444444444444444444444444444444444444444444444444444444444444`' \
  '- Generated: 2024-01-01T00:00:00Z' \
  >"$COMPLIANCE_DIR/SOURCE_CODE.md"
python3 - \
  "$COMPLIANCE_DIR/SBOM.spdx.json" \
  "$TEMP_DIR/package" \
  "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md" \
  "$COMPLIANCE_DIR/SOURCE_CODE.md" <<'PY'
import hashlib
import json
import pathlib
import sys

sbom_path = pathlib.Path(sys.argv[1])
package_root = pathlib.Path(sys.argv[2])
human_paths = tuple(pathlib.Path(value) for value in sys.argv[3:])
excluded = {
    ".roammand-package-output",
    "Library/Application Support/Roammand/install-manifest.sha256",
    "Library/Application Support/Roammand/licenses/SBOM.spdx.json",
    "Library/Application Support/Roammand/licenses/THIRD_PARTY_NOTICES.md",
    "Library/Application Support/Roammand/licenses/SOURCE_CODE.md",
}
document = json.loads(sbom_path.read_text(encoding="utf-8"))
files = []
relationships = [document["relationships"][0]]
sha1_values = []
inventory_lines = []
for path in sorted(package_root.rglob("*"), key=lambda item: item.as_posix()):
    if path.is_symlink() or not path.is_file():
        continue
    relative = path.relative_to(package_root).as_posix()
    if relative in excluded:
        continue
    content = path.read_bytes()
    sha1 = hashlib.sha1(content, usedforsecurity=False).hexdigest()
    sha256 = hashlib.sha256(content).hexdigest()
    file_id = f"SPDXRef-File-{hashlib.sha256(relative.encode()).hexdigest()[:20]}"
    files.append(
        {
            "SPDXID": file_id,
            "fileName": f"./{relative}",
            "checksums": [
                {"algorithm": "SHA1", "checksumValue": sha1},
                {"algorithm": "SHA256", "checksumValue": sha256},
            ],
            "licenseConcluded": "NOASSERTION",
            "copyrightText": "NOASSERTION",
        }
    )
    relationships.append(
        {
            "spdxElementId": "SPDXRef-Package-Roammand",
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": file_id,
        }
    )
    sha1_values.append(sha1)
    inventory_lines.append(f"{sha256}  {relative}")
verification = hashlib.sha1(
    "".join(sorted(sha1_values)).encode("ascii"), usedforsecurity=False
).hexdigest()
inventory = hashlib.sha256(
    ("\n".join(inventory_lines) + "\n").encode("utf-8")
).hexdigest()
root = document["packages"][0]
root["packageVerificationCode"] = {
    "packageVerificationCodeValue": verification,
    "packageVerificationCodeExcludedFiles": [
        f"./{value}" for value in sorted(excluded)
    ],
}
root["sourceInfo"] = root["sourceInfo"].replace("4" * 64, inventory)
document["files"] = files
document["relationships"] = relationships
sbom_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
for human_path in human_paths:
    human_path.write_text(
        human_path.read_text(encoding="utf-8").replace("4" * 64, inventory),
        encoding="utf-8",
    )
PY
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package"
cp "$COMPLIANCE_DIR/SBOM.spdx.json" "$TEMP_DIR/valid-sbom.json"
cp "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md" "$TEMP_DIR/valid-notices.md"
cp "$COMPLIANCE_DIR/SOURCE_CODE.md" "$TEMP_DIR/valid-source.md"
readonly PROJECT_LICENSE="$TEMP_DIR/package/Library/Application Support/Roammand/licenses/MPL-2.0.txt"
cp "$PROJECT_LICENSE" "$TEMP_DIR/valid-project-license.txt"
printf 'tampered project license\n' >"$PROJECT_LICENSE"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted a payload/SBOM hash mismatch\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-project-license.txt" "$PROJECT_LICENSE"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
python3 - \
  "$COMPLIANCE_DIR/SBOM.spdx.json" \
  "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md" \
  "$COMPLIANCE_DIR/SOURCE_CODE.md" <<'PY'
import json
import pathlib
import sys

sbom_path = pathlib.Path(sys.argv[1])
document = json.loads(sbom_path.read_text(encoding="utf-8"))
document["name"] = "Roammand macOS 9.9.9 build 99"
document["packages"][0]["versionInfo"] = "9.9.9"
document["packages"][0]["sourceInfo"] = document["packages"][0][
    "sourceInfo"
].replace("build 5;", "build 99;")
sbom_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
for raw_path in sys.argv[2:]:
    path = pathlib.Path(raw_path)
    path.write_text(
        path.read_text(encoding="utf-8")
        .replace("Roammand 1.0.2 (build 5)", "Roammand 9.9.9 (build 99)"),
        encoding="utf-8",
    )
PY
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted an SBOM/app version mismatch\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-sbom.json" "$COMPLIANCE_DIR/SBOM.spdx.json"
cp "$TEMP_DIR/valid-notices.md" "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md"
cp "$TEMP_DIR/valid-source.md" "$COMPLIANCE_DIR/SOURCE_CODE.md"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
sed 's/(build 5)/(build 6)/' \
  "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md" >"$TEMP_DIR/invalid-notices.md"
mv "$TEMP_DIR/invalid-notices.md" "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted mismatched compliance records\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-notices.md" "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md"
python3 - "$COMPLIANCE_DIR/SBOM.spdx.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text(encoding="utf-8"))
document["files"][0]["checksums"] = [
    checksum
    for checksum in document["files"][0]["checksums"]
    if checksum["algorithm"] != "SHA1"
]
path.write_text(json.dumps(document), encoding="utf-8")
PY
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted an SBOM without file SHA-1\n' >&2
  exit 1
fi
cp "$TEMP_DIR/valid-sbom.json" "$COMPLIANCE_DIR/SBOM.spdx.json"
sed 's/"filesAnalyzed": true/"filesAnalyzed": false/' \
  "$COMPLIANCE_DIR/SBOM.spdx.json" >"$TEMP_DIR/invalid-root-sbom.json"
mv "$TEMP_DIR/invalid-root-sbom.json" "$COMPLIANCE_DIR/SBOM.spdx.json"
./scripts/write_macos_package_manifest.sh "$TEMP_DIR/package" >/dev/null
if ./scripts/check_m8_macos_package.sh \
  --require-compliance "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'strict macOS package check accepted filesAnalyzed=false\n' >&2
  exit 1
fi
ln -s /etc/passwd "$TEMP_DIR/package/unsafe-link"
if ./scripts/check_m8_macos_package.sh "$TEMP_DIR/package" >/dev/null 2>&1; then
  printf 'macOS package checker accepted an escaping symbolic link\n' >&2
  exit 1
fi
rm "$TEMP_DIR/package/unsafe-link"
./scripts/install_macos.sh --dry-run \
  --package "$TEMP_DIR/package" | rg -q 'no changes made'
./scripts/uninstall_macos.sh --dry-run | \
  rg -q 'system permissions, device identity, pairings, preferences, caches'

printf 'M8 macOS package contract ok\n'
