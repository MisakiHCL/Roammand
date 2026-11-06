#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Contract tests for exact Cargo notice fallbacks."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import sys
import tempfile
from collections.abc import Callable
from unittest import mock

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from macos_release_compliance.collectors import (  # noqa: E402
    cargo_components,
    copyright_text_from_notices,
)
from macos_release_compliance.model import (  # noqa: E402
    ComplianceError,
    Notice,
    validated_source_input_digests,
)
from macos_release_compliance.render import spdx_package  # noqa: E402
from macos_release_compliance.vetted_cargo_notices import (  # noqa: E402
    vetted_identities,
    vetted_notice_for_package,
)

BLOCK2_REVISION = "b4167b582b2f75f9a1be75495c41b765344fd03c"
BLOCK2_REPOSITORY = "https://github.com/madsmtm/objc2"


def expect_failure(expected: str, action: Callable[[], object]) -> None:
    try:
        action()
    except ComplianceError as error:
        if expected not in str(error):
            raise AssertionError(
                f"expected failure containing {expected!r}, got {error!r}"
            ) from error
    else:
        raise AssertionError(f"expected failure containing {expected!r}")


def write_vcs_revision(package_root: pathlib.Path, revision: str) -> None:
    (package_root / ".cargo_vcs_info.json").write_text(
        json.dumps({"git": {"sha1": revision}, "path_in_vcs": "crates/block2"}),
        encoding="utf-8",
    )


def check_repository_cargo_path_dependency() -> None:
    with tempfile.TemporaryDirectory(prefix="roammand-cargo-path-") as raw_temp:
        root = pathlib.Path(raw_temp)
        package_root = root / "third_party/webrtc-sys-build"
        package_root.mkdir(parents=True)
        manifest = package_root / "Cargo.toml"
        manifest.write_text("[package]\nname='webrtc-sys-build'\nversion='0.3.14'\n")
        for name in ("LICENSE", "NOTICE", "NOTICE.md", "DOWNSTREAM_PATCH.md"):
            (package_root / name).write_text(f"{name}\nApache-2.0\n")
        lock_path = root / "Cargo.lock"
        lock_path.write_text(
            'version = 4\n[[package]]\nname = "webrtc-sys-build"\nversion = "0.3.14"\n'
        )
        package_id = "path+file:///fixture/webrtc-sys-build#0.3.14"
        metadata_path = root / "cargo-metadata.json"
        metadata = {
            "packages": [
                {"id": "host", "name": "roammand-host-agent"},
                {
                    "id": package_id,
                    "name": "webrtc-sys-build",
                    "version": "0.3.14",
                    "source": None,
                    "license": "Apache-2.0",
                    "repository": "https://github.com/livekit/rust-sdks",
                    "manifest_path": str(manifest),
                },
            ],
            "resolve": {
                "nodes": [
                    {
                        "id": "host",
                        "deps": [
                            {"pkg": package_id, "dep_kinds": [{"kind": "build"}]}
                        ],
                    },
                    {"id": package_id, "deps": []},
                ]
            },
        }
        metadata_path.write_text(json.dumps(metadata))
        arguments = argparse.Namespace(
            cargo_metadata=[str(metadata_path)],
            cargo_lock=lock_path,
            source_url="https://github.com/example/project/tree/release-1",
            source_revision="a" * 40,
        )
        components = cargo_components(root, arguments)
        assert len(components) == 1
        component = components[0]
        assert component.name == "webrtc-sys-build"
        assert component.ecosystem == "cargo-path"
        assert component.relationship == "BUILD_DEPENDENCY_OF"
        assert component.source_url == (
            "https://github.com/example/project/tree/release-1/"
            "third_party/webrtc-sys-build"
        )
        assert component.download_location == "NOASSERTION"
        assert component.checksum == component.purl == ""
        rendered = spdx_package(component)
        assert "checksums" not in rendered and "externalRefs" not in rendered
        assert {notice.label for notice in component.notices} == {
            "LICENSE", "NOTICE", "NOTICE.md", "DOWNSTREAM_PATCH.md"
        }
        assert "Repository-local modified Cargo path dependency" in component.summary

        arguments.source_url = "https://github.com/example/project"
        assert cargo_components(root, arguments)[0].source_url == (
            f"https://github.com/example/project/tree/{'a' * 40}/"
            "third_party/webrtc-sys-build"
        )

        (package_root / "NOTICE.md").unlink()
        expect_failure("Cargo path notice", lambda: cargo_components(root, arguments))
        (package_root / "NOTICE.md").write_text("Apache-2.0\n")
        metadata["packages"][1]["manifest_path"] = str(root / "wrong/Cargo.toml")
        metadata_path.write_text(json.dumps(metadata))
        expect_failure("must resolve to repository", lambda: cargo_components(root, arguments))

        source_file = package_root / "src/lib.rs"
        source_file.parent.mkdir()
        source_file.write_text("// vendored source\n")
        for relative in (
            "Cargo.toml",
            "apps/client_flutter/pubspec.yaml",
            "apps/client_flutter/pubspec.lock",
            "apps/client_flutter/macos/Podfile",
            "apps/client_flutter/macos/Podfile.lock",
            "scripts/libwebrtc-assets.sha256",
            "conformance/wordlists/bip39-english.txt",
            "third_party/flutter_webrtc/LICENSE",
        ):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture\n")
        source_snapshot = {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file() and path != metadata_path
        }

        def fixture_git_output(
            _root: pathlib.Path,
            command: tuple[str, ...],
            _label: str,
            *,
            text: bool,
        ) -> str | bytes:
            if command[0] in {"ls-tree", "ls-files"}:
                assert text
                return "\n".join(sorted(source_snapshot)) + "\n"
            assert command[0] == "show" and not text
            return source_snapshot[command[1].split(":", 1)[1]]

        with mock.patch(
            "macos_release_compliance.model.git_output", side_effect=fixture_git_output
        ):
            source_arguments = argparse.Namespace(source_revision="a" * 40)
            digests = validated_source_input_digests(root, source_arguments)
            assert "third_party/webrtc-sys-build/**" in digests
            source_file.write_text("// modified after release revision\n")
            expect_failure(
                "source input does not match revision: third_party/webrtc-sys-build/src/lib.rs",
                lambda: validated_source_input_digests(root, source_arguments),
            )


def main() -> None:
    check_repository_cargo_path_dependency()
    identities = vetted_identities()
    assert len(identities) == 23
    assert len(set(identities)) == len(identities)
    assert (
        copyright_text_from_notices(
            (
                Notice(
                    "Apache template",
                    "copyright notice that is included in the work\n"
                    "Copyright [yyyy] [name of copyright owner]\n",
                ),
            )
        )
        == "NOASSERTION"
    )
    assert (
        copyright_text_from_notices(
            (Notice("MIT", "Copyright (c) 2020 Example Authors\n"),)
        )
        == "Copyright (c) 2020 Example Authors"
    )

    with tempfile.TemporaryDirectory(prefix="roammand-vetted-cargo-") as raw_temp:
        root = pathlib.Path(raw_temp)
        package_root = root / "cargo-cache/block2-0.6.2"
        package_root.mkdir(parents=True)
        manifest = package_root / "Cargo.toml"
        manifest.write_text("[package]\nname='block2'\nversion='0.6.2'\n")
        write_vcs_revision(package_root, BLOCK2_REVISION)

        for relative_path in (
            "scripts/macos_release_compliance/vetted_notices/objc2-LICENSE.md",
            "licenses/MIT.txt",
        ):
            source = REPO_ROOT / relative_path
            destination = root / relative_path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)

        entry, notices = vetted_notice_for_package(
            root,
            name="block2",
            version="0.6.2",
            repository=BLOCK2_REPOSITORY,
            manifest_path=manifest,
            license_declared="MIT",
        )
        assert entry.license_concluded == "MIT"
        assert entry.copyright_text == "NOASSERTION"
        assert entry.source_url.endswith(BLOCK2_REVISION)
        assert len(notices) == 2

        write_vcs_revision(package_root, "a" * 40)
        expect_failure(
            "no exact vetted fallback",
            lambda: vetted_notice_for_package(
                root,
                name="block2",
                version="0.6.2",
                repository=BLOCK2_REPOSITORY,
                manifest_path=manifest,
                license_declared="MIT",
            ),
        )

        write_vcs_revision(package_root, BLOCK2_REVISION)
        expect_failure(
            "no exact vetted fallback",
            lambda: vetted_notice_for_package(
                root,
                name="block2",
                version="0.6.3",
                repository=BLOCK2_REPOSITORY,
                manifest_path=manifest,
                license_declared="MIT",
            ),
        )

        expect_failure(
            "no exact vetted fallback",
            lambda: vetted_notice_for_package(
                root,
                name="unknown-crate",
                version="1.0.0",
                repository="https://example.test/unknown-crate",
                manifest_path=manifest,
                license_declared="MIT",
            ),
        )

        (root / "licenses/MIT.txt").write_text("tampered\n", encoding="utf-8")
        expect_failure(
            "vetted notice content has changed",
            lambda: vetted_notice_for_package(
                root,
                name="block2",
                version="0.6.2",
                repository=BLOCK2_REPOSITORY,
                manifest_path=manifest,
                license_declared="MIT",
            ),
        )

    print("vetted Cargo notice contract ok")


if __name__ == "__main__":
    main()
