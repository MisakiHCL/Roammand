#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

PACKAGE_DIR=""
REQUIRE_COMPLIANCE=false
while (($#)); do
  case "$1" in
    --require-compliance)
      REQUIRE_COMPLIANCE=true
      shift
      ;;
    -*)
      printf 'unknown macOS package check option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$PACKAGE_DIR" ]]; then
        printf 'only one package directory may be checked\n' >&2
        exit 2
      fi
      PACKAGE_DIR="$1"
      shift
      ;;
  esac
done

[[ -n "$PACKAGE_DIR" && -d "$PACKAGE_DIR" ]] || { printf 'package directory required\n' >&2; exit 2; }
readonly MANIFEST="$PACKAGE_DIR/Library/Application Support/Roammand/install-manifest.sha256"
readonly APP_INFO="$PACKAGE_DIR/Applications/Roammand.app/Contents/Info.plist"
readonly BACKGROUND_JOB_PLISTS=(
  "Library/LaunchAgents/dev.roammand.SessionAgent.plist"
  "Library/LaunchDaemons/dev.roammand.PrivilegedBridge.plist"
)

readonly REQUIRED=(
  "Applications/Roammand.app"
  "Library/PrivilegedHelperTools/roammand-host-agent"
  "Library/PrivilegedHelperTools/roammand-privileged-bridge"
  "Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app"
  "Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app/Contents/MacOS/roammand-session-agent"
  "Library/LaunchDaemons/dev.roammand.PrivilegedBridge.plist"
  "Library/LaunchAgents/dev.roammand.SessionAgent.plist"
  "Library/Application Support/Roammand/uninstall-macos.sh"
  "Library/Application Support/Roammand/licenses/MPL-2.0.txt"
  "Library/Application Support/Roammand/licenses/Apache-2.0.txt"
  "Library/Application Support/Roammand/licenses/libwebrtc-macos-arm64-LICENSE.md"
  "Library/Application Support/Roammand/licenses/libwebrtc-macos-x86_64-LICENSE.md"
)
for path in "${REQUIRED[@]}"; do
  [[ -e "$PACKAGE_DIR/$path" ]] || { printf 'missing staged macOS path: %s\n' "$path" >&2; exit 1; }
done
app_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$APP_INFO" 2>/dev/null || true)"
if [[ ! "$app_bundle_id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$ ]]; then
  printf 'staged macOS app bundle identifier is invalid\n' >&2
  exit 1
fi
for path in "${BACKGROUND_JOB_PLISTS[@]}"; do
  job_plist="$PACKAGE_DIR/$path"
  associated_bundle_id="$(plutil -extract AssociatedBundleIdentifiers.0 \
    raw -o - "$job_plist" 2>/dev/null || true)"
  if [[ "$associated_bundle_id" != "$app_bundle_id" ]] ||
    plutil -extract AssociatedBundleIdentifiers.1 raw -o - \
      "$job_plist" >/dev/null 2>&1; then
    printf 'staged macOS background item is not associated with the app: %s\n' \
      "$path" >&2
    exit 1
  fi
done
for path in \
  "Library/Application Support/Roammand/licenses/libwebrtc-macos-arm64-LICENSE.md" \
  "Library/Application Support/Roammand/licenses/libwebrtc-macos-x86_64-LICENSE.md"; do
  [[ -f "$PACKAGE_DIR/$path" && -s "$PACKAGE_DIR/$path" ]] || {
    printf 'staged libwebrtc license is not a non-empty regular file\n' >&2
    exit 1
  }
done
if $REQUIRE_COMPLIANCE; then
  readonly COMPLIANCE_DIR="$PACKAGE_DIR/Library/Application Support/Roammand/licenses"
  readonly COMPLIANCE_FILES=(
    "SBOM.spdx.json"
    "THIRD_PARTY_NOTICES.md"
    "SOURCE_CODE.md"
  )
  for path in "${COMPLIANCE_FILES[@]}"; do
    [[ -f "$COMPLIANCE_DIR/$path" &&
        ! -L "$COMPLIANCE_DIR/$path" &&
        -s "$COMPLIANCE_DIR/$path" ]] || {
      printf 'staged macOS compliance asset is not a non-empty regular file: %s\n' \
        "$path" >&2
      exit 1
    }
  done
  python3 - \
    "$COMPLIANCE_DIR/SBOM.spdx.json" \
    "$COMPLIANCE_DIR/THIRD_PARTY_NOTICES.md" \
    "$COMPLIANCE_DIR/SOURCE_CODE.md" \
    "$PACKAGE_DIR" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import re
import sys

path = pathlib.Path(sys.argv[1])
notices_path = pathlib.Path(sys.argv[2])
source_record_path = pathlib.Path(sys.argv[3])
package_root = pathlib.Path(sys.argv[4]).resolve()
excluded_paths = {
    ".roammand-package-output",
    "Library/Application Support/Roammand/install-manifest.sha256",
    "Library/Application Support/Roammand/licenses/SBOM.spdx.json",
    "Library/Application Support/Roammand/licenses/THIRD_PARTY_NOTICES.md",
    "Library/Application Support/Roammand/licenses/SOURCE_CODE.md",
}
try:
    document = json.loads(path.read_text(encoding="utf-8"))
    notices_text = notices_path.read_text(encoding="utf-8")
    source_record_text = source_record_path.read_text(encoding="utf-8")
except (OSError, UnicodeDecodeError, json.JSONDecodeError):
    print("staged macOS compliance records are not valid UTF-8", file=sys.stderr)
    raise SystemExit(1)


def reject(message: str) -> None:
    print(f"staged macOS SBOM is invalid: {message}", file=sys.stderr)
    raise SystemExit(1)


if not isinstance(document, dict):
    reject("document root must be an object")
if document.get("spdxVersion") != "SPDX-2.3":
    reject("spdxVersion must be SPDX-2.3")
if document.get("dataLicense") != "CC0-1.0":
    reject("dataLicense must be CC0-1.0")
if document.get("SPDXID") != "SPDXRef-DOCUMENT":
    reject("document SPDXID is missing")
identity_match = re.fullmatch(
    r"Roammand macOS ([0-9]+(?:\.[0-9]+)+) build ([0-9]+)",
    str(document.get("name", "")),
)
if identity_match is None:
    reject("document name does not contain the release version and build")
release_version, release_build = identity_match.groups()
namespace = document.get("documentNamespace")
if not isinstance(namespace, str) or not namespace.startswith("https://"):
    reject("documentNamespace must be an HTTPS URL")
creation = document.get("creationInfo")
if not isinstance(creation, dict) or not creation.get("created") or not creation.get("creators"):
    reject("creationInfo is incomplete")

packages = document.get("packages")
files = document.get("files")
relationships = document.get("relationships")
if not isinstance(packages, list) or not packages:
    reject("packages must be a non-empty list")
if not isinstance(files, list) or not files:
    reject("files must be a non-empty list")
if not isinstance(relationships, list) or not relationships:
    reject("relationships must be a non-empty list")

root_id = "SPDXRef-Package-Roammand"
root = next(
    (
        package
        for package in packages
        if isinstance(package, dict) and package.get("SPDXID") == root_id
    ),
    None,
)
if root is None or root.get("filesAnalyzed") is not True:
    reject("Roammand root package must analyze its shipped files")
if root.get("name") != "Roammand" or root.get("versionInfo") != release_version:
    reject("Roammand root package identity differs from the document")
verification = root.get("packageVerificationCode")
if not isinstance(verification, dict) or not re.fullmatch(
    r"[0-9a-fA-F]{40}", str(verification.get("packageVerificationCodeValue", ""))
):
    reject("root package verification code must be a SHA-1 value")
expected_exclusions = {f"./{value}" for value in excluded_paths}
declared_exclusions = verification.get("packageVerificationCodeExcludedFiles")
if not isinstance(declared_exclusions, list) or set(declared_exclusions) != (
    expected_exclusions
):
    reject("root package verification-code exclusions are incomplete")
source_info = str(root.get("sourceInfo", ""))
source_identity_match = re.match(
    r"(https://\S+) at commit ([0-9a-fA-F]{40}); "
    r"bundle ([A-Za-z0-9.-]+), build ([0-9]+);",
    source_info,
)
inventory_match = re.search(
    r"not a serialized \.pkg file: ([0-9a-fA-F]{64})\.", source_info
)
if source_identity_match is None or inventory_match is None:
    reject("root sourceInfo is missing provenance or payload inventory identity")
source_url, source_revision, bundle_identifier, source_build = (
    source_identity_match.groups()
)
source_revision = source_revision.lower()
if source_build != release_build:
    reject("root sourceInfo build differs from the document")
inventory_sha256 = inventory_match.group(1).lower()
info_path = (
    package_root / "Applications/Roammand.app/Contents/Info.plist"
)
try:
    with info_path.open("rb") as info_source:
        bundle_info = plistlib.load(info_source)
except (OSError, plistlib.InvalidFileException, ValueError):
    reject("staged Roammand Info.plist is unreadable")
if not isinstance(bundle_info, dict):
    reject("staged Roammand Info.plist is not a dictionary")
if str(bundle_info.get("CFBundleIdentifier", "")) != bundle_identifier:
    reject("SBOM bundle identifier differs from the staged app")
if str(bundle_info.get("CFBundleShortVersionString", "")) != release_version:
    reject("SBOM release version differs from the staged app")
if str(bundle_info.get("CFBundleVersion", "")) != release_build:
    reject("SBOM build differs from the staged app")
supplier_match = re.fullmatch(r"Person: (.+)", str(root.get("supplier", "")))
if supplier_match is None or not supplier_match.group(1).strip():
    reject("Roammand root package has no copyright holder identity")
copyright_holder = supplier_match.group(1).strip()
if root.get("originator") != f"Person: {copyright_holder}":
    reject("Roammand root package supplier and originator differ")
if copyright_holder not in str(root.get("copyrightText", "")):
    reject("Roammand root package copyright text differs from its supplier")
created = str(creation.get("created"))
product_line = f"- Product: Roammand {release_version} (build {release_build})"
bundle_line = f"- Bundle identifier: `{bundle_identifier}`"
inventory_line = f"- Payload inventory SHA-256: `{inventory_sha256}`"
if product_line not in notices_text or product_line not in source_record_text:
    reject("human-readable records do not match the SBOM release identity")
if bundle_line not in notices_text or bundle_line not in source_record_text:
    reject("human-readable records do not match the SBOM bundle identifier")
if inventory_line not in notices_text or inventory_line not in source_record_text:
    reject("human-readable records do not match the SBOM payload inventory")
if f"- Source: {source_url}" not in notices_text:
    reject("third-party notices do not match the SBOM source URL")
if f"- Exact project source: {source_url}" not in source_record_text:
    reject("source record does not match the SBOM source URL")
if f"- Source revision: `{source_revision}`" not in notices_text:
    reject("third-party notices do not match the SBOM source revision")
if f"- Exact Git commit: `{source_revision}`" not in source_record_text:
    reject("source record does not match the SBOM source revision")
if f"- Generated: {created}" not in notices_text:
    reject("third-party notices do not match the SBOM creation time")
if f"- Generated: {created}" not in source_record_text:
    reject("source record does not match the SBOM creation time")
if f"- Project copyright holder: {copyright_holder}" not in notices_text:
    reject("third-party notices do not match the SBOM copyright holder")
if f"- Copyright holder: {copyright_holder}" not in source_record_text:
    reject("source record does not match the SBOM copyright holder")

file_ids = set()
sbom_files = {}
for file_entry in files:
    if not isinstance(file_entry, dict):
        reject("file entry must be an object")
    file_id = file_entry.get("SPDXID")
    if not isinstance(file_id, str) or not file_id.startswith("SPDXRef-File-"):
        reject("file entry has an invalid SPDXID")
    if file_id in file_ids:
        reject("file SPDXIDs must be unique")
    file_ids.add(file_id)
    file_name = file_entry.get("fileName")
    if not isinstance(file_name, str) or not file_name.startswith("./"):
        reject(f"{file_id} has an invalid fileName")
    relative = pathlib.PurePosixPath(file_name[2:])
    if not relative.parts or relative.is_absolute() or ".." in relative.parts:
        reject(f"{file_id} has an unsafe fileName")
    if relative.as_posix() in excluded_paths:
        reject(f"{file_id} lists an excluded volatile file")
    if relative.as_posix() in sbom_files:
        reject("file names must be unique")
    checksums = file_entry.get("checksums")
    if not isinstance(checksums, list):
        reject(f"{file_id} has no checksums")
    checksum_map = {
        item.get("algorithm"): item.get("checksumValue")
        for item in checksums
        if isinstance(item, dict)
    }
    if not re.fullmatch(r"[0-9a-fA-F]{40}", str(checksum_map.get("SHA1", ""))):
        reject(f"{file_id} is missing a SHA-1 checksum")
    if not re.fullmatch(r"[0-9a-fA-F]{64}", str(checksum_map.get("SHA256", ""))):
        reject(f"{file_id} is missing a SHA-256 checksum")
    sbom_files[relative.as_posix()] = (
        str(checksum_map["SHA1"]).lower(),
        str(checksum_map["SHA256"]).lower(),
    )

actual_files = {}
inventory_lines = []
for actual_path in sorted(package_root.rglob("*"), key=lambda item: item.as_posix()):
    if actual_path.is_symlink() or not actual_path.is_file():
        continue
    relative = actual_path.relative_to(package_root).as_posix()
    if relative in excluded_paths:
        continue
    sha1_digest = hashlib.sha1(usedforsecurity=False)
    sha256_digest = hashlib.sha256()
    with actual_path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha1_digest.update(chunk)
            sha256_digest.update(chunk)
    sha1 = sha1_digest.hexdigest()
    sha256 = sha256_digest.hexdigest()
    actual_files[relative] = (sha1, sha256)
    inventory_lines.append(f"{sha256}  {relative}")
if sbom_files != actual_files:
    missing = sorted(set(actual_files) - set(sbom_files))
    unexpected = sorted(set(sbom_files) - set(actual_files))
    changed = sorted(
        relative
        for relative in set(actual_files) & set(sbom_files)
        if actual_files[relative] != sbom_files[relative]
    )
    detail = (
        f"missing={missing[:1]}, unexpected={unexpected[:1]}, "
        f"changed={changed[:1]}"
    )
    reject(f"file inventory does not match the staged payload ({detail})")
verification_input = "".join(
    sorted(checksums[0] for checksums in actual_files.values())
).encode("ascii")
actual_verification = hashlib.sha1(
    verification_input, usedforsecurity=False
).hexdigest()
if str(verification["packageVerificationCodeValue"]).lower() != actual_verification:
    reject("root package verification code does not match the staged payload")
actual_inventory = hashlib.sha256(
    ("\n".join(inventory_lines) + "\n").encode("utf-8")
).hexdigest()
if actual_inventory != inventory_sha256:
    reject("payload inventory SHA-256 does not match the staged payload")

describes_root = any(
    isinstance(relationship, dict)
    and relationship.get("spdxElementId") == "SPDXRef-DOCUMENT"
    and relationship.get("relationshipType") == "DESCRIBES"
    and relationship.get("relatedSpdxElement") == root_id
    for relationship in relationships
)
if not describes_root:
    reject("document does not DESCRIBE the Roammand root package")
contained_files = {
    relationship.get("relatedSpdxElement")
    for relationship in relationships
    if isinstance(relationship, dict)
    and relationship.get("spdxElementId") == root_id
    and relationship.get("relationshipType") == "CONTAINS"
}
if contained_files != file_ids:
    reject("root CONTAINS relationships do not match the file inventory")

license_ref_pattern = re.compile(r"LicenseRef-[A-Za-z0-9.-]+")
raw_license_ref_pattern = re.compile(r"LicenseRef-[A-Za-z0-9._-]+")
used_license_refs = set()
for package in packages:
    if not isinstance(package, dict):
        reject("package entry must be an object")
    for field in ("licenseDeclared", "licenseConcluded"):
        expression = str(package.get(field, ""))
        raw_refs = raw_license_ref_pattern.findall(expression)
        if any(license_ref_pattern.fullmatch(value) is None for value in raw_refs):
            reject(f"{package.get('SPDXID', 'package')} has an invalid LicenseRef")
        used_license_refs.update(license_ref_pattern.findall(expression))
extracted = document.get("hasExtractedLicensingInfos", [])
extracted_ids = {
    item.get("licenseId")
    for item in extracted
    if isinstance(item, dict)
    and item.get("extractedText")
    and license_ref_pattern.fullmatch(str(item.get("licenseId", "")))
}
if not used_license_refs.issubset(extracted_ids):
    reject("one or more LicenseRef values have no extracted license text")
PY
fi
[[ -x "$PACKAGE_DIR/Library/Application Support/Roammand/uninstall-macos.sh" ]] || {
  printf 'staged macOS uninstaller is not executable\n' >&2
  exit 1
}
[[ ! -e "$PACKAGE_DIR/Library/LaunchAgents/dev.roammand.HostAgent.plist" ]] || {
  printf 'GUI-managed Host Agent must not be installed as a launchd job\n' >&2
  exit 1
}
[[ -f "$MANIFEST" ]] || { printf 'missing macOS package manifest\n' >&2; exit 1; }
(
  cd "$PACKAGE_DIR"
  shasum -a 256 -c "Library/Application Support/Roammand/install-manifest.sha256" >/dev/null
)
readonly PACKAGE_ROOT="$(realpath "$PACKAGE_DIR")"
readonly FRAMEWORKS_ROOT="$PACKAGE_ROOT/Applications/Roammand.app/Contents/Frameworks"
while IFS= read -r -d '' link; do
  target="$(readlink "$link")"
  link_parent="$(cd "$(dirname "$link")" && pwd -P)"
  link_absolute="$link_parent/$(basename "$link")"
  resolved="$(realpath "$link")"
  if [[ "$target" == /* || "$link_absolute" != "$FRAMEWORKS_ROOT/"* || "$resolved" != "$FRAMEWORKS_ROOT/"* ]]; then
    printf 'unsafe symbolic link in staged macOS package\n' >&2
    exit 1
  fi
done < <(find "$PACKAGE_DIR" -type l -print0)

readonly UNIVERSAL_BINARIES=(
  "Applications/Roammand.app/Contents/MacOS/roammand"
  "Library/PrivilegedHelperTools/roammand-host-agent"
  "Library/PrivilegedHelperTools/roammand-privileged-bridge"
  "Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app/Contents/MacOS/roammand-session-agent"
)
for path in "${UNIVERSAL_BINARIES[@]}"; do
  binary="$PACKAGE_DIR/$path"
  if file -b "$binary" | rg -q '^Mach-O'; then
    lipo "$binary" -verify_arch arm64 x86_64 >/dev/null || {
      printf 'macOS package binary is not Universal\n' >&2
      exit 1
    }
  fi
done
readonly SESSION_AGENT="$PACKAGE_DIR/Applications/Roammand.app/Contents/Library/LoginItems/RoammandSessionAgent.app/Contents/MacOS/roammand-session-agent"
if file -b "$SESSION_AGENT" | rg -q '^Mach-O'; then
  for architecture in arm64 x86_64; do
    if ! nm -arch "$architecture" "$SESSION_AGENT" 2>/dev/null | \
      rg -F '+[NSString(AbslStringView) stringForAbslStringView:]' >/dev/null; then
      printf 'macOS Session Agent is missing required Objective-C categories\n' >&2
      exit 1
    fi
  done
fi
"$PACKAGE_DIR/Library/PrivilegedHelperTools/roammand-privileged-bridge" \
  check-macos-daemon >/dev/null
"$SESSION_AGENT" check-macos-agent >/dev/null
printf 'macOS package ok\n'
