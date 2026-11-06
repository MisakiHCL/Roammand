<!-- SPDX-License-Identifier: Apache-2.0 -->

# Roammand downstream patch

This directory vendors `webrtc-sys-build` 0.3.14 from the published crates.io
archive. It is a build dependency of the pinned `webrtc-sys` 0.3.25 bindings.

- Upstream project: <https://github.com/livekit/rust-sdks>
- Upstream revision: `20e442edab8e91f399ca62e0f5d811ed0002a4b2`
- Upstream source directory: `webrtc-sys/build`
- Original crate archive SHA-256:
  `b553c88516e5a794d844e822ef90f2a20cc6503a79dfb636321cc4db7789fe60`

The checksum identifies the unmodified upstream archive, not this modified
downstream tree. `Cargo.toml.orig`, `CHANGELOG.md`, and `.cargo_vcs_info.json`
retain upstream metadata. `LICENSE`, `NOTICE`, and `NOTICE.md` preserve the
applicable upstream license and attribution files already vetted for this
revision by the repository's release compliance tooling.

The downstream manifest expands upstream workspace-inherited package settings
and dependencies for this repository, disables publication, and adds the
extraction regression test dependency. The source is formatted with `rustfmt`
so the workspace's normal formatting gate covers it alongside the application.
The download URL uses one formatting call, and temporary archive files are
explicitly truncated before a fresh download so a shorter response cannot
leave bytes from an earlier archive at the end of the file. These narrow
changes also allow the helper to pass the workspace's Clippy gate.

## ZIP extraction security update

The downstream manifest selects `zip` 9.0.5 to fix
[GHSA-m665-v7pm-7grj](https://github.com/advisories/GHSA-m665-v7pm-7grj) and
[GHSA-8hxf-qr8p-62x4](https://github.com/advisories/GHSA-8hxf-qr8p-62x4).
Only DEFLATE support is enabled, using the same
`deflate-flate2-zlib-rs` feature selected by upstream build-helper releases
0.3.20 and 0.3.21. AES and unrelated compression formats are unnecessary for
the pinned native library archives.

The extractor explicitly validates local and central ZIP header consistency
before extracting any files. This enables the fixed crate's opt-in protection
against dual-header filename discrepancies. Regression tests exercise valid
DEFLATE extraction, rejection of inconsistent filenames before writes, and
protection of files outside the extraction destination.

The public helper API and `WEBRTC_TAG = "webrtc-24f6822-2"` remain unchanged.
Updating the helper to upstream 0.3.20 or 0.3.21 would change its default native
archive tag independently of the pinned bindings. This focused patch avoids
that ABI mismatch and preserves the repository's checked native archive
digests. Package publication is disabled; the package version continues to
identify its upstream source version and the root Cargo patch selects this
documented downstream tree.

When upgrading the native bindings and their archive set together, reevaluate
whether this downstream package is still needed.
