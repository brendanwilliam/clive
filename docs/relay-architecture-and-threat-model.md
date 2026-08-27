# Encrypted relay architecture decision record

Status: designed for a future release; unavailable in V1

This decision record resolves the relay boundary for Epic [#155](https://github.com/brendanwilliam/clive/issues/155), Issue [#162](https://github.com/brendanwilliam/clive/issues/162), and the NAT traversal research in [`nat-traversal-spike.md`](nat-traversal-spike.md).

## Decision

Clive may use an encrypted relay as a last-resort byte-forwarding path after
direct LAN, private VPN, and direct WAN/cellular routes fail. The relay is not a
Clive session endpoint: it cannot terminate Clive TLS, authorize a device or
session, inspect terminal frames, or create a shell.

The relay is designed but not enabled in V1. Until the launch gates below are
approved, the route catalog reports no relay candidate and Clive fails closed
when no approved direct route is available. Adding the relay slot to the route
abstraction does not authorize a deployment.

## Responsibilities and deployment

The relay operator is responsible for capacity, uptime, abuse response, cost,
incident response, software updates, and deletion of active routing metadata.
Clive is responsible for issuing and revoking relay rendezvous capabilities,
maintaining end-to-end TLS, and presenting the route as a fallback to the user.
The operator must be separately identified before production use; a developer
or test deployment is not a production trust anchor.

The Mac maintains an outbound relay connection, which permits operation behind
NAT, CGNAT, changing addresses, and restrictive inbound firewalls. The iPhone
obtains a short-lived rendezvous capability through the existing authenticated
Clive control path. The relay matches the two connections and forwards opaque
bytes. It does not receive CloudKit records, terminal data, or private keys.

## Connection and authorization flow

1. Direct route providers are exhausted according to the normal route priority
   and hysteresis policy.
2. The paired Mac requests a relay rendezvous capability for one iPhone and one
   connection attempt. The capability is short-lived, single-use, scoped to the
   paired device and session, and bound to the expected peer context.
3. The Mac opens an outbound relay connection and proves possession of the
   capability without sending terminal bytes before the Clive TLS channel is
   ready.
4. The iPhone presents the matching capability over its authenticated route
   setup. The relay either pairs the two opaque streams or rejects the request.
5. Mac and iPhone perform the same pinned mutual TLS handshake used on direct
   routes. Only after that handshake succeeds may framed session traffic flow.
6. Session attachment uses the stable server session ID and last received
   output offset. A relay connection never creates a replacement PTY.

The capability is not a bearer credential for Clive. Possession of it can only
permit a bounded relay match; certificate authentication still authorizes the
Clive connection. Expired, replayed, revoked, mismatched, or duplicate
capabilities fail closed. Local disablement and device revocation invalidate
capabilities before any remote cleanup is attempted.

## Trust boundaries

| Component | Trusted for | Not trusted for |
| --- | --- | --- |
| Mac daemon | PTY ownership, session state, capability issuance, peer authorization | — |
| iPhone app | Paired identity, user confirmation, TLS peer verification | — |
| Relay | Matching two authorized connection attempts and forwarding bytes | TLS termination, session authorization, shell creation, terminal interpretation |
| CloudKit/APNs | Short-lived rendezvous metadata and wake/refetch hints | Terminal transport, relay authorization, or certificate trust |
| Network and provider logs | Delivery only | Confidentiality, integrity, or deletion outside the documented operator boundary |

The relay sees connection timing, byte counts, network addresses, and an opaque
short-lived match identifier while a connection is active. It must not see
terminal plaintext, protocol semantics, pairing secrets, certificates, private
keys, prompts, commands, output offsets, or output.

## Threat model and controls

| Threat | Required control |
| --- | --- |
| Relay reads terminal content | End-to-end Clive TLS remains between Mac and iPhone; relay forwards bytes only. |
| Relay authorizes an unpaired client | Pinned mutual TLS and Mac-side pairing state remain authoritative; relay credentials cannot authorize a session. |
| Capability replay or theft | Single-use, connection-scoped capabilities with short expiry, peer/session binding, atomic consumption, and revocation. |
| Cross-device or cross-session mix-up | Match records include the paired-device and session context; both TLS peers verify the expected identity. |
| Stale route survives disablement or revocation | Local invalidation prevents new connections immediately; relay rejects invalidated capabilities. |
| Relay is used as a preferred or covert path | Route priority is explicit, relay is fallback-only, and V1 exposes no relay candidate until launch approval. |
| Resource exhaustion or cost abuse | Per-capability connection, duration, bandwidth, idle, and concurrency quotas; abuse response and a kill switch. |
| Metadata reconstructs a session | No terminal-content retention, no persistent session history, minimal active metadata, and deletion shortly after both peers disconnect. |
| Operator compromise | Minimize relay authority and stored data; retain end-to-end TLS and require independent security review before production. |
| Provider-side logging leaks sensitive metadata | Document provider retention and logging, use privacy-preserving aggregate metrics, and do not send secrets or terminal data to the provider. |

## Retention, quotas, and monitoring

The relay stores only the minimum active mapping needed to join two streams.
Mappings and connection metadata are deleted shortly after both peers
disconnect, subject to a documented operational deletion bound. No terminal
content, credentials, decrypted protocol data, or persistent session history is
stored.

Production limits must cover concurrent connections, connection duration,
bandwidth, idle time, capability issuance, and retry volume. Monitoring may
record aggregate availability, latency, rejection classes, and resource usage
only when it cannot identify a user or reconstruct a session. Logs must use
opaque identifiers and bounded retention, and must never contain terminal
bytes, pairing payloads, credentials, private keys, or certificate material.

## Launch gates

Relay implementation and production enablement require all of the following:

- An identified operator and documented deployment, cost, abuse, and incident
  response ownership.
- A reviewed capability issuance, rotation, expiry, revocation, and quota
  design.
- A privacy and retention review covering the relay and its infrastructure
  providers.
- Independent security review confirming that the relay cannot terminate Clive
  TLS, authorize sessions, expose terminal data, or create shells.
- Automated tests for expiry, replay, mismatch, revocation, disablement,
  relay absence, bounded backpressure, and opaque forwarding.
- A user-visible policy or setting stating whether relay access is enabled.
- A kill switch that disables relay without disabling direct LAN, private VPN,
  or WAN/cellular routes.

Until every gate is recorded as approved, Issue #163 remains deferred and the
V1 behavior is direct-route-only.
