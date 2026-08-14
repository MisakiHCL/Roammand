<!-- SPDX-License-Identifier: Apache-2.0 -->

# Building Roammand from source

**English** · [简体中文](BUILDING.zh-CN.md)

This guide covers the supported path for running, verifying, building, and packaging Roammand.

## Product workflow

Run `make help` at the repository root to see the common commands.

| Goal | Command |
| --- | --- |
| Check tools and resolve dependencies | `make bootstrap` |
| Analyze and test the Flutter app | `make app-check` |
| Build the Debug Host and run the macOS app | `make app-run-macos` |
| Run a selected iOS target | `make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID` |
| Run iOS with production performance | `make app-run-ios-release IOS_DEVICE=YOUR_IOS_DEVICE_ID` |
| Build the macOS Release app | `make app-build-macos` |
| Build the iOS Simulator app | `make app-build-ios-simulator` |
| Build the Android Debug APK | `make app-build-android` |
| Build and verify the macOS Host package | `make package-macos` |
| Create a Developer ID-signed macOS `.pkg` | `make package-macos-signed` |
| Notarize and staple the macOS `.pkg` | `make release-macos` |
| Run the complete product gate | `make test-product` |

`make bootstrap`, `make app-check`, and `make test-product` hide successful tool output and print one final `[PASS]` line. Failures include the last 40 log lines, the retained full-log path, and a command for enabling complete output. Add `VERBOSE=1` when you need to stream every command, for example `make test-product VERBOSE=1`.

Normal app use selects signaling and STUN from **Network services** and can
restore the built-in official profile. Build definitions remain useful as
development and CI defaults; pass them through `FLUTTER_ARGS`:

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect --dart-define=ROAMMAND_STUN_URLS=stun:stun.example.com:3478'
```

## Required tools

The repository pins the versions used for generated files and automated checks.

| Tool | Version |
| --- | --- |
| Flutter | 3.44.0 |
| Go | 1.26.5 |
| Rust | 1.97.0 |
| Buf | 1.69.0 |

Also install Git, Make, Protocol Buffers, and ripgrep. Native desktop WebRTC requires `curl`, `unzip`, and the platform C/C++ toolchain.

On macOS, install Xcode command-line tools and CocoaPods. On Windows, install Visual Studio 2022 with **Desktop development with C++**, a supported Windows SDK, CMake, Ninja, and Git for Windows. Confirm the intended targets with:

```bash
flutter doctor -v
make doctor
```

## Resolve the workspace

From the repository root:

```bash
make bootstrap
```

This checks the pinned toolchain and resolves Flutter, Dart, Rust, and Go dependencies. It does not install system packages or developer credentials.

## Run Roammand locally

### Recommended: use the official services

On macOS, run only:

```bash
make app-run-macos
```

This target downloads or reuses verified native WebRTC, incrementally builds
the Debug Host Agent, and passes it to the GUI through
`ROAMMAND_HOST_AGENT_EXECUTABLE`. Official signaling and STUN are built in, so
there is no local service terminal. When a local Apple Team configuration and
a matching—or the sole available—Apple Development identity are available, the
target also applies a stable signature to the Debug Agent. A sole identity from
a different Team is used only for this local Debug binary and produces a
warning; distribution signing remains separate. On the first signed launch,
choose **Always Allow** in the Keychain prompt; later Agent rebuilds signed by
the same identity should not prompt again. Without a development identity,
macOS can ask again after each rebuilt ad-hoc binary.

When a phone is the Controller, use a second terminal for:

```bash
cd apps/client_flutter
flutter devices
flutter run -d YOUR_IOS_DEVICE_ID --no-pub
# Or: flutter run -d YOUR_ANDROID_DEVICE_ID --no-pub
```

`-d` takes an exact ID from `flutter devices`. Do not pass the platform name
`ios` or `android` when selecting a physical device. From the repository root,
the equivalent iOS command is
`make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID`.

The normal run is a Debug build and is intended for hot reload, not performance
measurement. Validate keyboard, animation, and frame timing on the physical
device with
`make app-run-ios-release IOS_DEVICE=YOUR_IOS_DEVICE_ID`.

This path needs only the desktop and mobile app processes; it does not require a
local signaling terminal. Installed desktop and mobile Release builds launch
from their graphical interfaces and need no terminal. Re-run `make bootstrap`
after dependency files change; normal run targets intentionally use the locked,
cached packages.

### Advanced: start local signaling

For a same-computer loopback run:

```bash
cd services/signaling
go run ./cmd/signaling
```

The default session endpoint is `ws://127.0.0.1:8080/v1/connect`.

Signaling accepts at most 1,024 concurrent WebSocket connections, 64 from one
source IP, 4,096 active pairing rendezvous globally, and four active rendezvous
per Host by default. Operators can tune these bounded limits with
`SIGNALING_MAX_CONNECTIONS` (1–65,536),
`SIGNALING_MAX_CONNECTIONS_PER_IP` (1–65,536),
`SIGNALING_MAX_RENDEZVOUS` (1–65,536), and
`SIGNALING_MAX_RENDEZVOUS_PER_HOST` (1–64). Set explicit values appropriate for
the host's memory, expected NAT fan-out, and traffic instead of relying on an
unbounded deployment. `SIGNALING_SHUTDOWN_TIMEOUT` defaults to 10 seconds and
must be greater than zero and no longer than one minute.

Outbound delivery also has fixed byte budgets in addition to the 64-entry
buffered queue: 64 MiB process-wide, 4 MiB per source IP, and 526,336 bytes per
connection (two maximum-sized signaling frames). The service reserves all
three budgets before copying a frame into a queue and keeps the reservation
while the frame is being written. These built-in safety budgets are not
environment-variable tunables; a delivery that cannot reserve them is rejected
instead of increasing slow-consumer memory without bound.

Inbound safety limits are also fixed: in each one-second window, 256 frames /
32 MiB per connection, 4,096 frames / 128 MiB per source IP, and 32,768 frames /
512 MiB process-wide. Application and incoming ping/pong frames count; exceeding
a limit closes the WebSocket with status 1013. The traffic-IP window map is
capped at 65,536 entries. Pairing create and join requests separately share 30
attempts per source IP per minute, joins allow five attempts per lookup key,
and their limiter maps are capped at 65,536 IP and 262,144 lookup entries. New
keys fail closed with `PAIRING_RATE_LIMITED` when an applicable map is full.

For source Debug builds only, a physical Controller on the same trusted LAN can use plaintext WebSocket without installing a development certificate. Start signaling on all interfaces:

```bash
cd services/signaling
SIGNALING_LISTEN_ADDR=0.0.0.0:8080 go run ./cmd/signaling
```

Use the Host computer's private address, such as `ws://192.168.3.168:8080/v1/connect`. This opt-in accepts only literal RFC 1918 IPv4 or IPv6 unique-local addresses. Hostnames and public addresses remain rejected. Start every participating Debug component with the opt-in:

```bash
ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true \
ROAMMAND_SIGNALING_ENDPOINT='ws://192.168.3.168:8080/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=ws://192.168.3.168:8080/v1/connect --dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true'
```

```bash
make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID \
  FLUTTER_ARGS='--dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true'
```

For Android, run `flutter run -d YOUR_ANDROID_DEVICE_ID --dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true` from `apps/client_flutter`. On iOS, approve the Local Network prompt. The Rust environment switch is honored only in builds with debug assertions, and the Flutter switch only when `kDebugMode` is true. Profile, Release, and packaged Hosts ignore the opt-in and continue to reject non-loopback `ws://`. Host bindings created with a plaintext private-LAN endpoint are development-only; pair again through WSS before testing a Profile or Release app.

For normal cross-device use and all release acceptance, use WSS and a certificate trusted by every device:

```bash
cd services/signaling
SIGNALING_LISTEN_ADDR=0.0.0.0:8443 \
SIGNALING_TLS_CERT_FILE='certs/fullchain.pem' \
SIGNALING_TLS_KEY_FILE='certs/private-key.pem' \
go run ./cmd/signaling
```

Use `wss://<server-name>:8443/v1/connect` as the endpoint. A reverse proxy must preserve binary WebSocket frames and the `roammand-signaling.v1.protobuf` subprotocol.

### Advanced: start the Host Agent independently

On the computer being controlled:

```bash
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

Windows PowerShell:

```powershell
$env:ROAMMAND_SIGNALING_ENDPOINT = 'wss://signal.example.com:8443/v1/connect'
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

The Host Agent owns the desktop device identity, authorization registry, WebRTC peer, capture, and input path. On macOS, open **This computer** and complete the Screen Recording and Accessibility checklist before connecting. Permission setup is an explicit local action; starting a remote connection never opens permission prompts. This independent mode is for low-level development; the standard `make app-run-macos` workflow lets the GUI manage the Agent.

### Advanced: start the app independently

macOS:

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect'
```

Windows:

```powershell
cd apps\client_flutter
flutter run -d windows --dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect
```

The Flutter app and Host Agent must run as the same operating-system user. The app connects to the Agent through authenticated current-user IPC. The GUI starts and stops an Agent it owns; when it connects to a developer-started Agent, it never takes ownership or stops that process on exit.

### Pair a Controller

- Phone or tablet: open **This computer** on the Host, show the phone QR code, run `flutter run -d YOUR_DEVICE_ID` with an ID from `flutter devices`, and scan with the camera.
- Another computer: create a desktop pairing code, enter it under **My computers**, compare all four English verification words, and approve beside the Host.

After approval, the saved computer card can start future sessions without pairing again. Deleting the card on a Controller is local-only; revoking on the Host blocks future sessions.

## STUN configuration

The release profile uses direct ICE with STUN and no TURN fallback. Configure
the same public STUN service on the Host and Controller. An independently run
Host Agent reads both endpoints from its environment:

```bash
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
ROAMMAND_STUN_URLS='stun:stun.example.com:3478' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

The installed GUI passes its selected **Network services** profile to the Agent
it owns. Flutter development builds can override the default STUN service with
`--dart-define=ROAMMAND_STUN_URLS=stun:stun.example.com:3478`.

Follow [Docker Compose self-hosting](self-hosting/docker-compose.md) to deploy
matching WSS signaling and UDP STUN services. Without TURN, some symmetric NAT,
enterprise, and cellular paths are expected to fail rather than relay traffic.

### Optional low-level TURN test

The peer layer retains TURN environment inputs for isolated developer tests,
but TURN is not exposed by the release profile or the default Compose stack.
For a relay-only test, configure the same short-lived values on both peers:

```bash
ROAMMAND_ICE_TRANSPORT_POLICY=relay \
ROAMMAND_TURN_URLS='turns:turn.example.com:5349' \
ROAMMAND_TURN_USERNAME='<short-lived-username>' \
ROAMMAND_TURN_PASSWORD='<short-lived-password>' \
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

```bash
cd apps/client_flutter
flutter run -d YOUR_IOS_DEVICE_ID \
  --dart-define=ROAMMAND_ICE_TRANSPORT_POLICY=relay \
  --dart-define=ROAMMAND_TURN_URLS=turns:turn.example.com:5349 \
  --dart-define=ROAMMAND_TURN_USERNAME='<short-lived-username>' \
  --dart-define=ROAMMAND_TURN_PASSWORD='<short-lived-password>'
```

TURN URL, username, and password are an all-or-nothing group. Do not commit or
log credentials. This advanced path requires a separately operated TURN
service and is not a fallback provided by Roammand's current official profile.

## Build platform apps

```bash
make app-build-macos
make app-build-ios-simulator
make app-build-android
```

Windows Release:

```powershell
cd apps\client_flutter
flutter build windows --release --no-pub
```

Build output remains under `apps/client_flutter/build/` and is ignored by Git.

The iOS and iPadOS deployment target is 15.0 or later. Verify the generated
Simulator App and final Archive before distribution; both commands must print
`15.0`:

```bash
/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' \
  apps/client_flutter/build/ios/iphonesimulator/Runner.app/Info.plist
/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' \
  apps/client_flutter/build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Info.plist
```

### Check iOS artifacts for private APIs

Scan every iOS artifact before distribution. The scanner accepts an `.app`,
`.xcarchive`, or `.ipa`, walks every Mach-O file in the artifact—including the
main executable, embedded frameworks, and app extensions—and searches the raw
binary bytes for the forbidden ReplayKit selector `buttonPressed:`:

```bash
./scripts/check_ios_private_api.sh apps/client_flutter/build/ios/iphonesimulator/Runner.app
./scripts/check_ios_private_api.sh apps/client_flutter/build/ios/archive/Runner.xcarchive
./scripts/check_ios_private_api.sh path/to/Roammand.ipa
```

The command exits nonzero when the selector is present, when the artifact is
malformed, or when it contains no Mach-O files. It does not depend on Objective-C
metadata output from `otool`; the selector can reside in `__TEXT.__cstring`.
macOS CI runs this scan immediately after its iOS Simulator build. For a release,
scan both the final Archive and exported IPA produced from that Archive before
uploading either build to App Store Connect.

## Package the installed Host

Package scripts require a clean worktree for their default Release build. They stage only allowlisted apps, agents, bridge/helpers, service definitions, licenses, a protected uninstaller, and a sorted SHA-256 manifest. Device identities, grants, endpoints, credentials, private keys, and local developer paths are excluded.

The package allowlist and install manifest are technical integrity checks; they
are not substitutes for release compliance records. The macOS workflow
separately generates `SBOM.spdx.json`, `THIRD_PARTY_NOTICES.md`, and
`SOURCE_CODE.md` from the exact staged payload and the locked Cargo, Dart/pub,
CocoaPods, Flutter, and native WebRTC inputs. An unknown license, missing
notice, invalid provenance record, or incomplete required input stops
generation before the release files are replaced and blocks the release.
The package gate validates the complete three-file set, while CI also checks
the generated SPDX document with pinned `spdx-tools` 0.8.5. Other independently
distributed binaries, containers, iOS builds, and hosted services require
their own artifact-specific inventory and review. See
[Licensing](../LICENSES.md) for the scope.

### macOS

`make package-macos` builds Universal `arm64 + x86_64` app and background
components, generates the macOS compliance records, and stages the directory
used for development acceptance:

```bash
make package-macos
sudo ./scripts/install_macos.sh --dry-run
sudo ./scripts/install_macos.sh
```

Website distribution uses a signed installer package. After installing
Developer ID Application and Developer ID Installer identities and configuring
the local Apple Team, run the privacy-safe preflight and create the signed
package without submitting it for notarization:

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/check_apple_release_preflight.sh
make package-macos-signed
```

The workflow signs Frameworks, standalone Agents, the nested Session Agent,
and the app in inside-out order using Developer ID Application and Hardened
Runtime. It then regenerates the compliance records and install manifest so
their hashes describe the signed payload, and creates
`dist/apple-release/Roammand.pkg` with Developer ID Installer.
Compliance records use their actual UTC generation time unless a controlled
reproducible build explicitly sets `SOURCE_DATE_EPOCH`.

Store notarization credentials interactively in Keychain so the Apple ID,
Team ID, and password never appear in command arguments:

```bash
xcrun notarytool store-credentials roammand-notary
```

Leave the API private-key path blank, then enter the Apple ID, Team ID, and
app-specific password locally. Create an app-specific password under Sign-In
and Security at [Apple Account](https://account.apple.com/). Then run:

```bash
make release-macos
```

This submits through the `roammand-notary` Keychain profile, waits for an
`Accepted` response, staples the final package, and runs stapler and Gatekeeper
validation. Raw identities and credentials aren't printed. A failed
notarization log stays under ignored `dist/apple-release/`.

If the Keychain contains more than one valid identity of the same Developer ID
type, select the intended certificates explicitly without deleting the others:

```bash
ROAMMAND_APPLE_APPLICATION_IDENTITY_SHA1=APPLICATION_CERTIFICATE_SHA1 \
ROAMMAND_APPLE_INSTALLER_IDENTITY_SHA1=INSTALLER_CERTIFICATE_SHA1 \
make release-macos
```

Each selector must be the SHA-1 hash of a valid identity for the configured
Apple Team and certificate type.

The installer places `Roammand.app`, including its nested Session Agent, in `/Applications`, installed Host and
privileged binaries in `/Library/PrivilegedHelperTools`, and protected-session
launchd definitions in `/Library/LaunchDaemons` and `/Library/LaunchAgents`.
Opening the GUI starts its installed Host Agent. Closing the window keeps both
running in the tray; explicit **Exit** stops the Agent started by that GUI. The
installer loads the protected-session Agent into the current graphical session
without requiring sign-out.

An installed build exposes **Settings → Advanced → Uninstall Roammand**. It
requests administrator approval, stops the installed services, and completely
removes the app, background components, local data, and app-specific system
permissions. Development builds keep this action disabled so
they cannot accidentally target a separate installed copy.

For independent development, start `roammand-host-agent serve` before the GUI;
the GUI connects to that existing process and does not own or stop it. Set
`ROAMMAND_HOST_AGENT_AUTOSTART=false` to disable installed-Agent fallback, or
set `ROAMMAND_HOST_AGENT_EXECUTABLE` to test a specific Agent binary.

The repository script remains available as a terminal fallback or dry-run
preview:

```bash
sudo ./scripts/uninstall_macos.sh --dry-run
sudo ./scripts/uninstall_macos.sh
```

### Windows

Use an elevated PowerShell:

```powershell
pwsh -NoProfile -File scripts/package_windows.ps1
pwsh -NoProfile -File scripts/check_windows_package.ps1
pwsh -NoProfile -File scripts/install_windows.ps1 -WhatIf
pwsh -NoProfile -File scripts/install_windows.ps1
```

Preview and remove installed components with:

```powershell
pwsh -NoProfile -File scripts/uninstall_windows.ps1 -WhatIf
pwsh -NoProfile -File scripts/uninstall_windows.ps1
```

The macOS uninstaller completely removes Roammand's device identity, Controller
grants, saved Hosts, preferences, caches, and app-specific Screen Recording and
Accessibility decisions. The Windows fallback currently preserves each user's
device identity and Controller grants. Follow
[Testing and verification](TESTING.md) for target-system checks.

## Configure local Apple signing

The public Xcode projects do not contain an Apple developer identity. Configure the ignored local override from the repository root:

```bash
./scripts/configure_apple_signing.sh \
  --team-id YOUR_TEAM_ID \
  --bundle-id com.example.roammand
./scripts/configure_apple_signing.sh --check
```

The command validates its inputs, writes `apps/client_flutter/apple/Signing.local.xcconfig` atomically, and sets mode `0600`. Certificates, private keys, provisioning profiles, App Store Connect `*.p8` keys, and local export options must remain outside Git.

Use the privacy-safe preflight to verify effective Release settings without
printing the Team ID, bundle ID, or signing identity:

```bash
./scripts/check_apple_release_preflight.sh
```

iOS distribution uses App Store/TestFlight archives. The complete macOS Host uses Developer ID signing, Hardened Runtime, a signed installer, notarization, and stapling for direct distribution. Its privileged non-sandboxed architecture is not a Mac App Store target; a store-distributed macOS app requires a separate sandboxed Controller-only design.

## Verify changes

```bash
make format-check
make test
make test-product
```

Generate and verify versioned protocol outputs with:

```bash
make generate
make generate-check
make test-conformance
```

Protocol, pairing, session, bridge, security, self-hosting, and service contracts
are collected in the [architecture](architecture/README.md),
[security](security/README.md), [self-hosting](self-hosting/docker-compose.md),
[official service profile](operations/official-service-profile.md), and
[testing](TESTING.md) guides.
