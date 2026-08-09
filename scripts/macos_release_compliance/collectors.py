# SPDX-License-Identifier: Apache-2.0
"""Dependency, attribution, and bundled-asset collectors."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import tomllib
import urllib.parse
from collections.abc import Iterable, Sequence
from typing import Any

from .model import (
    LICENSE_RELATIVE_PATH,
    NATIVE_WEBRTC_RELEASE_URL,
    NOTICE_PREFIXES,
    REPOSITORY_DART_NOTICE_EXACT_PATHS,
    REPOSITORY_DART_PATH_DEPENDENCIES,
    RUST_RELEASE_ROOTS,
    Component,
    FlutterMetadata,
    Notice,
    explicit_fixture_inputs,
    fail,
    load_json,
    normalized_url,
    read_text,
    require_file,
    run_json,
    sha256_file,
    sha256_text,
)
from .vetted_cargo_notices import vetted_notice_for_package


def notice_candidates(
    package_root: pathlib.Path,
    *,
    recursive: bool = False,
    exact_relative_paths: frozenset[pathlib.PurePosixPath] = frozenset(),
) -> list[pathlib.Path]:
    if not package_root.is_dir():
        return []
    candidates = package_root.rglob("*") if recursive else package_root.iterdir()
    return sorted(
        (
            path
            for path in candidates
            if path.is_file()
            and not path.is_symlink()
            and (
                path.name.lower().startswith(NOTICE_PREFIXES)
                or pathlib.PurePosixPath(
                    path.relative_to(package_root).as_posix()
                )
                in exact_relative_paths
            )
        ),
        key=lambda path: path.relative_to(package_root).as_posix().lower(),
    )


def infer_license_expression(text: str, file_name: str = "") -> str:
    lowered = text.lower()
    lowered_name = file_name.lower()
    explicit_markers = (
        ("bsd-3-clause", "BSD-3-Clause"),
        ("bsd 3-clause", "BSD-3-Clause"),
        ("bsd-2-clause", "BSD-2-Clause"),
        ("apache-2.0", "Apache-2.0"),
        ("mpl-2.0", "MPL-2.0"),
        ("cc-by-4.0", "CC-BY-4.0"),
        ("cc by 4.0", "CC-BY-4.0"),
        ("unicode-3.0", "Unicode-3.0"),
        ("cdla-permissive-2.0", "CDLA-Permissive-2.0"),
        ("bsl-1.0", "BSL-1.0"),
    )
    for marker, identifier in explicit_markers:
        if marker in lowered or marker in lowered_name:
            return identifier
    if "apache" in lowered_name:
        return "Apache-2.0"
    if "mit" in lowered_name:
        return "MIT"
    if "zlib" in lowered_name:
        return "Zlib"
    if "unicode" in lowered_name:
        return "Unicode-3.0"
    if "boost" in lowered_name:
        return "BSL-1.0"
    if "unlicense" in lowered_name:
        return "Unlicense"
    if "creative commons attribution 4.0" in lowered:
        return "CC-BY-4.0"
    if "apache license" in lowered and "version 2.0" in lowered:
        return "Apache-2.0"
    if (
        "permission is hereby granted, free of charge" in lowered
        and "the software is provided \"as is\"" in lowered
    ):
        return "MIT"
    if "redistribution and use in source and binary forms" in lowered:
        if "neither the name" in lowered or "names of its contributors" in lowered:
            return "BSD-3-Clause"
        return "BSD-2-Clause"
    if "permission to use, copy, modify, and/or distribute" in lowered:
        return "ISC"
    if "this software is provided 'as-is'" in lowered and "altered source versions" in lowered:
        return "Zlib"
    if "boost software license - version 1.0" in lowered:
        return "BSL-1.0"
    if "this is free and unencumbered software released into the public domain" in lowered:
        return "Unlicense"
    if "creative commons zero v1.0 universal" in lowered:
        return "CC0-1.0"
    return ""


def normalize_cargo_license(expression: str) -> str:
    normalized = expression.strip()
    normalized = re.sub(r"\s*/\s*", " OR ", normalized)
    normalized = re.sub(r"\s+", " ", normalized)
    return normalized


def copyright_text_from_notices(notices: Sequence[Notice]) -> str:
    statements: list[str] = []
    for notice in notices:
        for line in notice.text.splitlines():
            statement = line.strip().lstrip("#/*;!- ").strip()
            # A copyright keyword alone appears throughout license boilerplate.
            # Require a concrete four-digit year to avoid turning template or
            # operative license clauses into asserted copyright statements.
            if not re.match(
                r"^(?:Copyright(?:\s+\(c\)|\s+©)?|©)\s+.*"
                r"\b(?:18|19|20)\d{2}\b",
                statement,
                flags=re.IGNORECASE,
            ):
                continue
            if statement not in statements:
                statements.append(statement)
    return "\n".join(statements) or "NOASSERTION"


def parse_metadata_argument(raw: str) -> pathlib.Path:
    candidate = raw.split("=", 1)[1] if "=" in raw else raw
    return pathlib.Path(candidate)


def default_cargo_metadata(repo_root: pathlib.Path) -> list[dict[str, Any]]:
    documents: list[dict[str, Any]] = []
    feature_list = (
        "roammand-host-agent/native-webrtc,"
        "roammand-privileged-bridge/native-webrtc"
    )
    for target in ("aarch64-apple-darwin", "x86_64-apple-darwin"):
        documents.append(
            run_json(
                (
                    "cargo",
                    "metadata",
                    "--locked",
                    "--format-version",
                    "1",
                    "--filter-platform",
                    target,
                    "--features",
                    feature_list,
                ),
                repo_root,
                f"Cargo metadata for {target}",
            )
        )
    return documents


def cargo_dependency_roles(document: dict[str, Any]) -> dict[str, str]:
    packages = {
        str(package.get("id")): package
        for package in document.get("packages", [])
        if isinstance(package, dict) and package.get("id")
    }
    roots = {
        package_id
        for package_id, package in packages.items()
        if package.get("name") in RUST_RELEASE_ROOTS
    }
    resolve = document.get("resolve")
    nodes_raw = resolve.get("nodes", []) if isinstance(resolve, dict) else []
    nodes = {
        str(node.get("id")): node
        for node in nodes_raw
        if isinstance(node, dict) and node.get("id")
    }
    if not roots:
        return {
            package_id: "DEPENDS_ON"
            for package_id, package in packages.items()
            if package.get("source")
        }
    roles: dict[str, str] = {}
    pending = [(package_id, "runtime") for package_id in roots]
    visited: set[tuple[str, str]] = set()
    while pending:
        package_id, traversal_role = pending.pop()
        visit = (package_id, traversal_role)
        if visit in visited:
            continue
        visited.add(visit)
        node = nodes.get(package_id, {})
        for dependency in node.get("deps", []):
            if not isinstance(dependency, dict):
                continue
            kinds = dependency.get("dep_kinds", [])
            non_dev_kinds = [
                kind.get("kind")
                for kind in kinds
                if isinstance(kind, dict) and kind.get("kind") != "dev"
            ]
            if kinds and not non_dev_kinds:
                continue
            dependency_id = str(dependency.get("pkg") or "")
            if not dependency_id:
                continue
            is_runtime_edge = traversal_role == "runtime" and (
                not kinds or any(kind in {None, "normal"} for kind in non_dev_kinds)
            )
            dependency_role = "runtime" if is_runtime_edge else "build"
            relationship = (
                "DEPENDS_ON"
                if dependency_role == "runtime"
                else "BUILD_DEPENDENCY_OF"
            )
            if roles.get(dependency_id) != "DEPENDS_ON":
                roles[dependency_id] = relationship
            pending.append((dependency_id, dependency_role))
        if not node.get("deps"):
            for dependency_id in node.get("dependencies", []):
                normalized_id = str(dependency_id)
                relationship = (
                    "DEPENDS_ON"
                    if traversal_role == "runtime"
                    else "BUILD_DEPENDENCY_OF"
                )
                if roles.get(normalized_id) != "DEPENDS_ON":
                    roles[normalized_id] = relationship
                pending.append((normalized_id, traversal_role))
    return roles


def cargo_lock_checksums(path: pathlib.Path) -> dict[tuple[str, str, str], str]:
    try:
        document = tomllib.loads(read_text(path, "Cargo.lock"))
    except tomllib.TOMLDecodeError as error:
        raise fail("invalid Cargo.lock TOML") from error
    checksums: dict[tuple[str, str, str], str] = {}
    for package in document.get("package", []):
        if not isinstance(package, dict):
            continue
        name = str(package.get("name") or "")
        version = str(package.get("version") or "")
        source = str(package.get("source") or "")
        checksum = str(package.get("checksum") or "")
        if not name or not version or not source:
            continue
        if checksum and not re.fullmatch(r"[0-9a-fA-F]{64}", checksum):
            raise fail(f"Cargo.lock has an invalid checksum for {name}")
        checksums[(name, version, source)] = checksum.lower()
    return checksums


def cargo_components(
    repo_root: pathlib.Path, arguments: argparse.Namespace
) -> list[Component]:
    if arguments.cargo_metadata:
        documents = [
            load_json(
                require_file(parse_metadata_argument(raw), "Cargo metadata"),
                "Cargo metadata",
            )
            for raw in arguments.cargo_metadata
        ]
    else:
        documents = default_cargo_metadata(repo_root)
    lock_path = arguments.cargo_lock or repo_root / "Cargo.lock"
    lock_checksums = cargo_lock_checksums(require_file(lock_path, "Cargo.lock"))
    allow_metadata_checksum_fallback = explicit_fixture_inputs(arguments)
    components: dict[tuple[str, str, str, str], Component] = {}
    for document in documents:
        roles = cargo_dependency_roles(document)
        for package in document.get("packages", []):
            if not isinstance(package, dict):
                continue
            package_id = str(package.get("id") or "")
            if package_id not in roles or not package.get("source"):
                continue
            name = str(package.get("name") or "")
            version = str(package.get("version") or "")
            if not name or not version:
                raise fail("Cargo metadata contains a package without name or version")
            license_raw = str(package.get("license") or "").strip()
            license_file_raw = str(package.get("license_file") or "").strip()
            if not license_raw and not license_file_raw:
                raise fail(f"Cargo package {name} has no declared license")
            license_declared = normalize_cargo_license(license_raw)
            manifest = pathlib.Path(str(package.get("manifest_path") or ""))
            paths: list[pathlib.Path] = []
            if license_file_raw:
                license_path = pathlib.Path(license_file_raw)
                if not license_path.is_absolute() and manifest:
                    license_path = manifest.parent / license_path
                paths.append(require_file(license_path, f"Cargo license for {name}"))
            if manifest.is_file():
                paths.extend(path for path in notice_candidates(manifest.parent) if path not in paths)
            notices = tuple(
                Notice(path.name, read_text(path, f"Cargo notice for {name}"))
                for path in paths
            )
            if not license_declared:
                inferred = next(
                    (
                        infer_license_expression(notice.text, notice.label)
                        for notice in notices
                        if infer_license_expression(notice.text, notice.label)
                    ),
                    "",
                )
                if not inferred:
                    raise fail(f"Cargo package {name} license file is not identifiable")
                license_declared = inferred
            source = str(package.get("source") or "")
            metadata_checksum = str(package.get("checksum") or "").lower()
            if metadata_checksum and not re.fullmatch(
                r"[0-9a-fA-F]{64}", metadata_checksum
            ):
                raise fail(f"Cargo package {name} has an invalid metadata checksum")
            checksum = lock_checksums.get((name, version, source), "")
            if source.startswith("registry+"):
                if not checksum and allow_metadata_checksum_fallback:
                    checksum = metadata_checksum
                if not checksum:
                    raise fail(
                        f"registry Cargo package {name} {version} has no locked checksum"
                    )
                if metadata_checksum and metadata_checksum != checksum:
                    raise fail(
                        f"Cargo metadata checksum differs from Cargo.lock for {name}"
                    )
            repository = normalized_url(
                str(package.get("repository") or package.get("homepage") or "")
            )
            source_url = repository or f"https://crates.io/crates/{name}/{version}"
            license_concluded = license_declared
            copyright_text = copyright_text_from_notices(notices)
            if not notices:
                vetted, notices = vetted_notice_for_package(
                    repo_root,
                    name=name,
                    version=version,
                    repository=repository,
                    manifest_path=manifest,
                    license_declared=license_declared,
                )
                source_url = vetted.source_url
                license_concluded = vetted.license_concluded
                copyright_text = vetted.copyright_text
            component = Component(
                ecosystem="cargo",
                name=name,
                version=version,
                license_declared=license_declared,
                license_concluded=license_concluded,
                source_url=source_url,
                download_location=f"https://crates.io/api/v1/crates/{name}/{version}/download",
                relationship=roles[package_id],
                checksum=checksum,
                purl=f"pkg:cargo/{urllib.parse.quote(name)}@{urllib.parse.quote(version)}",
                copyright_text=copyright_text,
                summary=str(package.get("description") or ""),
                notices=notices,
            )
            existing = components.get(component.key)
            if existing is not None and existing.relationship == "DEPENDS_ON":
                component = dataclasses.replace(component, relationship="DEPENDS_ON")
            components[component.key] = component
    if not components:
        raise fail("Cargo metadata contains no release dependencies")
    return sorted(components.values(), key=lambda item: item.key)


def unquote_yaml_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def parse_pub_lock(path: pathlib.Path) -> dict[str, dict[str, str]]:
    lines = read_text(path, "pubspec.lock").splitlines()
    packages: dict[str, dict[str, str]] = {}
    in_packages = False
    current = ""
    for line in lines:
        if line == "packages:":
            in_packages = True
            continue
        if not in_packages:
            continue
        if line and not line.startswith(" "):
            break
        package_match = re.fullmatch(r"  ([A-Za-z0-9_+.-]+):", line)
        if package_match:
            current = package_match.group(1)
            packages[current] = {}
            continue
        if not current:
            continue
        field = re.fullmatch(
            r"    (dependency|source|version):\s*(.+)", line
        )
        if field:
            packages[current][field.group(1)] = unquote_yaml_scalar(field.group(2))
            continue
        checksum = re.fullmatch(r"      sha256:\s*(.+)", line)
        if checksum:
            packages[current]["sha256"] = unquote_yaml_scalar(checksum.group(1))
    if not packages:
        raise fail("pubspec.lock contains no packages")
    return packages


def package_config_roots(path: pathlib.Path) -> dict[str, pathlib.Path]:
    document = load_json(path, "Dart package_config")
    if document.get("configVersion") != 2:
        raise fail("Dart package_config must use configVersion 2")
    roots: dict[str, pathlib.Path] = {}
    for package in document.get("packages", []):
        if not isinstance(package, dict):
            continue
        name = str(package.get("name") or "")
        root_uri = str(package.get("rootUri") or "")
        if not name or not root_uri:
            continue
        parsed = urllib.parse.urlparse(root_uri)
        if parsed.scheme == "file":
            root = pathlib.Path(urllib.parse.unquote(parsed.path))
        elif parsed.scheme:
            continue
        else:
            root = (path.parent / urllib.parse.unquote(root_uri)).resolve()
        roots[name] = root
    return roots


def default_pub_dependency_graph(repo_root: pathlib.Path) -> set[str]:
    app_root = repo_root / "apps/client_flutter"
    document = run_json(
        ("dart", "pub", "deps", "--json", "-C", str(app_root)),
        repo_root,
        "Dart dependency graph",
    )
    packages = {
        str(package.get("name")): package
        for package in document.get("packages", [])
        if isinstance(package, dict) and package.get("name")
    }
    root_name = str(document.get("root") or "")
    root = packages.get(root_name, {})
    pending = [str(name) for name in root.get("directDependencies", [])]
    reachable: set[str] = set()
    while pending:
        name = pending.pop()
        if name in reachable:
            continue
        reachable.add(name)
        package = packages.get(name, {})
        pending.extend(str(item) for item in package.get("dependencies", []))
    return reachable


def dart_components(
    repo_root: pathlib.Path, arguments: argparse.Namespace
) -> list[Component]:
    default_lock = repo_root / "apps/client_flutter/pubspec.lock"
    default_config = repo_root / "apps/client_flutter/.dart_tool/package_config.json"
    lock_path = arguments.pub_lock or default_lock
    config_path = arguments.dart_package_config or default_config
    require_file(lock_path, "pubspec.lock")
    require_file(config_path, "Dart package_config")
    locked = parse_pub_lock(lock_path)
    roots = package_config_roots(config_path)
    using_defaults = (
        lock_path.resolve() == default_lock.resolve()
        and config_path.resolve() == default_config.resolve()
    )
    if using_defaults:
        selected = default_pub_dependency_graph(repo_root)
    else:
        selected = {
            name
            for name, values in locked.items()
            if values.get("dependency") != "direct dev"
        }
    components: list[Component] = []
    for name in sorted(selected):
        values = locked.get(name)
        if values is None:
            continue
        source = values.get("source", "")
        repository_relative = (
            REPOSITORY_DART_PATH_DEPENDENCIES.get(name)
            if source == "path"
            else None
        )
        if source == "sdk" or (source == "path" and repository_relative is None):
            continue
        version = values.get("version", "")
        if not version:
            raise fail(f"Dart package {name} has no locked version")
        root = roots.get(name)
        if root is None:
            raise fail(f"Dart package_config is missing {name}")
        if repository_relative is not None:
            expected_root = (repo_root / repository_relative).resolve()
            if root.resolve() != expected_root:
                raise fail(
                    f"Dart path package {name} must resolve to repository "
                    f"{repository_relative.as_posix()}"
                )
        paths = notice_candidates(
            root,
            recursive=repository_relative is not None,
            exact_relative_paths=(
                REPOSITORY_DART_NOTICE_EXACT_PATHS.get(name, frozenset())
                if repository_relative is not None
                else frozenset()
            ),
        )
        if not paths:
            raise fail(f"Dart package {name} has no LICENSE or NOTICE file")
        notices = tuple(
            Notice(
                (
                    path.relative_to(root).as_posix()
                    if repository_relative is not None
                    else path.name
                ),
                read_text(path, f"Dart notice for {name}"),
            )
            for path in paths
        )
        license_notice = next(
            (notice for notice in notices if notice.label.lower().startswith(("license", "copying"))),
            notices[0],
        )
        inferred = infer_license_expression(license_notice.text, license_notice.label)
        if inferred:
            license_declared = inferred
        else:
            license_declared = (
                f"LicenseRef-Pub-{re.sub(r'[^A-Za-z0-9.-]+', '-', name)}-"
                f"{sha256_text(license_notice.text)[:12]}"
            )
        if repository_relative is not None:
            discovered_licenses = [license_declared]
            for notice in notices:
                discovered = infer_license_expression(notice.text, notice.label)
                if discovered and discovered not in discovered_licenses:
                    discovered_licenses.append(discovered)
            license_declared = " AND ".join(discovered_licenses)
        elif name == "flutter_webrtc" and license_declared == "MIT":
            has_apache_notice = any(
                notice.label.lower().startswith("notice")
                and "apache license" in notice.text.lower()
                and "version 2.0" in notice.text.lower()
                for notice in notices
            )
            if has_apache_notice:
                license_declared = "MIT AND Apache-2.0"
        checksum = (
            "" if repository_relative is not None else values.get("sha256", "")
        )
        if checksum and not re.fullmatch(r"[0-9a-fA-F]{64}", checksum):
            raise fail(f"Dart package {name} has an invalid checksum")
        if repository_relative is not None:
            source_url = (
                f"{normalized_url(arguments.source_url).rstrip('/')}/tree/"
                f"{urllib.parse.quote(arguments.source_revision, safe='')}/"
                f"{urllib.parse.quote(repository_relative.as_posix(), safe='/')}"
            )
            ecosystem = "pub-path"
            download_location = "NOASSERTION"
            purl = ""
            summary = (
                "Repository-local modified Dart path dependency at "
                f"{repository_relative.as_posix()}; based on upstream {name} "
                f"{version}."
            )
        else:
            source_url = f"https://pub.dev/packages/{name}/versions/{version}"
            ecosystem = "pub"
            download_location = source_url
            purl = f"pkg:pub/{urllib.parse.quote(name)}@{urllib.parse.quote(version)}"
            summary = ""
        components.append(
            Component(
                ecosystem=ecosystem,
                name=name,
                version=version,
                license_declared=license_declared,
                license_concluded=license_declared,
                source_url=source_url,
                download_location=download_location,
                checksum=checksum,
                purl=purl,
                summary=summary,
                notices=notices,
            )
        )
    if not components:
        raise fail("Dart dependency inputs contain no release packages")
    return components


def parse_pod_lock(path: pathlib.Path) -> list[tuple[str, str, str]]:
    lines = read_text(path, "Podfile.lock").splitlines()
    in_pods = False
    in_checksums = False
    versions: dict[str, str] = {}
    checksums: dict[str, str] = {}
    for line in lines:
        if line == "PODS:":
            in_pods = True
            in_checksums = False
            continue
        if line == "SPEC CHECKSUMS:":
            in_pods = False
            in_checksums = True
            continue
        if line and not line.startswith(" "):
            in_pods = False
            in_checksums = False
        if in_pods:
            match = re.fullmatch(r"  - ([A-Za-z0-9_.+-]+) \(([^):]+)\):?", line)
            if match:
                versions.setdefault(match.group(1), match.group(2).strip())
        elif in_checksums:
            match = re.fullmatch(r"  ([A-Za-z0-9_.+-]+): ([0-9a-fA-F]+)", line)
            if match:
                checksums[match.group(1)] = match.group(2)
    if not versions:
        raise fail("Podfile.lock contains no pods")
    return [
        (name, version, checksums.get(name, ""))
        for name, version in sorted(versions.items())
    ]


def parse_pod_acknowledgements(path: pathlib.Path) -> dict[str, str]:
    text = read_text(path, "Pods-Runner-acknowledgements.markdown")
    matches = list(re.finditer(r"^## ([^\n]+)\n", text, flags=re.MULTILINE))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[match.end() : end].strip()
        body = re.sub(r"\nGenerated by CocoaPods.*\Z", "", body, flags=re.DOTALL).strip()
        if body:
            sections[match.group(1).strip()] = body + "\n"
    if not sections:
        raise fail("Pods acknowledgements contain no component sections")
    return sections


def pod_components(repo_root: pathlib.Path, arguments: argparse.Namespace) -> list[Component]:
    lock_path = arguments.pod_lock or repo_root / "apps/client_flutter/macos/Podfile.lock"
    acknowledgements_path = (
        arguments.pod_acknowledgements
        or repo_root
        / "apps/client_flutter/macos/Pods/Target Support Files/Pods-Runner"
        / "Pods-Runner-acknowledgements.markdown"
    )
    require_file(lock_path, "Podfile.lock")
    require_file(
        acknowledgements_path, "Pods-Runner-acknowledgements.markdown"
    )
    sections = parse_pod_acknowledgements(acknowledgements_path)
    components: list[Component] = []
    for name, version, checksum in parse_pod_lock(lock_path):
        if checksum and not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", checksum):
            raise fail(f"Podfile.lock has an invalid checksum for {name}")
        if name == "FlutterMacOS":
            notice = Notice(
                "Flutter bundled notices",
                "FlutterMacOS is covered by the Flutter Engine notices reproduced below.\n",
            )
            license_declared = "BSD-3-Clause"
            source_url = "https://github.com/flutter/engine"
        else:
            section = sections.get(name)
            if not section:
                raise fail(f"Pods acknowledgements are missing {name}")
            notice = Notice(f"{name} CocoaPods acknowledgement", section)
            license_declared = infer_license_expression(section, name)
            if not license_declared:
                license_declared = (
                    f"LicenseRef-Pod-{re.sub(r'[^A-Za-z0-9.-]+', '-', name)}-"
                    f"{sha256_text(section)[:12]}"
                )
            if name == "WebRTC-SDK":
                source_url = (
                    "https://cocoapods.org/pods/WebRTC-SDK"
                    f"?version={urllib.parse.quote(version)}"
                )
            elif name == "flutter_webrtc":
                source_url = "https://github.com/flutter-webrtc/flutter-webrtc"
            else:
                source_url = f"https://cocoapods.org/pods/{urllib.parse.quote(name)}"
        components.append(
            Component(
                ecosystem="cocoapods",
                name=name,
                version=version,
                license_declared=license_declared,
                license_concluded=license_declared,
                source_url=source_url,
                download_location=source_url,
                checksum=checksum,
                purl=f"pkg:cocoapods/{urllib.parse.quote(name)}@{urllib.parse.quote(version)}",
                notices=(notice,),
            )
        )
    return components


def native_notice_overrides(raw_values: Iterable[str]) -> dict[str, pathlib.Path]:
    overrides: dict[str, pathlib.Path] = {}
    for raw in raw_values:
        if "=" not in raw:
            raise fail("native notice override must use ARCH=PATH")
        architecture, path = raw.split("=", 1)
        normalized = {
            "arm64": "arm64",
            "aarch64": "arm64",
            "x86_64": "x86_64",
            "x64": "x86_64",
        }.get(architecture)
        if not normalized:
            raise fail(f"unsupported native notice architecture: {architecture}")
        overrides[normalized] = pathlib.Path(path)
    return overrides


def native_webrtc_components(
    package_dir: pathlib.Path, repo_root: pathlib.Path, arguments: argparse.Namespace
) -> tuple[list[Component], str]:
    manifest_path = (
        arguments.native_webrtc_manifest or repo_root / "scripts/libwebrtc-assets.sha256"
    )
    lines = read_text(manifest_path, "native WebRTC manifest").splitlines()
    entries: list[tuple[str, str, str, str]] = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3:
            raise fail("invalid native WebRTC manifest row")
        tag, asset, checksum = fields
        architecture = ""
        if asset == "webrtc-mac-arm64-release.zip":
            architecture = "arm64"
        elif asset == "webrtc-mac-x64-release.zip":
            architecture = "x86_64"
        if architecture:
            if not re.fullmatch(r"[0-9a-fA-F]{64}", checksum):
                raise fail(f"invalid native WebRTC checksum for {architecture}")
            entries.append((architecture, tag, asset, checksum))
    if {entry[0] for entry in entries} != {"arm64", "x86_64"}:
        raise fail("native WebRTC manifest must contain arm64 and x86_64 assets")
    tags = {entry[1] for entry in entries}
    if len(tags) != 1:
        raise fail("native WebRTC macOS assets must use one upstream tag")
    tag = next(iter(tags))
    overrides = native_notice_overrides(arguments.native_notice)
    components: list[Component] = []
    for architecture, _, asset, checksum in sorted(entries):
        notice_path = overrides.get(
            architecture,
            package_dir
            / LICENSE_RELATIVE_PATH
            / f"libwebrtc-macos-{architecture}-LICENSE.md",
        )
        text = read_text(notice_path, f"native WebRTC {architecture} notice")
        license_architecture = architecture.replace("_", "-")
        license_ref = (
            f"LicenseRef-LiveKit-WebRTC-{license_architecture}-"
            f"{sha256_text(text)[:12]}"
        )
        release_url = f"{NATIVE_WEBRTC_RELEASE_URL}/{urllib.parse.quote(tag)}"
        components.append(
            Component(
                ecosystem="native",
                name=f"LiveKit WebRTC binary ({architecture})",
                version=tag,
                license_declared=license_ref,
                license_concluded=license_ref,
                source_url=release_url,
                download_location=f"{release_url}/{asset}",
                checksum=checksum,
                purl=f"pkg:generic/livekit-webrtc@{urllib.parse.quote(tag)}?arch={architecture}",
                summary=(
                    "Pinned native WebRTC archive statically linked into the "
                    f"Roammand Rust agents for {architecture}."
                ),
                notices=(Notice(f"Native WebRTC {architecture} notices", text),),
            )
        )
    return components, tag


def bip39_component(
    package_dir: pathlib.Path,
    assets_root: pathlib.Path,
    repo_root: pathlib.Path,
    arguments: argparse.Namespace,
) -> Component:
    packaged_wordlist = require_file(
        assets_root / "assets/bip39-english.txt", "packaged BIP-39 word list"
    )
    canonical_wordlist = repo_root / "conformance/wordlists/bip39-english.txt"
    if canonical_wordlist.is_file() and sha256_file(packaged_wordlist) != sha256_file(
        canonical_wordlist
    ):
        if arguments.bip39_notice is None:
            raise fail("packaged BIP-39 word list differs from the reviewed source")
    notice_path = (
        arguments.bip39_notice or repo_root / "conformance/wordlists/NOTICE.md"
    )
    notice_text = read_text(notice_path, "BIP-39 notice")
    if "MIT" not in notice_text or "bitcoin/bips" not in notice_text:
        raise fail("BIP-39 notice is missing its MIT license or upstream source")
    mit_text = read_text(repo_root / "licenses/MIT.txt", "MIT license")
    checksum = sha256_file(packaged_wordlist)
    return Component(
        ecosystem="asset",
        name="BIP-39 English word list",
        version=f"sha256:{checksum[:12]}",
        license_declared="MIT",
        license_concluded="MIT",
        source_url=(
            "https://github.com/bitcoin/bips/blob/"
            "ce1862ac6bcffa1dd20aad858380e51e66e949ea/"
            "bip-0039/english.txt"
        ),
        download_location=(
            "https://raw.githubusercontent.com/bitcoin/bips/"
            "ce1862ac6bcffa1dd20aad858380e51e66e949ea/"
            "bip-0039/english.txt"
        ),
        checksum=checksum,
        purl="pkg:generic/bip39-english-wordlist",
        notices=(
            Notice("BIP-39 word-list attribution", notice_text),
            Notice("MIT License", mit_text),
        ),
    )


def material_icons_component(
    assets_root: pathlib.Path,
    metadata: FlutterMetadata,
    arguments: argparse.Namespace,
) -> Component | None:
    font_path = assets_root / "fonts/MaterialIcons-Regular.otf"
    if not font_path.is_file():
        return None
    license_path = arguments.material_icons_license
    if license_path is None and metadata.flutter_root is not None:
        license_path = (
            metadata.flutter_root
            / "bin/cache/artifacts/material_fonts/MaterialIcons_LICENSE.txt"
        )
    if license_path is None:
        raise fail("Material Icons font is shipped but its license input is missing")
    text = read_text(license_path, "Material Icons license")
    if infer_license_expression(text, license_path.name) != "CC-BY-4.0":
        raise fail("Material Icons license input is not CC-BY-4.0")
    checksum = sha256_file(font_path)
    notice_text = (
        "Material Icons\n"
        "Copyright Google LLC\n"
        "Source: https://github.com/google/material-design-icons\n\n"
        "The file shipped in this package is the Flutter-generated, tree-shaken "
        "subset used by Roammand. The following CC BY 4.0 text applies:\n\n"
        f"{text}"
    )
    return Component(
        ecosystem="asset",
        name="Material Icons font subset",
        version=f"Flutter {metadata.version}",
        license_declared="CC-BY-4.0",
        license_concluded="CC-BY-4.0",
        source_url="https://github.com/google/material-design-icons",
        download_location="https://github.com/google/material-design-icons",
        checksum=checksum,
        purl="pkg:generic/material-icons",
        summary="Flutter-generated subset of MaterialIcons-Regular.otf.",
        copyright_text="Copyright Google LLC",
        notices=(Notice("Material Icons attribution and CC BY 4.0", notice_text),),
    )


def flutter_components(
    metadata: FlutterMetadata, notices_text: str
) -> list[Component]:
    framework_source = (
        f"https://github.com/flutter/flutter/tree/{metadata.framework_revision}"
        if metadata.framework_revision
        else "https://github.com/flutter/flutter"
    )
    engine_source = (
        f"https://github.com/flutter/engine/tree/{metadata.engine_revision}"
    )
    return [
        Component(
            ecosystem="flutter",
            name="Flutter SDK",
            version=metadata.version,
            license_declared="BSD-3-Clause",
            license_concluded="BSD-3-Clause",
            source_url=framework_source,
            download_location=framework_source,
            purl=f"pkg:generic/flutter@{urllib.parse.quote(metadata.version)}",
            notices=(
                Notice(
                    "Flutter-generated dependency notices",
                    notices_text,
                ),
            ),
        ),
        Component(
            ecosystem="flutter",
            name="Flutter Engine",
            version=metadata.engine_revision,
            license_declared="BSD-3-Clause",
            license_concluded="BSD-3-Clause",
            source_url=engine_source,
            download_location=engine_source,
            purl=(
                "pkg:github/flutter/engine@"
                f"{urllib.parse.quote(metadata.engine_revision)}"
            ),
            summary=(
                f"Flutter {metadata.version}; Dart {metadata.dart_version or 'unknown'}."
            ),
        ),
    ]


def brand_component(
    assets_root: pathlib.Path, copyright_holder: str, source_url: str
) -> Component | None:
    paths = sorted((assets_root / "assets/brand").glob("*"))
    windows_icon = assets_root / "windows/runner/resources/app_icon.ico"
    if windows_icon.is_file():
        paths.append(windows_icon)
    paths = [path for path in paths if path.is_file()]
    if not paths:
        return None
    checksums = "\n".join(
        f"{sha256_file(path)}  {path.relative_to(assets_root).as_posix()}"
        for path in sorted(paths)
    )
    combined = sha256_text(checksums + "\n")
    text = (
        f"Copyright © {copyright_holder}. All rights reserved.\n\n"
        "These original Roammand visual brand assets are authorized for use in "
        "official Roammand source and binary distributions. Their inclusion does "
        "not grant a standalone trademark right or a separate open-source asset "
        "license. See the repository brand guide for permitted-use boundaries.\n"
    )
    license_ref = f"LicenseRef-Roammand-Brand-Assets-{sha256_text(text)[:12]}"
    return Component(
        ecosystem="project-asset",
        name="Roammand visual brand assets",
        version=f"aggregate-sha256:{combined[:12]}",
        license_declared=license_ref,
        license_concluded=license_ref,
        source_url=f"{source_url.rstrip('/')}/brand",
        download_location="NOASSERTION",
        copyright_text=f"Copyright © {copyright_holder}",
        summary=(
            "Aggregate SHA-256 over sorted brand-asset path/hash records: "
            f"{combined}. This inventory digest is not an individual file checksum."
        ),
        notices=(Notice("Roammand brand asset terms", text),),
    )


def merge_components(components: Iterable[Component]) -> list[Component]:
    merged: dict[tuple[str, str, str, str], Component] = {}
    for component in components:
        existing = merged.get(component.key)
        if existing is None:
            merged[component.key] = component
            continue
        notices = {
            (notice.label, sha256_text(notice.text)): notice
            for notice in (*existing.notices, *component.notices)
        }
        merged[component.key] = dataclasses.replace(
            existing,
            relationship=(
                "DEPENDS_ON"
                if "DEPENDS_ON" in {existing.relationship, component.relationship}
                else existing.relationship
            ),
            notices=tuple(
                value for _, value in sorted(notices.items(), key=lambda item: item[0])
            ),
        )
    return sorted(merged.values(), key=lambda item: item.key)
