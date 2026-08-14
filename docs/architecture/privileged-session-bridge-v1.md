<!-- SPDX-License-Identifier: Apache-2.0 -->

# Privileged session bridge V1

The privileged session bridge extends a desktop Host across operating-system
desktop transitions without moving permanent trust into a root or LocalSystem
process. It is local-only and does not change the Controller signaling or
WebRTC wire protocol.

## Trust boundary

The current-user Host Agent remains the sole owner of:

- the device's long-term private key;
- permanent Controller → Host grants and revocation;
- pairing, signaling, and session authentication;
- DataChannel decoding, permission checks, ordering, limits, and input
  validation.

The installed broker observes graphical sessions, authenticates local peers,
routes one active session, and issues one ephemeral lease. A per-session Helper
owns the native PeerConnection, capture, validated input injection, and the
protected-desktop control indicator. Neither component has a general command
execution interface or an Internet signaling endpoint.

Controller → Host authorization remains one-way. Reverse control requires a
separate pairing, and a permanent grant remains valid until the Host revokes
it. A broker restart, Helper restart, or emergency stop does not silently
delete that grant.

## Local bridge protocol

`privileged_bridge.proto` defines separate versioned client and server frames.
Every frame has a protocol version, bounded request identifier, monotonically
checked sequence, and one typed payload. The protocol carries peer negotiation,
ICE, raw DataChannel events, validated input commands, status, and unified
errors; it carries no arbitrary executable command.

The local framing limit is 256 KiB. Authentication combines local transport
credentials, an installed executable identity/hash policy, and a challenge
response made with a random installation secret. Host and Helper proofs have
different contexts. Reflected nonce, replay, duplicate request, stale
generation, wrong peer, unknown version, and over-limit input fail closed.

The broker permits one authenticated Host connection and one active lease. The
Host renews a lease every 5 seconds; it expires after 15 seconds. Each operation
is bound to the lease ID and graphical-session generation. Lease IDs, nonces,
socket paths, SDP, ICE, and input payloads are redacted from diagnostics.

## Session migration

A route is one of normal, locked/login, secure, transitioning, or unavailable.
The normal migration order is:

1. freeze remote input;
2. release every key, pointer button, and modifier;
3. close the old Helper peer;
4. publish a strictly newer graphical-session generation;
5. perform the existing authenticated reconnect with a fresh nonce, signature,
   and DTLS fingerprint binding;
6. enable input only after the new route and peer are authenticated.

Old-generation input, ICE, close, and secure-attention requests are rejected.
Route loss, logout, peer authentication failure, queue overflow, capture
failure, or input failure releases input and closes the peer.

## Platform mapping

Windows maps the active console session to `winsta0\\default` for the normal
desktop and `winsta0\\winlogon` for lock, credential, UAC, and secure-attention
surfaces. The installed service is non-interactive LocalSystem. A software
Ctrl+Alt+Del request uses the operating-system SendSAS policy only when the
current controlled Winlogon route and `CONTROL_INPUT` permission are both
present. Ordinary synthetic input is never used to imitate Ctrl+Alt+Del.

macOS 14.4 or newer uses a root LaunchDaemon for routing and a Global
LaunchAgent in Aqua and LoginWindow. The daemon never captures a screen or
injects input. The session Agent uses only the permissions and APIs available
to its graphical session. FileVault preboot is outside WindowServer and is not
supported.

When the installed bridge is unavailable, Roammand uses the normal desktop
implementation. That state is explicitly reported as
`user_session_only`; it does not claim lock, LoginWindow, UAC, or secure-desktop
support.

## Local visibility and stop

The Host application and tray display sanitized bridge state and the bounded
Controller display name. Closing the desktop window hides it; explicit Exit is
separate. During control, Emergency stop terminates active sessions and
releases input without deleting permanent grants. The protected-desktop Helper
shows a localized topmost/non-activating indicator; its local Stop releases
input and closes the route, and no remote IPC command can hide or dismiss it.

## Supported boundary

The architecture supports an already logged-in Host owner, one inbound
Controller, lock/unlock transitions, credential surfaces, and authenticated
reconnect. It does not support a new connection before the owner has ever
logged in, continued control after the Host Agent exits or the owner fully logs
out, FileVault preboot, bypassing TCC/UAC/SAS or administrator approval, file
transfer, clipboard, audio, multi-display selection, invisible control, or
automatic updates.

Repository tests verify protocol, leases, authentication, state transitions,
UI behavior, and package layout. Windows secure desktop and macOS LoginWindow
behavior require the installed target-system checks in
[Testing and verification](../TESTING.md).
