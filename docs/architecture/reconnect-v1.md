<!-- SPDX-License-Identifier: Apache-2.0 -->

# Authenticated reconnect V1

This document defines how an authenticated Roammand session recovers from a temporary signaling or WebRTC interruption. Reconnect never creates trust: the existing one-way Controller-to-Host grant remains authoritative, and the Host can revoke it at any time.

## State and timing

An active Controller moves from `connected` to `reconnecting` after a
recoverable signaling or peer failure. It schedules at most five serial attempts
with per-attempt delays of 1, 2, 4, 8, and 8 seconds. The delay ledger therefore
reaches 1, 3, 7, 15, and 23 seconds. After the fifth unsuccessful attempt
finishes, a final 7-second policy grace completes the configured 30-second
schedule; there is no sixth attempt or unbounded retry loop.

The 30-second value accounts for scheduled delays and the final grace, not time
spent inside asynchronous signaling, cryptographic, or peer operations. Those
operations run serially between timers and can add wall-clock time. The policy
is therefore a bounded retry schedule, not a hard 30-second end-to-end latency
or wall-clock SLA.

Entering `reconnecting` immediately blocks new remote input, releases held buttons and keys on a best-effort basis, and clears pending fast-pointer data. A spontaneous peer recovery cancels every remaining timer. If recovery has not completed when the final grace expires, the session becomes `failed` and waits for an explicit user retry or close. Manual retry creates a new session resource group instead of reusing closed signaling, peer, identity-adapter, or renderer objects.

The Host uses a separate 45-second fail-closed retention deadline from the time
it enters reconnecting state. That deadline is intentionally longer than the
Controller's 30-second timer budget so a final authenticated ICE restart has
time to complete; it does not add Controller attempts. The Host releases remote
input while retained, rejects new input envelopes, and continues to return busy
for other Controllers. Revoking the grant terminates the retained session
immediately.

Mobile application backgrounding is not a reconnect trigger. It releases input, closes the session, and requires the user to choose **Connect** after returning to the foreground.

## Fresh authentication on every attempt

Every reconnect offer contains a fresh 32-byte nonce, new issue and expiry times, the current ICE-restart SDP hash, the current DTLS fingerprint, and a new Ed25519 signature over the canonical protocol transcript. The Controller must not reuse authentication, SDP, candidates, or transcript bytes from an earlier attempt.

When the Host still has the peer, it authenticates the offer, restarts ICE on that peer, and returns a Host-signed reconnect response with a strictly increasing generation. The Controller verifies both device identities and public keys, session ID, nonce, offer and answer hashes, DTLS fingerprints, permissions, time window, and generation before accepting it.

If the Host process restarted and lost its peer, the same fresh offer may establish a new peer only after the full normal session authentication and grant checks. This path returns a normal signed answer; it is not an anonymous or reduced-authentication fallback.

Stale generations, expired messages, replayed nonces, mismatched identities, unexpected candidates, invalid signatures, and revoked or absent grants fail closed.

## Resource and protocol boundaries

- Only one reconnect offer may be in flight for a session.
- Pending candidates and signaling frames retain their protocol count and byte limits.
- ICE restart reuses the current peer only while the authenticated Host session is retained.
- Successful recovery re-enables input only after the authenticated peer reports connected.
- Failure and close cancel timers and dispose session-scoped subscriptions, channels, capture, and input state.
- The signaling service continues to route bounded opaque envelopes. It cannot validate device grants or authorize remote control.

Recovery, privacy, and resource checks are collected in
[Testing and verification](../TESTING.md). Diagnostic boundaries are defined in
[Privacy-safe diagnostics](../security/privacy-safe-diagnostics.md).
