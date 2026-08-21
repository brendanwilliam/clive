# Protocol and lifecycle

## Discovery

The Mac advertises `_iphone-term._tcp` with a non-secret service identifier, protocol version, and TLS port in Bonjour TXT records. Discovery is a convenience only; trust never comes from the service name, hostname, IP address, or Bonjour metadata.

## Pairing

For opted-in cellular access, the same-account CloudKit private database stores short-lived per-device encrypted `RendezvousV1`, `ReachabilityHintV1`, and `ReachabilityResultV1` envelopes. APNs only prompts a refetch. Public IPv6 is preferred; CloudKit and APNs never carry terminal frames. Non-private `session.open` messages include the current WAN gate token, while authenticated local sessions exchange optional rendezvous capabilities to upgrade existing pairings. Setup verification uses `reachability.probe` as the first mutually authenticated TLS frame; it must match the current rendezvous challenge and gate token, replies with `reachability.verified`, and cannot allocate a PTY.

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
- The app sends `session.open` only after mutual TLS completes. The Mac responds with `session.opened` containing an opaque session ID, a `created` or `resumed` disposition, and a replay-truncation flag. Older replies without those fields mean `created` and not truncated.
- One TLS connection carries exactly one session and PTY. Multiple tabs use independent connections, so terminal frames need no session ID.

## Framing

Application records are length-prefixed binary frames over TLS:

| Frame | Direction | Purpose |
| --- | --- | --- |
| `session.open` / `session.close` | iOS → Mac | Request or end an interactive session. |
| `session.opened` | Mac → iOS | Confirm shell creation and return its opaque session ID. |
| `pairing.revoke` / `pairing.revoked` | iOS ↔ Mac | Revoke the authenticated iPhone and acknowledge persisted removal. |
| `terminal.input` | iOS → Mac | UTF-8/control bytes to the PTY. |
| `terminal.output` | Mac → iOS | Raw PTY output bytes. |
| `terminal.resize` | iOS → Mac | Terminal columns and rows. |
| `session.error` | Either | Non-sensitive structured failure code. |

Frames have a bounded maximum size and an explicit protocol version. The Mac rejects unknown mandatory frame types and closes malformed or oversized records. The service must apply backpressure so a slow iPhone cannot cause unbounded PTY output buffering.

## Session lifecycle

Each authenticated device ID and stable client session ID maps to one PTY and login shell. Network loss detaches only the transport and retains the shell for 30 minutes; detached output does not extend that retention timer. Up to 1 MiB of output is replayed in order on reattachment, with oldest bytes discarded and reported on overflow. A replacement TLS attachment supersedes the prior attachment, whose later input, resize, close, or disconnect events have no effect. Explicit close by the current attachment, shell exit, grace expiry, revocation, and daemon shutdown terminate the PTY immediately. Shell exit sends `session.close` to the current iOS attachment. The iOS app persists only opaque session IDs, never terminal contents.

Successful terminal input and produced output refresh one daemon-wide idle-system-sleep assertion for 30 minutes. Pairing, authentication, resize traffic, and idle connections do not. Display sleep, explicit Sleep, lid close, shutdown, and system policy remain unaffected.

`session.open` may include a working directory. An omitted or empty value uses the Mac user's home directory; the daemon expands `~/`, rejects unavailable directories, and changes directory before starting the login shell. A phone-initiated `pairing.revoke` is bound to the mutual-TLS peer identity and cannot name or revoke another device. The iPhone removes its local pairing only after `pairing.revoked` is received.
