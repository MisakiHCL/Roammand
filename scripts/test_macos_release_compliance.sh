#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GENERATOR="$ROOT_DIR/scripts/generate_macos_release_compliance.py"
readonly TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

readonly PACKAGE_DIR="$TEMP_DIR/package"
readonly INPUT_DIR="$TEMP_DIR/inputs"
readonly APP_CONTENTS="$PACKAGE_DIR/Applications/Roammand.app/Contents"
readonly FLUTTER_ASSETS="$APP_CONTENTS/Frameworks/App.framework/Versions/A/Resources/flutter_assets"
readonly PACKAGE_LICENSES="$PACKAGE_DIR/Library/Application Support/Roammand/licenses"
readonly CARGO_PACKAGE_DIR="$INPUT_DIR/cargo/sample-rust-1.2.3"
readonly CARGO_BUILD_PACKAGE_DIR="$INPUT_DIR/cargo/sample-build-4.5.6"
readonly CARGO_DEV_PACKAGE_DIR="$INPUT_DIR/cargo/sample-dev-6.7.8"
readonly UNKNOWN_CARGO_PACKAGE_DIR="$INPUT_DIR/cargo/unknown-rust-license-9.9.9"
readonly DART_PACKAGE_DIR="$INPUT_DIR/dart/sample_dart-2.3.4"
readonly DART_WEBRTC_PACKAGE_DIR="$ROOT_DIR/third_party/flutter_webrtc"
readonly UNLICENSED_DART_PACKAGE_DIR="$INPUT_DIR/dart/unlicensed_dart-9.9.9"
readonly SOURCE_REVISION="0123456789abcdef0123456789abcdef01234567"
readonly SOURCE_URL="https://example.test/roammand"
readonly COPYRIGHT_HOLDER="ChengLong Hu"
readonly FIXED_SOURCE_DATE_EPOCH="1704067200"
readonly FLUTTER_ENGINE_REVISION="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
readonly FLUTTER_WEBRTC_UPSTREAM_ARCHIVE_SHA256="0f89dee7f4c35dab5611f351c3897a3bfe9f7057720cc7da209b52455af4316e"
readonly FLUTTER_LICENSE_SHA256="a598db94b6290ffbe10b5ecf911057b6a943351c727fdda9e5f2891d68700a20"
readonly WEBRTC_LICENSE_SHA256="ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482"
readonly WEBRTC_PATENTS_SHA256="01462e2068d1a04c2274f3389773014c14ed9bc3446b28303543bd3e3c064145"

fail() {
  printf 'macOS release compliance test failed: %s\n' "$1" >&2
  exit 1
}

require_text() {
  local path="$1"
  local expected="$2"
  rg --quiet --fixed-strings -- "$expected" "$path" || {
    fail "missing expected text in $(basename "$path"): $expected"
  }
}

require_output_set() {
  local output_dir="$1"
  local name
  for name in SBOM.spdx.json THIRD_PARTY_NOTICES.md SOURCE_CODE.md; do
    [[ -f "$output_dir/$name" && -s "$output_dir/$name" &&
      ! -L "$output_dir/$name" ]] || {
      fail "missing or unsafe compliance output: $name"
    }
  done
}

write_package_fixture() {
  mkdir -p \
    "$APP_CONTENTS/MacOS" \
    "$APP_CONTENTS/Frameworks/App.framework/Versions/A" \
    "$APP_CONTENTS/Frameworks/FlutterMacOS.framework/Versions/A/Resources" \
    "$APP_CONTENTS/Frameworks/WebRTC.framework" \
    "$APP_CONTENTS/Frameworks/flutter_webrtc.framework" \
    "$APP_CONTENTS/Frameworks/objective_c.framework" \
    "$FLUTTER_ASSETS/assets/brand" \
    "$PACKAGE_DIR/Library/PrivilegedHelperTools" \
    "$PACKAGE_LICENSES"

  cat >"$APP_CONTENTS/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.roammand.compliance-fixture</string>
  <key>CFBundleName</key>
  <string>Roammand</string>
  <key>CFBundleShortVersionString</key>
  <string>7.8.9</string>
  <key>CFBundleVersion</key>
  <string>42</string>
</dict>
</plist>
EOF

  cat >"$APP_CONTENTS/Frameworks/FlutterMacOS.framework/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>FlutterEngine</key>
  <string>$FLUTTER_ENGINE_REVISION</string>
</dict>
</plist>
EOF

  printf 'fixture macOS executable\n' >"$APP_CONTENTS/MacOS/roammand"
  printf 'fixture Dart AOT framework\n' \
    >"$APP_CONTENTS/Frameworks/App.framework/Versions/A/App"
  printf 'fixture Flutter engine\n' \
    >"$APP_CONTENTS/Frameworks/FlutterMacOS.framework/FlutterMacOS"
  printf 'fixture CocoaPods WebRTC runtime\n' \
    >"$APP_CONTENTS/Frameworks/WebRTC.framework/WebRTC"
  printf 'fixture flutter_webrtc plugin\n' \
    >"$APP_CONTENTS/Frameworks/flutter_webrtc.framework/flutter_webrtc"
  printf 'fixture objective_c native asset\n' \
    >"$APP_CONTENTS/Frameworks/objective_c.framework/objective_c"
  printf 'fixture Rust Host Agent\n' \
    >"$PACKAGE_DIR/Library/PrivilegedHelperTools/roammand-host-agent"
  printf 'fixture Rust privileged bridge\n' \
    >"$PACKAGE_DIR/Library/PrivilegedHelperTools/roammand-privileged-bridge"

  cat >"$TEMP_DIR/flutter-notices.txt" <<'EOF'
flutter_fixture

Flutter fixture engine notice.
--------------------------------------------------------------------------------
sample_dart

Sample Dart fixture notice embedded by Flutter.
EOF
  gzip -n -c "$TEMP_DIR/flutter-notices.txt" >"$FLUTTER_ASSETS/NOTICES.Z"

  printf 'abandon\nability\nable\nabout\n' \
    >"$FLUTTER_ASSETS/assets/bip39-english.txt"
  printf 'fixture original Roammand brand asset\n' \
    >"$FLUTTER_ASSETS/assets/brand/app-icon.txt"
  printf 'Fixture MPL-2.0 project license text.\n' \
    >"$PACKAGE_LICENSES/MPL-2.0.txt"
  printf 'Fixture Apache-2.0 project license text.\n' \
    >"$PACKAGE_LICENSES/Apache-2.0.txt"
  printf 'Native WebRTC arm64 fixture notice.\n' \
    >"$PACKAGE_LICENSES/libwebrtc-macos-arm64-LICENSE.md"
  printf 'Native WebRTC x86_64 fixture notice.\n' \
    >"$PACKAGE_LICENSES/libwebrtc-macos-x86_64-LICENSE.md"
}

write_dependency_fixtures() {
  mkdir -p "$CARGO_PACKAGE_DIR" "$CARGO_BUILD_PACKAGE_DIR" \
    "$CARGO_DEV_PACKAGE_DIR" "$UNKNOWN_CARGO_PACKAGE_DIR" \
    "$DART_PACKAGE_DIR/lib" \
    "$UNLICENSED_DART_PACKAGE_DIR/lib"

  for required_notice in \
    LICENSE \
    NOTICE \
    DOWNSTREAM_PATCH.md \
    third_party/svpng/LICENSE \
    third_party_licenses/LICENSE-FLUTTER \
    third_party_licenses/LICENSE-WEBRTC \
    third_party_licenses/NOTICE-WEBRTC-PATENTS \
    third_party_licenses/README.md; do
    [[ -f "$DART_WEBRTC_PACKAGE_DIR/$required_notice" ]] || {
      fail "missing repository flutter_webrtc notice input: $required_notice"
    }
  done

  printf 'Sample Rust fixture MIT license text.\n' \
    >"$CARGO_PACKAGE_DIR/LICENSE"
  printf 'Sample build-only Rust fixture MIT license text.\n' \
    >"$CARGO_BUILD_PACKAGE_DIR/LICENSE"
  printf 'Sample dev-only Rust fixture MIT license text.\n' \
    >"$CARGO_DEV_PACKAGE_DIR/LICENSE"
  printf 'SPDX-License-Identifier: BSD-3-Clause\nSample Dart fixture BSD-3-Clause license text.\n' \
    >"$DART_PACKAGE_DIR/LICENSE"
  printf 'Sample Dart fixture additional attribution.\n' \
    >"$DART_PACKAGE_DIR/NOTICE"
  cat >"$CARGO_PACKAGE_DIR/Cargo.toml" <<'EOF'
[package]
name = "sample-rust"
version = "1.2.3"
license = "MIT"
repository = "https://example.test/sample-rust"
EOF
  cat >"$UNKNOWN_CARGO_PACKAGE_DIR/Cargo.toml" <<'EOF'
[package]
name = "unknown-rust-license"
version = "9.9.9"
repository = "https://example.test/unknown-rust-license"
EOF
  cat >"$CARGO_BUILD_PACKAGE_DIR/Cargo.toml" <<'EOF'
[package]
name = "sample-build"
version = "4.5.6"
license = "MIT"
repository = "https://example.test/sample-build"
EOF
  cat >"$CARGO_DEV_PACKAGE_DIR/Cargo.toml" <<'EOF'
[package]
name = "sample-dev"
version = "6.7.8"
license = "MIT"
repository = "https://example.test/sample-dev"
EOF
  cat >"$DART_PACKAGE_DIR/pubspec.yaml" <<'EOF'
name: sample_dart
version: 2.3.4
homepage: https://example.test/sample-dart
repository: https://example.test/sample-dart/source
EOF
  cat >"$UNLICENSED_DART_PACKAGE_DIR/pubspec.yaml" <<'EOF'
name: unlicensed_dart
version: 9.9.9
homepage: https://example.test/unlicensed-dart
repository: https://example.test/unlicensed-dart/source
EOF
  cat >"$INPUT_DIR/cargo-metadata.json" <<EOF
{
  "packages": [
    {
      "name": "roammand-host-agent",
      "version": "0.1.0",
      "id": "path+file://$ROOT_DIR/crates/roammand-host-agent#0.1.0",
      "license": "Apache-2.0",
      "license_file": null,
      "source": null,
      "manifest_path": "$ROOT_DIR/crates/roammand-host-agent/Cargo.toml",
      "dependencies": [],
      "targets": [],
      "features": {}
    },
    {
      "name": "sample-rust",
      "version": "1.2.3",
      "id": "registry+https://github.com/rust-lang/crates.io-index#sample-rust@1.2.3",
      "license": "MIT",
      "license_file": "$CARGO_PACKAGE_DIR/LICENSE",
      "source": "registry+https://github.com/rust-lang/crates.io-index",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "repository": "https://example.test/sample-rust",
      "homepage": "https://example.test/sample-rust",
      "description": "Release compliance fixture",
      "authors": ["Fixture Author"],
      "manifest_path": "$CARGO_PACKAGE_DIR/Cargo.toml",
      "dependencies": [],
      "targets": [],
      "features": {},
      "edition": "2021",
      "metadata": {},
      "publish": null,
      "rust_version": null,
      "categories": [],
      "keywords": [],
      "readme": null,
      "documentation": null,
      "links": null,
      "default_run": null
    },
    {
      "name": "sample-build",
      "version": "4.5.6",
      "id": "registry+https://github.com/rust-lang/crates.io-index#sample-build@4.5.6",
      "license": "MIT",
      "license_file": "$CARGO_BUILD_PACKAGE_DIR/LICENSE",
      "source": "registry+https://github.com/rust-lang/crates.io-index",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "repository": "https://example.test/sample-build",
      "manifest_path": "$CARGO_BUILD_PACKAGE_DIR/Cargo.toml",
      "dependencies": [],
      "targets": [],
      "features": {}
    },
    {
      "name": "sample-dev",
      "version": "6.7.8",
      "id": "registry+https://github.com/rust-lang/crates.io-index#sample-dev@6.7.8",
      "license": "MIT",
      "license_file": "$CARGO_DEV_PACKAGE_DIR/LICENSE",
      "source": "registry+https://github.com/rust-lang/crates.io-index",
      "checksum": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "repository": "https://example.test/sample-dev",
      "manifest_path": "$CARGO_DEV_PACKAGE_DIR/Cargo.toml",
      "dependencies": [],
      "targets": [],
      "features": {}
    }
  ],
  "workspace_members": ["path+file://$ROOT_DIR/crates/roammand-host-agent#0.1.0"],
  "workspace_default_members": ["path+file://$ROOT_DIR/crates/roammand-host-agent#0.1.0"],
  "resolve": {
    "nodes": [
      {
        "id": "path+file://$ROOT_DIR/crates/roammand-host-agent#0.1.0",
        "dependencies": [
          "registry+https://github.com/rust-lang/crates.io-index#sample-rust@1.2.3",
          "registry+https://github.com/rust-lang/crates.io-index#sample-build@4.5.6",
          "registry+https://github.com/rust-lang/crates.io-index#sample-dev@6.7.8"
        ],
        "deps": [
          {
            "name": "sample_rust",
            "pkg": "registry+https://github.com/rust-lang/crates.io-index#sample-rust@1.2.3",
            "dep_kinds": [{"kind": null, "target": null}]
          },
          {
            "name": "sample_build",
            "pkg": "registry+https://github.com/rust-lang/crates.io-index#sample-build@4.5.6",
            "dep_kinds": [{"kind": "build", "target": null}]
          },
          {
            "name": "sample_dev",
            "pkg": "registry+https://github.com/rust-lang/crates.io-index#sample-dev@6.7.8",
            "dep_kinds": [{"kind": "dev", "target": null}]
          }
        ],
        "features": []
      },
      {
        "id": "registry+https://github.com/rust-lang/crates.io-index#sample-rust@1.2.3",
        "dependencies": [],
        "deps": [],
        "features": []
      },
      {
        "id": "registry+https://github.com/rust-lang/crates.io-index#sample-build@4.5.6",
        "dependencies": [],
        "deps": [],
        "features": []
      },
      {
        "id": "registry+https://github.com/rust-lang/crates.io-index#sample-dev@6.7.8",
        "dependencies": [],
        "deps": [],
        "features": []
      }
    ],
    "root": "path+file://$ROOT_DIR/crates/roammand-host-agent#0.1.0"
  },
  "target_directory": "$TEMP_DIR/target",
  "version": 1,
  "workspace_root": "$ROOT_DIR",
  "metadata": null
}
EOF

  cat >"$INPUT_DIR/Cargo.lock" <<'EOF'
version = 4

[[package]]
name = "sample-rust"
version = "1.2.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

[[package]]
name = "sample-build"
version = "4.5.6"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

[[package]]
name = "sample-dev"
version = "6.7.8"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
EOF
  printf 'version = 4\n' >"$INPUT_DIR/Cargo-empty.lock"

  cat >"$INPUT_DIR/cargo-metadata-unknown.json" <<EOF
{
  "packages": [
    {
      "name": "unknown-rust-license",
      "version": "9.9.9",
      "id": "registry+https://github.com/rust-lang/crates.io-index#unknown-rust-license@9.9.9",
      "license": null,
      "license_file": null,
      "source": "registry+https://github.com/rust-lang/crates.io-index",
      "checksum": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "repository": "https://example.test/unknown-rust-license",
      "manifest_path": "$UNKNOWN_CARGO_PACKAGE_DIR/Cargo.toml",
      "dependencies": [],
      "targets": [],
      "features": {}
    }
  ],
  "workspace_members": [],
  "workspace_default_members": [],
  "resolve": {
    "nodes": [
      {
        "id": "registry+https://github.com/rust-lang/crates.io-index#unknown-rust-license@9.9.9",
        "dependencies": [],
        "deps": [],
        "features": []
      }
    ],
    "root": null
  },
  "target_directory": "$TEMP_DIR/target-unknown",
  "version": 1,
  "workspace_root": "$ROOT_DIR",
  "metadata": null
}
EOF

  cat >"$INPUT_DIR/pubspec.lock" <<EOF
# Generated fixture.
packages:
  flutter_webrtc:
    dependency: "direct main"
    description:
      path: "../../../third_party/flutter_webrtc"
      relative: true
      sha256: "$FLUTTER_WEBRTC_UPSTREAM_ARCHIVE_SHA256"
    source: path
    version: "1.5.2"
  sample_dart:
    dependency: "direct main"
    description:
      name: sample_dart
      sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      url: "https://pub.dev"
    source: hosted
    version: "2.3.4"
sdks:
  dart: ">=3.0.0 <4.0.0"
EOF

  cat >"$INPUT_DIR/pubspec-unlicensed.lock" <<'EOF'
# Generated fixture.
packages:
  unlicensed_dart:
    dependency: "direct main"
    description:
      name: unlicensed_dart
      sha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      url: "https://pub.dev"
    source: hosted
    version: "9.9.9"
sdks:
  dart: ">=3.0.0 <4.0.0"
EOF

  cat >"$INPUT_DIR/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {
      "name": "flutter_webrtc",
      "rootUri": "file://$DART_WEBRTC_PACKAGE_DIR/",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    },
    {
      "name": "sample_dart",
      "rootUri": "file://$DART_PACKAGE_DIR/",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ],
  "generator": "roammand-compliance-fixture"
}
EOF

  cat >"$INPUT_DIR/package_config_unlicensed.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {
      "name": "unlicensed_dart",
      "rootUri": "file://$UNLICENSED_DART_PACKAGE_DIR/",
      "packageUri": "lib/",
      "languageVersion": "3.0"
    }
  ],
  "generator": "roammand-compliance-fixture"
}
EOF

  cat >"$INPUT_DIR/Podfile.lock" <<'EOF'
PODS:
  - flutter_webrtc (1.5.2-roammand.1):
    - FlutterMacOS
    - WebRTC-SDK (= 144.7559.09)
  - FlutterMacOS (1.0.0)
  - WebRTC-SDK (144.7559.09)

DEPENDENCIES:
  - flutter_webrtc

SPEC CHECKSUMS:
  flutter_webrtc: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  WebRTC-SDK: ffffffffffffffffffffffffffffffffffffffff

COCOAPODS: 1.16.2
EOF

  cat >"$INPUT_DIR/Pods-Runner-acknowledgements.markdown" <<'EOF'
# Acknowledgements

## WebRTC-SDK

WebRTC-SDK fixture BSD-3-Clause notice.

## FlutterMacOS

FlutterMacOS fixture BSD-3-Clause notice.

## flutter_webrtc

flutter_webrtc fixture MIT notice.
EOF

  cat >"$INPUT_DIR/bip39-NOTICE.md" <<'EOF'
# BIP-39 English word list

BIP-39 fixture MIT notice.

Upstream: https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt
EOF

  cat >"$INPUT_DIR/libwebrtc-assets.sha256" <<'EOF'
# Upstream tag, release asset, SHA-256
webrtc-fixture-1 webrtc-mac-arm64-release.zip 1111111111111111111111111111111111111111111111111111111111111111
webrtc-fixture-1 webrtc-mac-x64-release.zip 2222222222222222222222222222222222222222222222222222222222222222
EOF
}

generate_compliance() {
  local output_dir="$1"
  local cargo_metadata="$2"
  local pub_lock="$3"
  local package_config="$4"
  local pod_acknowledgements="$5"
  local bip39_notice="$6"
  local native_webrtc_manifest="$7"

  SOURCE_DATE_EPOCH="$FIXED_SOURCE_DATE_EPOCH" LC_ALL=C TZ=UTC \
    python3 "$GENERATOR" \
      --package-dir "$PACKAGE_DIR" \
      --output-dir "$output_dir" \
      --source-revision "$SOURCE_REVISION" \
      --source-url "$SOURCE_URL" \
      --copyright-holder "$COPYRIGHT_HOLDER" \
      --cargo-metadata "$cargo_metadata" \
      --cargo-lock "$INPUT_DIR/Cargo.lock" \
      --pub-lock "$pub_lock" \
      --dart-package-config "$package_config" \
      --pod-lock "$INPUT_DIR/Podfile.lock" \
      --pod-acknowledgements "$pod_acknowledgements" \
      --bip39-notice "$bip39_notice" \
      --native-webrtc-manifest "$native_webrtc_manifest" \
      --flutter-version "3.44.0" \
      --flutter-engine-revision "$FLUTTER_ENGINE_REVISION"
}

assert_spdx_contract() {
  local sbom="$1"
  python3 - \
    "$sbom" \
    "$SOURCE_REVISION" \
    "$SOURCE_URL" \
    "$FLUTTER_WEBRTC_UPSTREAM_ARCHIVE_SHA256" <<'PY'
import json
import hashlib
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
revision = sys.argv[2]
source_url = sys.argv[3]
upstream_archive_sha256 = sys.argv[4]
with path.open(encoding="utf-8") as source:
    document = json.load(source)

assert document["spdxVersion"] == "SPDX-2.3"
assert document["dataLicense"] == "CC0-1.0"
assert document["SPDXID"] == "SPDXRef-DOCUMENT"
assert document["creationInfo"]["created"] == "2024-01-01T00:00:00Z"
assert "licenseListVersion" not in document["creationInfo"]
assert document["documentNamespace"].startswith("https://")
assert revision in json.dumps(document, sort_keys=True)

packages = {package["name"]: package for package in document["packages"]}
for required in (
    "Roammand",
    "sample-rust",
    "sample-build",
    "sample_dart",
    "WebRTC-SDK",
    "Roammand visual brand assets",
):
    assert required in packages, f"missing SPDX package: {required}"
assert "sample-dev" not in packages

assert packages["sample-rust"]["versionInfo"] == "1.2.3"
assert packages["sample-rust"]["licenseDeclared"] == "MIT"
assert packages["sample-rust"]["copyrightText"] == "NOASSERTION"
assert packages["sample-rust"]["checksums"] == [
    {"algorithm": "SHA256", "checksumValue": "a" * 64}
]
assert packages["sample_dart"]["versionInfo"] == "2.3.4"
assert packages["sample_dart"]["licenseDeclared"] == "BSD-3-Clause"
assert packages["WebRTC-SDK"]["versionInfo"] == "144.7559.09"
assert packages["WebRTC-SDK"]["checksums"] == [
    {"algorithm": "SHA1", "checksumValue": "f" * 40}
]
path_webrtc_source = (
    f"{source_url}/tree/{revision}/third_party/flutter_webrtc"
)
path_webrtc = next(
    package
    for package in document["packages"]
    if package["name"] == "flutter_webrtc"
    and package["sourceInfo"] == path_webrtc_source
)
assert path_webrtc["versionInfo"] == "1.5.2"
assert path_webrtc["licenseDeclared"] == (
    "MIT AND Apache-2.0 AND BSD-3-Clause"
)
assert path_webrtc["downloadLocation"] == "NOASSERTION"
assert "Repository-local modified Dart path dependency" in path_webrtc["summary"]
assert "checksums" not in path_webrtc
assert "externalRefs" not in path_webrtc
assert upstream_archive_sha256 not in json.dumps(path_webrtc, sort_keys=True)
assert packages["BIP-39 English word list"]["sourceInfo"].endswith(
    "ce1862ac6bcffa1dd20aad858380e51e66e949ea/bip-0039/english.txt"
)
brand = packages["Roammand visual brand assets"]
assert brand["sourceInfo"] == "https://example.test/roammand/brand"
assert "checksums" not in brand
assert "inventory digest is not an individual file checksum" in brand["summary"]

root_package = packages["Roammand"]
assert root_package["filesAnalyzed"] is True
assert root_package["licenseConcluded"] == "NOASSERTION"
assert root_package["licenseDeclared"].startswith("MPL-2.0 AND Apache-2.0 AND ")
assert "LicenseRef-Roammand-Brand-Assets-" in root_package["licenseDeclared"]
assert "packageFileName" not in root_package
assert "checksums" not in root_package
verification = root_package["packageVerificationCode"]
assert re.fullmatch(
    r"[0-9a-f]{40}", verification["packageVerificationCodeValue"]
)
excluded = set(verification["packageVerificationCodeExcludedFiles"])
for required_exclusion in (
    "./.roammand-package-output",
    "./Library/Application Support/Roammand/install-manifest.sha256",
    "./Library/Application Support/Roammand/licenses/SBOM.spdx.json",
    "./Library/Application Support/Roammand/licenses/SOURCE_CODE.md",
    "./Library/Application Support/Roammand/licenses/THIRD_PARTY_NOTICES.md",
):
    assert required_exclusion in excluded

external_refs = [
    ref["referenceLocator"]
    for package in document["packages"]
    for ref in package.get("externalRefs", [])
]
assert "pkg:cargo/sample-rust@1.2.3" in external_refs
assert "pkg:pub/sample_dart@2.3.4" in external_refs
assert "pkg:pub/flutter_webrtc@1.5.2" not in external_refs

files = document.get("files", [])
assert files, "SPDX document has no shipped-file inventory"
file_sha1_values = []
for file_entry in files:
    checksums = file_entry.get("checksums", [])
    sha1_values = [
        checksum.get("checksumValue", "")
        for checksum in checksums
        if checksum.get("algorithm") == "SHA1"
    ]
    assert len(sha1_values) == 1 and re.fullmatch(
        r"[0-9a-f]{40}", sha1_values[0]
    ), f"missing SHA-1 for {file_entry.get('fileName')}"
    file_sha1_values.extend(sha1_values)
    assert any(
        checksum.get("algorithm") == "SHA256"
        and len(checksum.get("checksumValue", "")) == 64
        for checksum in checksums
    ), f"missing SHA-256 for {file_entry.get('fileName')}"
expected_verification = hashlib.sha1(
    "".join(sorted(file_sha1_values)).encode("ascii"),
    usedforsecurity=False,
).hexdigest()
assert verification["packageVerificationCodeValue"] == expected_verification

extracted_ids = {
    item["licenseId"] for item in document.get("hasExtractedLicensingInfos", [])
}
for package in document["packages"]:
    declared = package["licenseDeclared"]
    for license_ref in re.findall(r"LicenseRef-[A-Za-z0-9._-]+", declared):
        assert re.fullmatch(r"LicenseRef-[A-Za-z0-9.-]+", license_ref)
        assert license_ref in extracted_ids
native_x86_refs = [
    package["licenseDeclared"]
    for package in document["packages"]
    if package["name"] == "LiveKit WebRTC binary (x86_64)"
]
assert len(native_x86_refs) == 1
assert "x86-64" in native_x86_refs[0] and "_" not in native_x86_refs[0]

relationships = document.get("relationships", [])
assert relationships, "SPDX document has no relationships"
assert any(
    relationship["spdxElementId"] == "SPDXRef-DOCUMENT"
    and relationship["relationshipType"] == "DESCRIBES"
    for relationship in relationships
)
runtime_id = packages["sample-rust"]["SPDXID"]
build_id = packages["sample-build"]["SPDXID"]
assert any(
    relationship["spdxElementId"] == "SPDXRef-Package-Roammand"
    and relationship["relationshipType"] == "DEPENDS_ON"
    and relationship["relatedSpdxElement"] == runtime_id
    for relationship in relationships
)
assert any(
    relationship["spdxElementId"] == build_id
    and relationship["relationshipType"] == "BUILD_DEPENDENCY_OF"
    and relationship["relatedSpdxElement"] == "SPDXRef-Package-Roammand"
    for relationship in relationships
)
assert all(
    annotation["annotationType"] == "OTHER"
    and annotation["annotator"].startswith("Tool:")
    for annotation in document["annotations"]
)
PY
}

assert_failure_is_atomic() {
  local case_name="$1"
  local expected_error="$2"
  local cargo_metadata="$3"
  local pub_lock="$4"
  local package_config="$5"
  local pod_acknowledgements="$6"
  local bip39_notice="$7"
  local native_webrtc_manifest="$8"
  local output_dir="$TEMP_DIR/failure-$case_name"
  local snapshot_dir="$TEMP_DIR/snapshot-$case_name"
  local log="$TEMP_DIR/failure-$case_name.log"
  local name

  generate_compliance \
    "$output_dir" \
    "$INPUT_DIR/cargo-metadata.json" \
    "$INPUT_DIR/pubspec.lock" \
    "$INPUT_DIR/package_config.json" \
    "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
    "$INPUT_DIR/bip39-NOTICE.md" \
    "$INPUT_DIR/libwebrtc-assets.sha256" >/dev/null
  require_output_set "$output_dir"

  mkdir -p "$snapshot_dir"
  for name in SBOM.spdx.json THIRD_PARTY_NOTICES.md SOURCE_CODE.md; do
    cp "$output_dir/$name" "$snapshot_dir/$name"
  done

  if generate_compliance \
    "$output_dir" \
    "$cargo_metadata" \
    "$pub_lock" \
    "$package_config" \
    "$pod_acknowledgements" \
    "$bip39_notice" \
    "$native_webrtc_manifest" >"$log" 2>&1; then
    fail "$case_name input unexpectedly generated release compliance files"
  fi
  require_text "$log" "$expected_error"

  for name in SBOM.spdx.json THIRD_PARTY_NOTICES.md SOURCE_CODE.md; do
    cmp "$output_dir/$name" "$snapshot_dir/$name" >/dev/null || {
      fail "$case_name failure replaced a previously valid $name"
    }
  done
}

cd "$ROOT_DIR"
[[ -f "$GENERATOR" ]] || fail "missing release compliance generator"

write_package_fixture
write_dependency_fixtures

readonly OUTPUT_ONE="$TEMP_DIR/output-one"
readonly OUTPUT_TWO="$TEMP_DIR/output-two"
generate_compliance \
  "$OUTPUT_ONE" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256"
generate_compliance \
  "$OUTPUT_TWO" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256"

require_output_set "$OUTPUT_ONE"
require_output_set "$OUTPUT_TWO"
assert_spdx_contract "$OUTPUT_ONE/SBOM.spdx.json"

if [[ -n "${ROAMMAND_SPDX_TOOLS_PYTHON:-}" ]]; then
  "$ROAMMAND_SPDX_TOOLS_PYTHON" \
    -m spdx_tools.spdx.clitools.pyspdxtools \
    -i "$OUTPUT_ONE/SBOM.spdx.json"
fi

PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT_DIR/scripts/test_vetted_cargo_notices.py"

cp "$INPUT_DIR/Podfile.lock" "$INPUT_DIR/Podfile.lock.original"
python3 - "$INPUT_DIR/Podfile.lock" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    path.read_text(encoding="utf-8").replace("f" * 40, "d" * 40),
    encoding="utf-8",
)
PY
generate_compliance \
  "$TEMP_DIR/output-component-change" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256" >/dev/null
cp "$INPUT_DIR/Podfile.lock.original" "$INPUT_DIR/Podfile.lock"
python3 - \
  "$OUTPUT_ONE/SBOM.spdx.json" \
  "$TEMP_DIR/output-component-change/SBOM.spdx.json" <<'PY'
import json
import pathlib
import sys

original = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
changed = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert original["documentNamespace"] != changed["documentNamespace"]
PY

for output_name in SBOM.spdx.json THIRD_PARTY_NOTICES.md SOURCE_CODE.md; do
  cmp "$OUTPUT_ONE/$output_name" "$OUTPUT_TWO/$output_name" >/dev/null || {
    fail "non-deterministic compliance output: $output_name"
  }
  if rg --quiet --fixed-strings -- "$TEMP_DIR" "$OUTPUT_ONE/$output_name"; then
    fail "compliance output leaks its local fixture path: $output_name"
  fi
done

for expected in \
  "Flutter fixture engine notice." \
  "Sample Dart fixture BSD-3-Clause license text." \
  "Sample Rust fixture MIT license text." \
  "WebRTC-SDK fixture BSD-3-Clause notice." \
  "flutter_webrtc fixture MIT notice." \
  "Copyright (c) 2018 湖北捷智云技术有限公司" \
  "Copyright 2014 The Flutter Authors. All rights reserved." \
  "Copyright (c) 2011, The WebRTC project authors. All rights reserved." \
  "Additional IP Rights Grant (Patents)" \
  "Copyright (C) 2017 Milo Yip. All rights reserved." \
  "$FLUTTER_LICENSE_SHA256" \
  "$WEBRTC_LICENSE_SHA256" \
  "$WEBRTC_PATENTS_SHA256" \
  "$FLUTTER_WEBRTC_UPSTREAM_ARCHIVE_SHA256" \
  "These files preserve the missing" \
  "https://github.com/flutter/flutter/blob/559ffa3f75e7402d65a8def9c28389a9b2e6fe42/LICENSE" \
  "https://webrtc.googlesource.com/src/+/refs/branch-heads/7559/LICENSE" \
  "https://webrtc.googlesource.com/src/+/refs/branch-heads/7559/PATENTS" \
  "BIP-39 fixture MIT notice." \
  "Native WebRTC arm64 fixture notice." \
  "Native WebRTC x86_64 fixture notice."; do
  require_text "$OUTPUT_ONE/THIRD_PARTY_NOTICES.md" "$expected"
done

for expected in \
  "$SOURCE_URL" \
  "$SOURCE_REVISION" \
  "$COPYRIGHT_HOLDER" \
  "https://example.test/sample-rust" \
  "https://pub.dev/packages/sample_dart" \
  "$SOURCE_URL/tree/$SOURCE_REVISION/third_party/flutter_webrtc" \
  "webrtc-fixture-1"; do
  require_text "$OUTPUT_ONE/SOURCE_CODE.md" "$expected"
done

if rg --quiet --fixed-strings \
  "https://pub.dev/packages/flutter_webrtc" \
  "$OUTPUT_ONE/SOURCE_CODE.md"; then
  fail "modified path flutter_webrtc is represented as hosted pub source"
fi

assert_failure_is_atomic \
  "unknown-cargo-license" \
  "unknown-rust-license" \
  "$INPUT_DIR/cargo-metadata-unknown.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256"

assert_failure_is_atomic \
  "missing-dart-license" \
  "unlicensed_dart" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec-unlicensed.lock" \
  "$INPUT_DIR/package_config_unlicensed.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256"

assert_failure_is_atomic \
  "missing-required-input" \
  "missing-Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/missing-Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256"

readonly ENGINE_INFO_PLIST="$APP_CONTENTS/Frameworks/FlutterMacOS.framework/Versions/A/Resources/Info.plist"
cp "$ENGINE_INFO_PLIST" "$INPUT_DIR/FlutterMacOS-Info.plist"
python3 - "$ENGINE_INFO_PLIST" "$FLUTTER_ENGINE_REVISION" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(
    path.read_text(encoding="utf-8").replace(sys.argv[2], "b" * 40),
    encoding="utf-8",
)
PY
if generate_compliance \
  "$TEMP_DIR/flutter-engine-mismatch" \
  "$INPUT_DIR/cargo-metadata.json" \
  "$INPUT_DIR/pubspec.lock" \
  "$INPUT_DIR/package_config.json" \
  "$INPUT_DIR/Pods-Runner-acknowledgements.markdown" \
  "$INPUT_DIR/bip39-NOTICE.md" \
  "$INPUT_DIR/libwebrtc-assets.sha256" \
  >"$TEMP_DIR/flutter-engine-mismatch.log" 2>&1; then
  fail "mismatched staged Flutter engine unexpectedly generated compliance files"
fi
require_text \
  "$TEMP_DIR/flutter-engine-mismatch.log" \
  "does not match staged FlutterMacOS.framework FlutterEngine"
cp "$INPUT_DIR/FlutterMacOS-Info.plist" "$ENGINE_INFO_PLIST"

python3 - "$ROOT_DIR" "$INPUT_DIR" <<'PY'
import argparse
import json
import pathlib
import sys
from unittest import mock

root = pathlib.Path(sys.argv[1])
inputs = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts"))

from macos_release_compliance.collectors import cargo_components
from macos_release_compliance.model import ComplianceError, validated_source_input_digests

metadata = json.loads((inputs / "cargo-metadata.json").read_text(encoding="utf-8"))
arguments = argparse.Namespace(cargo_metadata=[], cargo_lock=inputs / "Cargo-empty.lock")
with mock.patch(
    "macos_release_compliance.collectors.default_cargo_metadata",
    return_value=[metadata],
):
    try:
        cargo_components(root, arguments)
    except ComplianceError as error:
        assert "has no locked checksum" in str(error)
    else:
        raise AssertionError("default Cargo metadata accepted a missing lock checksum")

revision = __import__("subprocess").run(
    ("git", "rev-parse", "HEAD"),
    cwd=root,
    check=True,
    stdout=__import__("subprocess").PIPE,
    text=True,
).stdout.strip()
source_arguments = argparse.Namespace(
    source_revision=revision,
    cargo_metadata=[],
    cargo_lock=None,
    pub_lock=None,
    dart_package_config=None,
    pod_lock=None,
    pod_acknowledgements=None,
    bip39_notice=None,
    native_webrtc_manifest=None,
    flutter_version=None,
    flutter_engine_revision=None,
)
digests = validated_source_input_digests(root, source_arguments)
for required in (
    "Cargo.toml",
    "Cargo.lock",
    "apps/client_flutter/pubspec.yaml",
    "apps/client_flutter/pubspec.lock",
    "apps/client_flutter/macos/Podfile",
    "apps/client_flutter/macos/Podfile.lock",
    "third_party/flutter_webrtc/**",
    "scripts/libwebrtc-assets.sha256",
    "conformance/wordlists/bip39-english.txt",
):
    assert required in digests
PY

printf 'macOS release compliance contract ok\n'
