<!-- SPDX-License-Identifier: Apache-2.0 -->

# Official signaling and STUN profile

**English** · [简体中文](official-service-profile.zh-CN.md)

The current official service profile uses account-free signaling plus public STUN:

- Signaling: `wss://signal.hcl.life/v1/connect`
- STUN: `stun:stun.hcl.life:3478`
- ICE policy: `all`
- TURN relay: not provided
- Operator: ChengLong Hu
- Privacy contact: `misakihcl@gmail.com`
- Privacy policy: <https://hclgame.com/roammand/privacy>
- Infrastructure: Tencent Cloud, Singapore region

Signaling is WebSocket traffic and may be routed through an HTTP reverse proxy.
STUN is UDP traffic and must be exposed through direct DNS or a compatible
layer-4 load balancer. A URL path such as `https://hcl.life/stun/` cannot carry
STUN, and an ordinary website CDN does not replace UDP 3478.

## Deployment boundary

The public client may contain official domain names and ports. It must not
contain an infrastructure credential, private key, origin address, SSH alias,
certificate path, or operator-specific local path. STUN has no password and
does not relay session traffic.

WSS terminates at signaling, so the operator can access the bounded nested
envelope bytes being forwarded, including public identity proofs and WebRTC
negotiation metadata, as well as source addresses, registered routing
identifiers, timing, and traffic size. The current service does not decode,
persist, or normally log nested bodies, but that data-minimizing implementation
is not end-to-end confidentiality from its operator. Access to proxy, runtime,
and infrastructure telemetry must also be restricted. The repository defines
no uptime or support SLA for the official profile; deployments that require
operator-controlled availability should use the self-hosting profile and their
own monitoring.

The official deployment has no Roammand business database. Presence, pairing
rendezvous, rate-limit windows, and active routes remain in process memory and
are cleared on restart; signaling messages are not intentionally persisted.
The WebSocket endpoint disables routine Nginx access logging. Infrastructure
error and service logs may still contain network addresses and timing needed
for security, abuse prevention, and availability. Nginx logs are checked daily
and keep at most 14 rotated archives when non-empty; system and coturn syslog
files are checked weekly and keep at most four rotated archives when non-empty.
The system journal is capacity-managed and has no fixed time-based maximum.
These are rotation limits, not guarantees that every record remains for a
specific number of days. The deployment scripts do not create backups of
Roammand signaling state or logs.

The signaling process listens on a private interface behind the reverse proxy.
The proxy overwrites `X-Real-IP`, and the service trusts that header only when
the direct peer belongs to `SIGNALING_TRUSTED_PROXY_CIDRS`. Never configure the
whole Internet as a trusted proxy.

## Client integration

Release builds include a restorable official profile and a runtime custom
profile for signaling and STUN. The selected profile is passed to the GUI-owned
Host Agent. Developers may continue to run signaling, the Host Agent, and
Flutter independently with explicit environment or Dart definitions.

Changing a Host signaling endpoint restarts its GUI-owned Agent. Previously
paired Controllers continue to hold the old endpoint until an authenticated
re-pairing replaces the binding for the same Host identity. STUN settings are
local ICE inputs and are not embedded in pairing QR codes.

## TURN relay boundary

TURN is deliberately outside the current official profile because it relays
high-bandwidth encrypted traffic and needs abuse controls, allocation limits,
capacity monitoring, and short-lived credentials. Any separately operated TURN
deployment should use a direct DNS name or layer-4 load balancer and must never
embed a long-lived TURN password in the client.
