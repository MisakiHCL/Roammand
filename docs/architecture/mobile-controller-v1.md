<!-- SPDX-License-Identifier: Apache-2.0 -->

# Mobile Controller V1

Mobile Controller V1 defines the iOS and Android control experience for an already paired Windows or macOS Host. It reuses the authenticated session, WebRTC media, and `input.reliable` / `pointer.fast` protocol from Desktop WebRTC V1. It does not add a second authorization mechanism or a mobile-specific wire format.

## Trust and session boundary

The mobile Ed25519 private key remains in platform-protected local storage. A successful camera-only pairing stores the Host public identity, signaling endpoint, pairing time, and local display metadata. Selecting **Connect** constructs a fresh session from that record:

1. the Controller registers its derived device ID with the saved signaling endpoint;
2. it signs the canonical session-offer transcript locally;
3. the Host verifies the signature, permanent Controller → Host grant, nonce, expiry, SDP hash, and DTLS fingerprint;
4. the Controller verifies the Host answer against the exact saved Host public key before accepting it;
5. remote input becomes available only after the authenticated WebRTC peer reaches connected state.

Signaling routes bounded opaque envelopes and cannot create a grant or device signature. TURN can relay encrypted WebRTC packets but has no authorization role. Reverse control still requires a separate pairing in the opposite direction.

## Components

- `MobileControllerSessionIdentity` exposes only public identity, offer signing, and close operations to the shared session controller.
- `RemoteDesktopController` owns authenticated signaling and peer negotiation and creates the two protocol input senders only after verification.
- `MobileViewport` contains the video, applies local zoom, preserves the visible remote anchor across rotation or keyboard resize, and maps visible points to the Host coordinate interval.
- `MobileGestureMachine` converts raw pointer sequences into mutually exclusive click, drag, scroll, and zoom actions using deterministic timers.
- `MobileGestureSurface` maps remote actions to the reliable or fast data channel. Zoom remains local.
- `MobileKeyboardController` serializes text, modifier, and special-key operations so rapid UI input cannot reorder reliable frames.
- `MobileRemoteDesktopPage` coordinates video dimensions, safe areas, input controls, connection status, and app lifecycle.

Every launch creates fresh signaling, peer, renderer, input, and identity-adapter resources. Only one Host launcher can be in flight from the mobile home screen. The saved “last connected” value changes only if the session actually reached `connected`.

## Viewport and coordinate contract

The base video rectangle uses aspect-ratio contain. Black bars reject input. Local zoom is clamped from `1.0` through `4.0`; panning is clamped so scaled content cannot expose invalid space on an axis where it covers the viewport. The inverse transform maps an accepted local point to inclusive integer coordinates from `0` through `10000`, matching the Host input validator.

Rotation, safe-area changes, and system-keyboard resizing rebuild the viewport using the prior visible remote center as the new anchor. Pinch uses the remote point under the initial focal position as its anchor. All transform inputs must be finite and positive, and every emitted remote position is bounded before serialization.

## Gesture mapping

| Mobile gesture | Result | Channel |
| --- | --- | --- |
| One tap | Left click after the double-tap window expires | `input.reliable` |
| Two taps | One left double-click; no earlier single click | `input.reliable` |
| Long press and move | Left down, coalesced moves with button bit, left up | reliable + `pointer.fast` |
| Two-finger tap | Right click at the initial centroid | `input.reliable` |
| Parallel two-finger movement | Signed horizontal/vertical scroll deltas | `pointer.fast` |
| Two-finger pinch | Local viewport zoom only | none |

The recognizer normally waits for both contacts to move before classifying a two-finger sequence. A 32 ms classification window also permits one finger to remain as a stationary pinch anchor. This avoids treating the temporary distance change between sequential platform move events as a pinch without making anchored pinch impossible. A cancel clears pending timers and requests one release-all operation.

## Keyboard input

The tray sends non-empty UTF-8 text up to the protocol limit and provides the left-side USB HID usages for Ctrl, Shift, Alt, and Command. Modifier state is included with Esc, Tab, and the four arrow keys. Special keys emit an ordered down/up pair. Duplicate modifier selections are idempotent, and release or close clears the local modifier set.

## Lifecycle and cleanup

Remote control is foreground-only:

- `inactive` or `hidden` cancels the recognizer and releases every held remote key/button;
- `paused` or `detached` additionally closes the authenticated session;
- `resumed` never reconnects automatically;
- page disposal closes the keyboard queue, input sender, peer, signaling streams, renderer, and identity adapter through idempotent ownership boundaries.

Android declares camera and network access, disables application backup, and
explicitly excludes all storage domains from cloud backup and device transfer.
It uses keyboard resize, supports platform rotation, and declares no
foreground-service permission. Its Debug manifest permits cleartext traffic for the guarded
private-LAN development path while Release retains the platform default. iOS
declares camera and local-network purposes, permits local resource loading
through the narrow ATS local-network setting, currently locks the Flutter UI to
landscape left/right, and declares no background mode. Flutter's endpoint policy
still rejects private-address plaintext WS outside Debug even though local
networking itself remains available to Release sessions.

## ICE, STUN, and optional TURN configuration

Direct ICE with H.264 then VP8 preference is the release default. The runtime
Network services profile supplies public `stun:` or `stuns:` URLs to the mobile
Controller and managed Host Agent. `ROAMMAND_STUN_URLS` remains available as a
Dart definition and Host Agent environment override for development.

The lower-level peer layer also accepts `ROAMMAND_ICE_TRANSPORT_POLICY`,
`ROAMMAND_TURN_URLS`, `ROAMMAND_TURN_USERNAME`, and
`ROAMMAND_TURN_PASSWORD` for isolated relay tests. TURN URL, username, and
password are an all-or-nothing group, and `relay` requires at least one valid
`turn:` or `turns:` URL. TURN is not part of the release Network services UI or
official service profile. Credentials are runtime inputs and must not be
committed or printed by smoke tooling.

For trusted-LAN source development, a mobile Debug build may accept a literal private-address `ws://` binding when compiled with `--dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true`. The Host Agent must opt in separately through the matching environment variable. Profile and Release ignore this setting and require WSS for non-loopback endpoints.

## Product boundaries

The mobile Controller does not add background control, multi-display selection,
clipboard, audio, or file transfer. Automated tests validate protocol mapping,
state machines, lifecycle, and simulator builds; target-device behavior follows
[Testing and verification](../TESTING.md).
