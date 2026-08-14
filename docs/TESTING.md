<!-- SPDX-License-Identifier: Apache-2.0 -->

# Testing and verification

**English** · [简体中文](TESTING.zh-CN.md)

Roammand uses deterministic automated gates for repository changes and focused
target-system checks for behavior that depends on real devices, networks,
permissions, installers, or protected operating-system desktops. Public
documentation defines the expected behavior; release sign-off records and real
environment evidence are maintained outside the public repository.

## Automated gates

Run the complete repository gate from the repository root:

```bash
make test-product
```

Use the narrower commands while iterating:

| Area | Command | Coverage |
| --- | --- | --- |
| Formatting and source contracts | `make format-check` | Rust, Go, Dart, generated sources, and repository policy |
| Protocol and native services | `make test` | Schema compatibility, signaling, identity, IPC, pairing, WebRTC, reconnect, bridge, privacy, and package contracts |
| Flutter product | `make app-check` | Localization generation, formatting, analysis, and widget/unit tests |
| Protocol generation | `make generate-check` and `make test-conformance` | Reproducible generated code and cross-language cryptographic vectors |
| Platform builds | `make app-build-macos`, `make app-build-ios-simulator`, `make app-build-android` | Build integration for supported source targets |
| Installed macOS package | `make package-macos` | Package allowlist, manifest, compliance records, and install/uninstall dry-run contracts |

Automated success is not evidence that screen capture, input injection, camera
access, NAT traversal, protected desktops, or an installer works on a particular
physical system.

## Target-system matrix

| Area | Minimum physical verification |
| --- | --- |
| macOS Host | macOS 14.4+ installation, Screen Recording and Accessibility readiness, capture, input, tray visibility, local Stop, lock/LoginWindow transition, and complete removal |
| Windows Host | Windows 11 installation, service readiness, capture, input, local Stop, lock/UAC/Winlogon behavior, SendSAS policy boundary, and removal behavior |
| Desktop Controller | macOS-to-Windows and Windows-to-macOS authenticated video/input, explicit close, grant revocation, and repeated cleanup |
| iOS/iPadOS Controller | Camera pairing, both landscape directions, gestures, keyboard, safe areas, background release, explicit reconnect, and Host-local Stop |
| Android Controller | Camera pairing, portrait/landscape, gestures, keyboard, safe areas, background release, explicit reconnect, and Host-local Stop |
| Networks | Same-LAN direct ICE and separate-public-network STUN-assisted direct ICE; restrictive paths must fail clearly because the official profile has no TURN fallback |
| Recovery | Signaling and network interruption, fresh authenticated reconnect, bounded retry, input release, process failure, and repeated connect/close cycles |
| Privacy | Diagnostics preview/export, bounded resource observation, redacted logs, untrusted-frame rejection, and self-hosted service limits |

Use installed packages for lock, login, UAC, Winlogon, LoginWindow, service, and
uninstall checks. A source run reporting `user_session_only`, a simulator,
cross-compilation, or a package dry run cannot substitute for those checks.

## Pairing and authorization

- QR pairing accepts only a live camera scan and handles camera denial cleanly.
- Desktop codes expire within 120 seconds and do not grant access by themselves.
- Both desktops show the same four English verification words.
- The Host creates a one-way permanent grant only after local approval.
- A saved Host reconnects without pairing again; Host-side revocation blocks
  later sessions, while Controller-side deletion remains local.
- Device identity survives an ordinary restart in platform-protected storage
  and is not restored onto another mobile device through cloud backup.

## Session and lifecycle

- Verify video, pointer, click, drag, scroll, text, modifiers, and special keys.
- Confirm that permission loss, backgrounding, route changes, reconnect, local
  Stop, Emergency stop, revocation, and process failure release held input.
- Repeat connect, protected-desktop transition, unlock, and disconnect cycles;
  watch for stuck input, duplicate indicators, stale sessions, and steadily
  growing process or resource counts.
- Debug-only private-LAN `ws://` is development evidence only. Cross-network
  release verification uses WSS and the configured public STUN service.
- Optional developer-operated TURN tests validate the lower-level relay path;
  they do not imply that the official service profile provides TURN.

## Evidence hygiene

Record only the operating-system version, device class, package version, coarse
network scenario, date, and result needed for internal sign-off. Use synthetic
names and endpoints. Never retain pairing codes, device identities, credentials,
private keys, SDP/ICE, exact network topology, input, screen content, session
transcripts, raw payloads, or unredacted diagnostics in test evidence.

Architecture-specific invariants are documented in the
[architecture guide](architecture/README.md), and diagnostic limits are defined
by [Privacy-safe diagnostics](security/privacy-safe-diagnostics.md).
