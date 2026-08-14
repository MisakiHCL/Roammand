<!-- SPDX-License-Identifier: Apache-2.0 -->

# Roammand user guide

**English** · [简体中文](README.zh-CN.md)

> The macOS installer is the only general-download binary currently published.
> Mobile Controllers require a source build or a test build supplied separately
> by a maintainer; there is no public App Store or Android package download.

## Before you start

- The current macOS release requires macOS 14.4 or later.
- The Mac must grant Roammand Screen Recording and Accessibility access before
  it can accept a connection.
- A Host accepts one inbound Controller session at a time.
- The iOS source target requires iOS/iPadOS 15 or later and currently runs in
  landscape. The Android source target requires Android 7.0 / API 24 or later.
- The current release attempts direct ICE connections and has no TURN relay
  fallback. Some restrictive or symmetric network combinations may not connect.

## Install and authorize the Mac

1. Download the signed and notarized `Roammand.pkg` from
   [GitHub Releases](https://github.com/MisakiHCL/roammand/releases/latest).
2. Open the package and approve the administrator prompt to install the app and
   its required Host components.
3. Start Roammand and open **This computer**.
4. Use the two **Set up** actions to grant Screen Recording and Accessibility
   access in System Settings.
5. Return to Roammand. Pairing and incoming connections become available only
   after both permissions are ready.

Permission requests are initiated only by these local setup actions. An incoming
connection does not request permissions on the user's behalf.

## Prepare the Controller

For another Mac, install the same public package and use **My computers**; Host
permissions are needed only on a computer that will accept incoming control.

There is no public mobile-store build at this time. Source builders should use
the physical-device commands in [Building Roammand from source](../BUILDING.md).
If a maintainer supplied a test build, install it through the channel named in
that invitation rather than an unofficial mirror.

On first launch, choose a device name. The Host displays this bounded name when
asking for local approval; it is a label, not proof of identity.

## Pair a phone or tablet with QR

1. On the Mac, open **This computer** and create a phone QR invitation.
2. In the mobile Controller, open the scanner and scan the live QR code. Import
   from photos, files, the clipboard, or manually entered QR text is not
   supported.
3. Check the Controller name shown on the Mac and approve it locally.
4. Select the Mac under **My computers** and choose **Connect**.

QR pairing does not use the four-word comparison. It relies on possession of
the live authenticated invitation and still requires approval at the Host.

## Pair another computer with a code

1. On the Host, create a desktop pairing code under **This computer**.
2. On the Controller, enter that code under **My computers**.
3. Compare all four English verification words shown by both computers. Cancel
   if any word differs.
4. Approve the named Controller locally on the Host, then connect from its saved
   card.

Both QR invitations and desktop codes expire after at most two minutes. Pairing
authorization is one-way. Reversing which device controls which Host requires a
separate pairing and approval.

Roammand uses the Mac's system computer name when it is available. If multiple
computers have similar names, use the edit action on a saved computer to set an
alias such as “Office Mac” or “Home Mac.” The alias remains only on that
Controller; it does not change the Mac name, device identity, or authorization.

## If a connection fails

- If the Mac shows incomplete permissions, finish both setup items before trying
  to connect again.
- Confirm that Roammand is running on the Mac and that the Host is shown as
  available.
- If another Controller is connected or recovering, stop that session locally
  before trying the second Controller.
- If the Host changed signaling services after pairing, pair again through the
  new service. A saved Controller record deliberately keeps the authenticated
  endpoint captured during pairing.
- Try another network on either device. Without TURN, direct connectivity can
  fail on restrictive networks even when both devices can reach signaling.
- Stop an active session locally from the Mac if the Controller is unexpected.

## Stop or revoke access

Closing a mobile Controller session releases held input; moving the mobile app
to the background closes the session and does not reconnect automatically.
**Stop** or **Emergency stop** on the Host ends the active session but preserves
the saved grant. To block future connections, revoke that Controller under
**This computer**. Deleting the Host card only on the Controller does not revoke
the Host-side grant.

Roammand requires no account, but the signaling and STUN services necessarily
observe limited network and routing metadata. See the [security guide](../security/README.md)
for the trust, metadata, and diagnostics boundaries.

## Uninstall from macOS

Open **Settings → Advanced → Uninstall Roammand**. The protected uninstaller
removes the app, Host components, launchd configuration, runtime files, logs,
device identity, pairing grants, saved Hosts, preferences, caches, and
Roammand-specific Screen Recording and Accessibility decisions. Reinstalling
creates a new identity and requires pairing again.

Developers and source builders should use the [build guide](../BUILDING.md).
