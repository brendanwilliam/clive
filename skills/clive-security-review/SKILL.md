---
name: clive-security-review
description: Review security-sensitive Clive changes against documented trust and validation requirements. Use for pairing, certificates, authorization, key storage, logging, permissions, CloudKit, cellular routing, or LAN exposure; not for ordinary code review without a security boundary.
---

# Clive Security Review

Read `docs/security.md` and the affected sections of `docs/protocol.md` and `docs/architecture.md`. Treat them as requirements, not implementation suggestions. Do not weaken a control, assertion, entitlement, or trust check to make a test pass.

## Threat-model the change

Identify the protected asset, attacker capability, trust boundaries crossed, and the component that authorizes the operation. Trace untrusted input from discovery, network, control socket, CloudKit, local storage, and UI entry points through validation and side effects.

Review the affected path for:

- authentication and authorization before state changes or terminal access;
- certificate pinning and trust-record handling, including changed, expired, revoked, or untrusted identities;
- secret creation, expiry, one-time use, storage, deletion, and redaction from logs and errors;
- strict framing, size limits, state transitions, and rejection of malformed or out-of-order input;
- replay, downgrade, cross-device, cross-account, and confused-deputy opportunities;
- minimum permissions and exposure, including owner-only local IPC and intended LAN or cellular routing;
- fail-closed behavior and complete cleanup after rejection, timeout, cancellation, disconnect, revocation, or shutdown.

CloudKit and APNs are rendezvous and reachability mechanisms, never terminal transports or independent authorization sources. Discovery identifies candidates; it does not establish trust.

## Validation and report

Require focused tests for each affected control and meaningful negative path. Depending on scope, cover expired or reused pairing secrets, altered certificates, revocation, unauthorized control-socket clients, malformed or oversized frames, replayed messages, redaction, disconnect cleanup, and bounded backpressure. Use the integration and local-verification skills when their scopes apply.

Report findings by severity with the attack path, affected requirement, and concrete remediation. In the pull request, summarize the trust boundaries reviewed, security impact, controls preserved or added, and tests run. Explicitly say when no security weakness was found; do not imply that passing tests proves the design secure.
