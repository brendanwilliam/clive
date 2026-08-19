# Protocol and lifecycle

## Discovery

The Mac advertises `_iphone-term._tcp` with a non-secret service identifier, protocol version, and TLS port in Bonjour TXT records. Discovery is a convenience only; trust never comes from the service name, hostname, IP address, or Bonjour metadata.

## Pairing

For opted-in cellular access, the same-account CloudKit private database stores short-lived per-device encrypted `RendezvousV1` and `ReachabilityHintV1` envelopes. APNs only prompts a refetch. Public IPv6 is preferred; CloudKit and APNs never carry terminal frames. Non-private `session.open` messages include the current WAN gate token, while authenticated local sessions exchange optional rendezvous capabilities to upgrade existing pairings.

1. The Mac user chooses **Pair iPhone** in the menu-bar app (or uses `clive pair` as a terminal fallback) and confirms the request locally.
2. The daemon creates a single-use pairing ticket that expires after 5 minutes. It uses the same persistent P-256 identity used by sessions.
3. It displays a compact `CL2:` Base45 QR containing the temporary endpoint, version, expiry, one-time secret, and persistent daemon certificate fingerprint. The QR contains no private key. The iOS app continues to accept legacy v1 JSON/Base64 pairing codes.
4. The iOS app scans the code, generates its own device key pair in the Keychain/Secure Enclave when available, and connects using TLS.
5. The one-time secret authorizes exchange of the two public certificates. Each side stores the peer certificate fingerprint, device identifier, and creation time as its pairing record.
6. The Mac reports the iPhone device name and fingerprint for local confirmation, then invalidates the one-time secret.

The pairing endpoint accepts only one successful exchange. Expired, consumed, or malformed QR payloads fail without creating a device record.

## Session setup

- TCP is protected by TLS 1.3 with client and server certificate authentication.
- The peer certificate must exactly match the stored fingerprint for the selected pairing record.
- TLS errors, certificate changes, protocol-version incompatibility, or missing biometric authorization terminate the attempt before shell creation.
- The app sends `session.open` only after mutual TLS completes. The Mac responds with `session.opened` containing an opaque session ID.
- One TLS connection carries exactly one session and PTY. Multiple tabs use independent connections, so terminal frames need no session ID.

## Framing

Application records are length-prefixed binary frames over TLS:

| Frame | Direction | Purpose |
| --- | --- | --- |
| `session.open` / `session.close` | iOS → Mac | Request or end an interactive session. |
| `session.opened` | Mac → iOS | Confirm shell creation and return its opaque session ID. |
| `terminal.input` | iOS → Mac | UTF-8/control bytes to the PTY. |
| `terminal.output` | Mac → iOS | Raw PTY output bytes. |
| `terminal.resize` | iOS → Mac | Terminal columns and rows. |
| `session.error` | Either | Non-sensitive structured failure code. |

Frames have a bounded maximum size and an explicit protocol version. The Mac rejects unknown mandatory frame types and closes malformed or oversized records. The service must apply backpressure so a slow iPhone cannot cause unbounded PTY output buffering.

## Session lifecycle

Each session maps to one PTY and one login shell. Network loss closes the TLS connection and sends SIGHUP to its child process; V1 does not preserve disconnected shell sessions. Stopping the CLI closes listeners and all active PTYs. Revoking a phone closes all sessions authenticated by its certificate.
