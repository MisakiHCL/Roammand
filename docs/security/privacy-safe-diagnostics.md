<!-- SPDX-License-Identifier: Apache-2.0 -->

# Privacy-safe diagnostics

Roammand diagnostics use a typed allowlist. They are intended to explain connection and recovery failures without turning a private remote-control session into a collection of identifiers, network topology, screen content, or user input.

## User-controlled report

The Controller exposes a diagnostics action on the remote-session page. It first shows a localized preview of what is included and excluded. A report is written only after the user chooses to save it; it is never uploaded automatically, copied to the clipboard, or sent through signaling.

The JSON schema identifier is `roammand-diagnostics/v1`. The app prefers the platform Downloads directory and falls back to its application documents directory. A report is limited to 256 KiB and uses a timestamped local filename. The in-memory event ring retains at most 128 typed entries, drops the oldest entry at capacity, and marks the report as truncated.

## Allowlisted data

A V1 report may contain only:

- app version, protocol major/minor, and coarse OS family;
- relative session-state timing and stable error categories/codes;
- reconnect attempt number, scheduled delay, outcome, and total relative time;
- aggregate WebRTC sample count, current/average RTT and bitrate, packet counts/loss ratio, frame rate, normalized codec, and `direct`, `relay`, or `unknown` route;
- event totals, retained event count, truncation state, and the explicit included/excluded field lists.

Raw WebRTC reports are reduced in memory to these aggregates and are not retained in the export.

## Data that is always excluded

The typed report cannot accept arbitrary messages or maps. It excludes:

- device identifiers, device names, keys, signatures, and nonces;
- tokens, TURN credentials, passwords, and private configuration paths;
- SDP, ICE candidates, IP addresses, ports, and raw WebRTC statistic IDs;
- text input, key values, pointer coordinates, screen pixels, and captured media;
- raw signaling frames, DataChannel payloads, and exception stacks.

Do not add a field merely because it is hashed or partially redacted. A stable hash of a device or address can still identify it and remains excluded.

## Component logging

The Go signaling service logs typed event and error codes plus bounded counts or durations. It does not log frame bodies, request/device identifiers, peer addresses, credentials, or raw transport errors. Rust identity, signaling, peer, offer, candidate, lease, and input types implement redacted debug output; errors exposed across process boundaries use stable categories.

The privacy checks in `make test-product` inject sentinel values into diagnostic
and logging paths and reject disclosure. The typed allowlist remains
authoritative; every new field requires explicit schema and privacy review.

Users should inspect the preview and saved JSON before sharing it. Deleting the file is sufficient to remove the report; the application does not maintain a report archive.
