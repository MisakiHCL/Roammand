<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img src="brand/roammand-app-icon.svg" width="112" alt="Roammand logo">
</p>

<h1 align="center">Roammand</h1>

<p align="center"><strong>Leave the desk. Keep work moving.</strong></p>

**English** · [简体中文](README.zh-CN.md)

Roammand is an open-source, account-free remote desktop app for your own
computers. Use a phone, tablet, or another computer to control Windows and
macOS—continue work away from your desk or check on a long-running task.

## What you can do

- **Pair once, reconnect easily.** Save trusted computers for later connections;
  authenticated reconnect helps recover from brief interruptions.
- **Work from mobile.** Use touch gestures, text entry, modifiers, and special
  keys to operate desktop apps.
- **Stay in control of access.** See who is connected, stop a session locally,
  and revoke a device's access from the computer being controlled.
- **Choose your infrastructure.** Start with the built-in official services, or
  [self-host signaling and STUN with Docker Compose](docs/self-hosting/docker-compose.md).

## Platform support and downloads

The **Host** is the computer you control; the **Controller** is the device you
use to control it. **Only macOS currently has a public installer.**

| Platform | Role | Get Roammand |
| --- | --- | --- |
| macOS 14.4 or later (Universal) | Host and Controller | [Download `Roammand.pkg`](https://github.com/MisakiHCL/Roammand/releases/latest/download/Roammand.pkg) |
| Windows 10 / 11 | Host and Controller | Build from source; no public installer. Installed Hosts use Windows 11 as the validation baseline. |
| iOS / iPadOS 15 or later | Controller | Build from source or join maintainer-invited testing; no public App Store download. |
| Android 7.0 or later (API 24) | Controller | Build from source; no public package. |

The macOS 1.1.0 package is Developer ID-signed but **not notarized**; Gatekeeper
may block opening it. See [Releases](https://github.com/MisakiHCL/Roammand/releases)
for release notes and asset digests. Mobile source and invited builds are for
development and device verification until a public release is listed here.

## Quick start

Start with two Macs, or a Mac and a mobile Controller prepared as listed above.

1. **Prepare the Mac you want to control.** Install Roammand, open **This
   computer**, and complete both **Screen Recording** and **Accessibility**
   setup items. The Host becomes available once both permissions are ready.
2. **Open Roammand on your Controller.** On another Mac, install the same
   package and open **My computers**; on mobile, use a source or invited build.
3. **Pair and approve.** For mobile, create a live QR invitation on the Host,
   scan it with the Controller, and approve the named device on the Mac. For
   another computer, create a one-time desktop code, enter it on the Controller,
   compare all four English verification words on both devices, then approve
   the named Controller on the Host.
4. **Connect.** Select the saved Mac in **My computers** and choose **Connect**.

For detailed installation, pairing, troubleshooting, and uninstall steps, see
the [user guide](docs/user-guide/README.md).

## Current limits

- One inbound Controller session per Host; only the main display is shared.
- No audio, clipboard sync, file transfer, cloud sync, or automatic updates.
- Mobile control is foreground-only; backgrounding closes the session. The
  iOS/iPadOS interface is landscape-only.
- Official and included self-hosting profiles have **no TURN relay**. Direct
  connections can fail on restrictive networks.
- Lock/login control needs installed Host components and system permissions.
  Access before the owner's first login, after full logout or Host exit, and
  during FileVault preboot is outside the supported boundary.

## Start from source

The app uses Flutter, the Host uses Rust, and signaling uses Go. Install the
prerequisites in [Build, run, package, and verify](docs/BUILDING.md), then run
from the repository root on macOS:

```bash
make bootstrap
make app-check
make app-run-macos
```

The build guide also covers mobile and Windows targets, packaging, and verbose
logs.

## Security by design

Pairing requires approval on the Host and saves a one-way grant; reverse control
needs a separate pairing. Long-term private keys and grants stay on the devices,
and signaling cannot authorize control. See the
[pairing model](docs/architecture/account-free-pairing-v1.md).

WebRTC protects screen and input traffic between devices. Signaling and STUN
operators can still observe negotiation or network metadata; account-free does
not mean anonymous. Read the [Security](docs/security/README.md) guide,
[diagnostics policy](docs/security/privacy-safe-diagnostics.md), and official
operator's [privacy policy](https://hclgame.com/roammand/privacy) for details.

## Project guides

- [Architecture](docs/architecture/README.md) · [Brand design guidelines](brand/README.md)
- [Official signaling and STUN service profile](docs/operations/official-service-profile.md)
- [Testing and verification](docs/TESTING.md)
- [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Report a security issue](SECURITY.md)

## License

Roammand uses path-specific open-source licenses. Read the
[licensing overview](LICENSES.md) before reuse or distribution.
