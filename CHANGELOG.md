<!-- SPDX-License-Identifier: Apache-2.0 -->

# Changelog

**English** · [简体中文](CHANGELOG.zh-CN.md)

All notable user-facing, compatibility, security, operations, and packaging
changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and released versions follow semantic versioning.

## [Unreleased]

## [1.0.3] - 2026-08-14

### Changed

- Raised the iOS and iPadOS minimum deployment target from 13.0 to 15.0 for
  App Store Connect compatibility beginning in spring 2027.
- Consolidated public verification guidance, separated current official-service
  facts from maintainer readiness procedures, and exposed stable platform
  packaging script names instead of milestone-oriented names.

### Fixed

- Associated the packaged macOS LaunchAgent and LaunchDaemon with the main
  Roammand app so System Settings shows the product name and icon instead of
  grouping background items under the Developer ID certificate holder.
- Serialized QR scanner lifecycle commands so a camera permission request that
  completes after iOS backgrounds the app is immediately paused and cannot be
  resumed by a stale foreground event.
- Replaced the hosted `flutter_webrtc` package with a reproducible,
  repository-local 1.5.2 downstream patch that removes an unused private
  ReplayKit selector from iOS and macOS builds, and added a release scanner
  that rejects affected iOS artifacts before distribution.

Version 1.0.3 supersedes 1.0.2. The published macOS artifact is a Developer
ID-signed, Apple-notarized, stapled package for macOS 14.4 or later.

## [1.0.2] - 2026-07-21

### Added

- Added weekly dependency update coverage for Rust, Go, Dart/Flutter,
  containers, and GitHub Actions, plus pull-request dependency review.
- Added bilingual changelogs and expanded contributor, security, architecture,
  operations, build, self-hosting, and user documentation.

### Changed

- Bounded signaling connection and rendezvous counts, inbound traffic,
  pairing-limiter state, queued entries, and outbound bytes at the applicable
  process, source-address, Host, lookup, and connection scopes.
- Made signaling heartbeat liveness single-flight with correlated
  acknowledgements across Host, pairing, and Controller-session links; bounded
  client connection/shutdown work and Host WebSocket I/O.
- Reworked macOS permission refresh into a bounded backoff flow and hardened
  installed-package integrity checks.
- Made CI dependency resolution reproducible with enforced Pub lockfiles,
  locked Cargo operations, read-only Go modules, and clean-tree checks.

### Security

- Pinned third-party CI actions and container base images to immutable commits
  or digests, and restricted the Docker build context to the two required Go
  source trees.
- Added fixed inbound traffic and memory-state budgets, bounded shutdown and
  WebSocket work, stricter trusted-proxy parsing, and TLS 1.2 minimums to the
  signaling service.
- Hardened local caches and exports with byte limits, corrupt-record handling,
  symlink rejection, exclusive destinations, secret zeroization, and explicit
  Android cloud/device-transfer exclusions.

### Fixed

- Closed stale asynchronous IPC, pairing, signaling, renderer, data-channel, and
  peer work without allowing it to publish after its owner was disposed.
- Preserved authenticated ICE recovery across answer/candidate races and made
  shutdown continue when one native cleanup operation fails.
- Closed mobile control on backgrounding, returned to the previous page after
  resume, and shielded iOS task-switcher snapshots.
- Stabilized mobile control locking, safe-area placement, and keyboard dismissal.
- Replaced the unpublished iOS App Store link with the source-build guide and
  corrected the QR pairing instructions in the in-app About page.
- Prevented concurrent diagnostics exports from selecting and overwriting the
  same destination file.
- Kept valid heartbeat acknowledgements correlated under heavy pairing relay
  traffic instead of evicting the pending request from bounded history.

Version 1.0.2 supersedes 1.0.1. The published macOS artifact is a
Developer ID-signed, Apple-notarized, stapled package for macOS 14.4 or later.

## [1.0.1] - 2026-07-19

### Added

- Added in-app project, installation, and companion-device guidance.
- Added a control-lock mode for a more immersive mobile remote viewport.

### Changed

- Persisted the iOS export-compliance declaration used by archive distribution.
- Refined macOS companion setup and Settings presentation.

### Fixed

- Kept the macOS protected-session control indicator non-activating and made its
  local Stop interaction more reliable.
- Corrected Settings hover shape and removed an unwanted menu tooltip.

Version 1.0.1 supersedes 1.0.0. The published artifact is a Developer ID-signed,
Apple-notarized, stapled macOS package for macOS 14.4 or later.

## [1.0.0] - 2026-07-19

### Added

- First public source release of account-free QR and desktop-code pairing with
  Host-local approval and persistent one-way grants.
- Authenticated WebRTC screen/control sessions, bounded reconnect, local Stop,
  grant revocation, and privacy-safe diagnostics.
- Source implementations for Windows/macOS Host and Controller roles plus
  iOS/Android Controller roles.
- Self-hostable in-memory signaling and STUN-only Docker Compose profile.
- Signed, notarized, and stapled macOS 14.4+ installer package.

This release contains known issues and is retained only for version history. Do
not install it; use 1.0.1 or a later release.

[Unreleased]: https://github.com/MisakiHCL/roammand/compare/v1.0.3...HEAD
[1.0.3]: https://github.com/MisakiHCL/roammand/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/MisakiHCL/roammand/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/MisakiHCL/roammand/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MisakiHCL/roammand/releases/tag/v1.0.0
