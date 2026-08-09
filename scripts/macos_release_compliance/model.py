# SPDX-License-Identifier: Apache-2.0
"""Shared models, constants, validation, and package inspection helpers."""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import urllib.parse
from collections.abc import Sequence
from typing import Any


OUTPUT_NAMES = (
    "SBOM.spdx.json",
    "THIRD_PARTY_NOTICES.md",
    "SOURCE_CODE.md",
)
APP_RELATIVE_PATH = pathlib.Path("Applications/Roammand.app/Contents")
SUPPORT_RELATIVE_PATH = pathlib.Path("Library/Application Support/Roammand")
LICENSE_RELATIVE_PATH = SUPPORT_RELATIVE_PATH / "licenses"
VOLATILE_PACKAGE_FILES = {
    pathlib.PurePosixPath(".roammand-package-output"),
    pathlib.PurePosixPath(SUPPORT_RELATIVE_PATH.as_posix()) / "install-manifest.sha256",
    *(
        pathlib.PurePosixPath(LICENSE_RELATIVE_PATH.as_posix()) / name
        for name in OUTPUT_NAMES
    ),
}
NOTICE_PREFIXES = (
    "license",
    "copying",
    "notice",
    "copyright",
    "unlicense",
    "patents",
)
RUST_RELEASE_ROOTS = {
    "roammand-host-agent",
    "roammand-privileged-bridge",
}
SOURCE_DATE_ENVIRONMENT_VARIABLE = "SOURCE_DATE_EPOCH"
DEFAULT_REPOSITORY_URL = "https://github.com/MisakiHCL/roammand"
NATIVE_WEBRTC_RELEASE_URL = "https://github.com/livekit/rust-sdks/releases/tag"
REPOSITORY_DART_PATH_DEPENDENCIES: dict[str, pathlib.PurePosixPath] = {
    "flutter_webrtc": pathlib.PurePosixPath("third_party/flutter_webrtc"),
}
REPOSITORY_DART_NOTICE_EXACT_PATHS: dict[
    str, frozenset[pathlib.PurePosixPath]
] = {
    "flutter_webrtc": frozenset(
        {
            pathlib.PurePosixPath("DOWNSTREAM_PATCH.md"),
            pathlib.PurePosixPath("third_party_licenses/README.md"),
        }
    ),
}
SPDX_LICENSE_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.+-]*")
SPDX_LICENSE_REF_TOKEN = re.compile(r"LicenseRef-[A-Za-z0-9.-]+")


class ComplianceError(RuntimeError):
    """An input cannot support a complete release-compliance result."""


@dataclasses.dataclass(frozen=True)
class Notice:
    label: str
    text: str


@dataclasses.dataclass(frozen=True)
class Component:
    ecosystem: str
    name: str
    version: str
    license_declared: str
    license_concluded: str
    source_url: str
    download_location: str
    relationship: str = "DEPENDS_ON"
    checksum: str = ""
    purl: str = ""
    copyright_text: str = "NOASSERTION"
    summary: str = ""
    notices: tuple[Notice, ...] = ()

    @property
    def key(self) -> tuple[str, str, str, str]:
        return (self.ecosystem, self.name, self.version, self.source_url)

    @property
    def spdx_id(self) -> str:
        readable = re.sub(r"[^A-Za-z0-9.-]+", "-", f"{self.ecosystem}-{self.name}")
        readable = readable.strip("-.") or "Component"
        digest = hashlib.sha256("\0".join(self.key).encode()).hexdigest()[:12]
        return f"SPDXRef-Package-{readable[:72]}-{digest}"


@dataclasses.dataclass(frozen=True)
class FlutterMetadata:
    version: str
    framework_revision: str
    engine_revision: str
    dart_version: str
    flutter_root: pathlib.Path | None


@dataclasses.dataclass(frozen=True)
class PackageMetadata:
    bundle_identifier: str
    name: str
    version: str
    build: str


@dataclasses.dataclass(frozen=True)
class ShippedFileInventory:
    files: list[dict[str, Any]]
    relationships: list[dict[str, str]]
    verification_code: str
    excluded_files: tuple[str, ...]
    inventory_sha256: str


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Generate an SPDX SBOM, third-party notices, and exact source record "
            "for a staged Roammand macOS package."
        )
    )
    parser.add_argument("--package-dir", required=True, type=pathlib.Path)
    parser.add_argument("--output-dir", required=True, type=pathlib.Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--copyright-holder", required=True)
    parser.add_argument(
        "--cargo-metadata",
        action="append",
        default=[],
        metavar="[ARCH=]PATH",
        help="cargo metadata format-version 1 JSON; may be repeated",
    )
    parser.add_argument(
        "--cargo-lock",
        type=pathlib.Path,
        help="Cargo.lock paired with the Cargo metadata (defaults to repository Cargo.lock)",
    )
    parser.add_argument("--pub-lock", type=pathlib.Path)
    parser.add_argument(
        "--dart-package-config",
        "--package-config",
        dest="dart_package_config",
        type=pathlib.Path,
    )
    parser.add_argument("--pod-lock", type=pathlib.Path)
    parser.add_argument("--pod-acknowledgements", type=pathlib.Path)
    parser.add_argument("--bip39-notice", type=pathlib.Path)
    parser.add_argument("--native-webrtc-manifest", type=pathlib.Path)
    parser.add_argument(
        "--native-notice",
        action="append",
        default=[],
        metavar="ARCH=PATH",
        help="override a packaged native WebRTC notice; may be repeated",
    )
    parser.add_argument("--material-icons-license", type=pathlib.Path)
    parser.add_argument("--flutter-version")
    parser.add_argument("--flutter-engine-revision")
    return parser.parse_args()


def fail(message: str) -> ComplianceError:
    return ComplianceError(message)


def require_file(path: pathlib.Path, label: str) -> pathlib.Path:
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        raise fail(f"missing or empty {label}: {path.name}")
    return path


def read_text(path: pathlib.Path, label: str) -> str:
    require_file(path, label)
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise fail(f"{label} is not UTF-8 text: {path.name}") from error
    if not text.strip():
        raise fail(f"empty {label}: {path.name}")
    return text.replace("\r\n", "\n").rstrip() + "\n"


def load_json(path: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(read_text(path, label))
    except json.JSONDecodeError as error:
        raise fail(f"invalid {label} JSON: {path.name}") from error
    if not isinstance(value, dict):
        raise fail(f"invalid {label} object: {path.name}")
    return value


def run_json(command: Sequence[str], cwd: pathlib.Path, label: str) -> dict[str, Any]:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError):
            detail = (error.stderr or "").strip().splitlines()[-1:]
            detail = f": {detail[0]}" if detail else ""
        raise fail(f"unable to collect {label}{detail}") from error
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise fail(f"{label} did not return JSON") from error
    if not isinstance(value, dict):
        raise fail(f"{label} did not return a JSON object")
    return value


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha1_file(path: pathlib.Path) -> str:
    digest = hashlib.sha1(usedforsecurity=False)
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def normalized_url(url: str) -> str:
    return url[:-4] if url.endswith(".git") else url


def validate_release_identity(arguments: argparse.Namespace) -> None:
    if not re.fullmatch(r"[0-9a-fA-F]{40}", arguments.source_revision):
        raise fail("source revision must be a full 40-character Git commit")
    parsed = urllib.parse.urlparse(arguments.source_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise fail("source URL must be an absolute HTTPS URL")
    if not arguments.copyright_holder.strip():
        raise fail("copyright holder must not be empty")


def package_metadata(package_dir: pathlib.Path) -> PackageMetadata:
    info_path = package_dir / APP_RELATIVE_PATH / "Info.plist"
    require_file(info_path, "Roammand Info.plist")
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise fail("invalid Roammand Info.plist") from error
    if not isinstance(info, dict):
        raise fail("invalid Roammand Info.plist dictionary")
    bundle_identifier = str(info.get("CFBundleIdentifier", "")).strip()
    name = str(info.get("CFBundleDisplayName") or info.get("CFBundleName") or "").strip()
    version = str(info.get("CFBundleShortVersionString", "")).strip()
    build = str(info.get("CFBundleVersion", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]+", bundle_identifier):
        raise fail("invalid macOS bundle identifier")
    if not name:
        raise fail("missing macOS bundle name")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", version):
        raise fail("invalid macOS marketing version")
    if not re.fullmatch(r"[0-9]+", build):
        raise fail("invalid macOS build number")
    return PackageMetadata(bundle_identifier, name, version, build)


def required_package_paths(package_dir: pathlib.Path) -> None:
    required = (
        APP_RELATIVE_PATH / "MacOS/roammand",
        APP_RELATIVE_PATH / "Frameworks/App.framework",
        APP_RELATIVE_PATH / "Frameworks/FlutterMacOS.framework",
        APP_RELATIVE_PATH / "Frameworks/WebRTC.framework",
        APP_RELATIVE_PATH / "Frameworks/flutter_webrtc.framework",
        APP_RELATIVE_PATH / "Frameworks/objective_c.framework",
        pathlib.Path("Library/PrivilegedHelperTools/roammand-host-agent"),
        pathlib.Path("Library/PrivilegedHelperTools/roammand-privileged-bridge"),
    )
    for relative in required:
        if not (package_dir / relative).exists():
            raise fail(f"staged macOS package is missing {relative.as_posix()}")


def flutter_assets_root(package_dir: pathlib.Path) -> pathlib.Path:
    candidates = (
        package_dir
        / APP_RELATIVE_PATH
        / "Frameworks/App.framework/Resources/flutter_assets",
        package_dir
        / APP_RELATIVE_PATH
        / "Frameworks/App.framework/Versions/A/Resources/flutter_assets",
    )
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise fail("staged macOS package is missing Flutter assets")


def collect_shipped_files(
    package_dir: pathlib.Path,
) -> ShippedFileInventory:
    files: list[dict[str, Any]] = []
    relationships: list[dict[str, str]] = []
    file_sha1_values: list[str] = []
    inventory_lines: list[str] = []
    for path in sorted(package_dir.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink() or not path.is_file():
            continue
        relative = pathlib.PurePosixPath(path.relative_to(package_dir).as_posix())
        if relative in VOLATILE_PACKAGE_FILES:
            continue
        sha1_checksum = sha1_file(path)
        sha256_checksum = sha256_file(path)
        file_id = f"SPDXRef-File-{hashlib.sha256(relative.as_posix().encode()).hexdigest()[:20]}"
        files.append(
            {
                "SPDXID": file_id,
                "fileName": f"./{relative.as_posix()}",
                "checksums": [
                    {"algorithm": "SHA1", "checksumValue": sha1_checksum},
                    {"algorithm": "SHA256", "checksumValue": sha256_checksum},
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
        file_sha1_values.append(sha1_checksum)
        inventory_lines.append(f"{sha256_checksum}  {relative.as_posix()}")
    if not files:
        raise fail("staged macOS package contains no regular files")
    verification_input = "".join(sorted(file_sha1_values)).encode("ascii")
    verification_code = hashlib.sha1(
        verification_input, usedforsecurity=False
    ).hexdigest()
    excluded_files = tuple(
        f"./{relative.as_posix()}"
        for relative in sorted(VOLATILE_PACKAGE_FILES, key=lambda item: item.as_posix())
    )
    inventory_sha256 = sha256_text("\n".join(inventory_lines) + "\n")
    return ShippedFileInventory(
        files=files,
        relationships=relationships,
        verification_code=verification_code,
        excluded_files=excluded_files,
        inventory_sha256=inventory_sha256,
    )


def decode_flutter_notices(assets_root: pathlib.Path) -> str:
    path = require_file(assets_root / "NOTICES.Z", "Flutter NOTICES.Z")
    try:
        text = gzip.decompress(path.read_bytes()).decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise fail("Flutter NOTICES.Z is not valid gzip UTF-8 content") from error
    if not text.strip():
        raise fail("Flutter NOTICES.Z is empty")
    return text.replace("\r\n", "\n").rstrip() + "\n"


def staged_flutter_engine_revision(package_dir: pathlib.Path) -> str:
    candidates = (
        package_dir
        / APP_RELATIVE_PATH
        / "Frameworks/FlutterMacOS.framework/Resources/Info.plist",
        package_dir
        / APP_RELATIVE_PATH
        / "Frameworks/FlutterMacOS.framework/Versions/A/Resources/Info.plist",
    )
    info_path = next((path for path in candidates if path.is_file()), None)
    if info_path is None:
        raise fail("staged FlutterMacOS.framework is missing Resources/Info.plist")
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise fail("invalid staged FlutterMacOS.framework Info.plist") from error
    if not isinstance(info, dict):
        raise fail("invalid staged FlutterMacOS.framework Info.plist dictionary")
    revision = str(info.get("FlutterEngine") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise fail("staged FlutterMacOS.framework has an invalid FlutterEngine revision")
    return revision


def collect_flutter_metadata(
    package_dir: pathlib.Path,
    repo_root: pathlib.Path,
    arguments: argparse.Namespace,
) -> FlutterMetadata:
    staged_engine = staged_flutter_engine_revision(package_dir)
    has_version_override = bool(arguments.flutter_version)
    has_engine_override = bool(arguments.flutter_engine_revision)
    if has_version_override != has_engine_override:
        raise fail(
            "Flutter version and engine revision overrides must be supplied together"
        )
    machine: dict[str, Any] = {}
    if not has_version_override:
        machine = run_json(
            ("flutter", "--version", "--machine"), repo_root, "Flutter metadata"
        )
    version = arguments.flutter_version or str(
        machine.get("flutterVersion") or machine.get("frameworkVersion") or ""
    )
    framework_revision = str(machine.get("frameworkRevision") or "")
    collected_engine = arguments.flutter_engine_revision or str(
        machine.get("engineRevision") or ""
    )
    engine_revision = collected_engine.strip().lower()
    dart_version = str(machine.get("dartSdkVersion") or "")
    flutter_root_raw = str(machine.get("flutterRoot") or "")
    flutter_root = pathlib.Path(flutter_root_raw) if flutter_root_raw else None
    if not version:
        raise fail("missing Flutter version")
    if not re.fullmatch(r"[0-9a-f]{40}", engine_revision):
        raise fail("missing or invalid Flutter engine revision")
    if engine_revision != staged_engine:
        raise fail(
            "Flutter engine revision does not match staged "
            "FlutterMacOS.framework FlutterEngine"
        )
    return FlutterMetadata(
        version=version,
        framework_revision=framework_revision,
        engine_revision=engine_revision,
        dart_version=dart_version,
        flutter_root=flutter_root,
    )


def explicit_fixture_inputs(arguments: argparse.Namespace) -> bool:
    return all(
        (
            bool(getattr(arguments, "cargo_metadata", [])),
            getattr(arguments, "cargo_lock", None) is not None,
            getattr(arguments, "pub_lock", None) is not None,
            getattr(arguments, "dart_package_config", None) is not None,
            getattr(arguments, "pod_lock", None) is not None,
            getattr(arguments, "pod_acknowledgements", None) is not None,
            getattr(arguments, "bip39_notice", None) is not None,
            getattr(arguments, "native_webrtc_manifest", None) is not None,
            bool(getattr(arguments, "flutter_version", None)),
            bool(getattr(arguments, "flutter_engine_revision", None)),
        )
    )


def git_output(
    repo_root: pathlib.Path, command: Sequence[str], label: str, *, text: bool
) -> str | bytes:
    try:
        result = subprocess.run(
            ("git", *command),
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=text,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise fail(f"unable to inspect {label} at the source revision") from error
    return result.stdout


def validated_source_input_digests(
    repo_root: pathlib.Path, arguments: argparse.Namespace
) -> dict[str, str]:
    """Verify default release inputs against the exact Git tree and hash them."""
    if explicit_fixture_inputs(arguments):
        return {}
    revision = arguments.source_revision
    revision_listing = str(
        git_output(
            repo_root,
            ("ls-tree", "-r", "--name-only", revision),
            "source tree",
            text=True,
        )
    ).splitlines()
    tracked_listing = str(
        git_output(repo_root, ("ls-files", "--cached"), "working tree", text=True)
    ).splitlines()
    revision_cargo = {
        path for path in revision_listing if pathlib.PurePosixPath(path).name == "Cargo.toml"
    }
    tracked_cargo = {
        path for path in tracked_listing if pathlib.PurePosixPath(path).name == "Cargo.toml"
    }
    if revision_cargo != tracked_cargo:
        raise fail("the set of Cargo.toml files differs from the source revision")
    required_paths = sorted(revision_cargo) + [
        "Cargo.lock",
        "apps/client_flutter/pubspec.yaml",
        "apps/client_flutter/pubspec.lock",
        "apps/client_flutter/macos/Podfile",
        "apps/client_flutter/macos/Podfile.lock",
        "scripts/libwebrtc-assets.sha256",
        "conformance/wordlists/bip39-english.txt",
    ]
    digests: dict[str, str] = {}
    for relative in required_paths:
        current_path = require_file(repo_root / relative, f"source input {relative}")
        source_bytes = git_output(
            repo_root,
            ("show", f"{revision}:{relative}"),
            relative,
            text=False,
        )
        current_bytes = current_path.read_bytes()
        if current_bytes != source_bytes:
            raise fail(f"source input does not match revision: {relative}")
        digests[relative] = hashlib.sha256(current_bytes).hexdigest()

    repository_trees = sorted(
        {path.as_posix() for path in REPOSITORY_DART_PATH_DEPENDENCIES.values()}
    )
    for tree in repository_trees:
        prefix = f"{tree.rstrip('/')}/"
        revision_files = sorted(
            path for path in revision_listing if path.startswith(prefix)
        )
        tracked_files = sorted(
            path for path in tracked_listing if path.startswith(prefix)
        )
        if not revision_files:
            raise fail(f"repository path dependency is missing at revision: {tree}")
        if revision_files != tracked_files:
            raise fail(
                f"repository path dependency file set differs from revision: {tree}"
            )

        manifest_lines: list[str] = []
        for relative in revision_files:
            current_path = require_file(
                repo_root / relative, f"repository path dependency source {relative}"
            )
            source_bytes = git_output(
                repo_root,
                ("show", f"{revision}:{relative}"),
                relative,
                text=False,
            )
            current_bytes = current_path.read_bytes()
            if current_bytes != source_bytes:
                raise fail(f"source input does not match revision: {relative}")
            manifest_lines.append(
                f"{hashlib.sha256(current_bytes).hexdigest()}  {relative}"
            )
        digests[f"{tree}/**"] = sha256_text("\n".join(manifest_lines) + "\n")
    return digests
