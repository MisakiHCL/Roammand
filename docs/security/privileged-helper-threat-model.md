<!-- SPDX-License-Identifier: Apache-2.0 -->

# Privileged Helper threat model

## Protected assets

The most sensitive assets are the device's long-term private key, permanent
Controller grants, session-authentication authority, captured pixels, remote
input, and the ability to cross a lock/login or protected system desktop.
Long-term private key and grant records remain in the current user's protected
storage and are never copied into the privileged broker, session Helper,
signaling service, package manifest, or diagnostics.

## Trusted and untrusted parties

The Host owner and the locally installed, verified binaries are trusted for
their narrow roles. Controller network traffic, signaling payloads, local
processes outside the installed identity policy, stale Helpers, package input,
and all frame bytes are untrusted.

The signaling service relays bounded opaque messages. It holds no device
private key or grant database and cannot independently authorize a Controller.
Administrator consent installs a service; it does not create a remote-control
grant. Host-local approval still creates every permanent one-way grant.

## Main threats and controls

| Threat | Required control |
| --- | --- |
| Local process impersonates the Host or Helper | Local-only transport, OS peer identity, installed path/hash or code identity, and role-separated challenge response |
| Network peer reaches privileged IPC | No network listener; reject remote Windows pipes and non-local Unix endpoints |
| Replay or reflection | Fresh nonces, distinct Host/Helper proof contexts, broker instance binding, strict sequence, and bounded request tracking |
| Stale Helper continues injecting | One 15-second lease, 5-second renewal, graphical-session generation binding, parent/route death cleanup |
| Controller turns DataChannel bytes into privileged commands | Host Agent decodes and validates typed protocol input before the Helper receives a concrete action |
| Route changes leave held input | Freeze, release-all, close, then publish the next generation; stale events fail closed |
| Helper gains permanent authorization | No private key, grant snapshot, pairing secret, or general signing interface in privileged schema |
| Secret or screen data leaks through logs | Stable errors and redacted debug output; no SDP, ICE, nonce, input, pixels, paths, or credentials |
| Package is replaced | Protected install location, sorted SHA-256 manifest, no links/reparse points, and platform signing policy for releases |
| Remote user hides local control | Tray/Host status plus a protected-session indicator; only local Emergency stop can dismiss control |

## Fail-closed behavior

Unknown versions, enum values, states, desktops, peers, fields, sequences, and
generations fail closed. So do malformed or oversized frames, partial
authentication, queue overflow, lease expiry, permission loss, Helper crash,
broker restart, logout, capture failure, and input injection failure. Failure
releases input and closes the peer; the implementation does not silently fall
back from a protected route to an unprivileged route.

Direct user-session mode is exposed as the distinct `user_session_only` state.
It does not relax authentication.

## Platform policy limits

The Windows service does not bypass UAC or the SAS policy. Ctrl+Alt+Del is
requested only through SendSAS when system policy and the current lease allow
it. The macOS components do not bypass Screen Recording, Accessibility, TCC,
code-signing, or administrator approval. FileVault preboot is not supported.

## Verification limits

Deterministic tests cover malformed authentication, peer mismatch, replay,
framing limits, state transitions, stale leases, protected-indicator behavior,
redaction, and package layout. UAC, Winlogon, Ctrl+Alt+Del, LoginWindow, TCC,
and lock-screen behavior require the installed target-system checks in
[Testing and verification](../TESTING.md).
