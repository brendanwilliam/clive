# Protocol and lifecycle

Protocol v3 is a coordinated Mac and iOS/TestFlight upgrade. Existing pairing records remain valid, but v2 frames are rejected before `session.open` can allocate a PTY. A Mac accepts one paired iPhone at a time. Sessions use stable server IDs and support iPhone and Mac CLI attachment through session list, attach, attachment-state, resize-claim, and explicit-termination frames.

Terminal output carries a monotonically increasing byte offset. Reconnecting clients supply their last received offset; the daemon returns bounded replay and reports truncation when that offset predates the replay ring. Sessions are scoped to one paired certificate and allow at most one attachment. A reconnect from the same endpoint replaces its prior attachment; a different endpoint is rejected.

## Discovery

The Mac advertises `_iphone-term._tcp` with a non-secret service identifier, protocol version, and TLS port in Bonjour TXT records. Discovery is a convenience only; trust never comes from the service name, hostname, IP address, or Bonjour metadata.

## Pairing

For opted-in cellular access, the same-account CloudKit private database stores short-lived per-device encrypted `RendezvousV1`, `ReachabilityHintV1`, and `ReachabilityResultV1` envelopes. APNs only prompts a refetch. Public IPv6 is preferred; CloudKit and APNs never carry terminal frames. Non-private `session.open` messages include the current WAN gate token, while authenticated local sessions exchange optional rendezvous capabilities to upgrade existing pairings. Setup verification uses `reachability.probe` as the first mutually authenticated TLS frame; it must match the current rendezvous challenge and gate token, replies with `reachability.verified`, and cannot allocate a PTY.

1. The Mac user chooses **Pair iPhone** in the menu-bar app (or uses `clive pair` as a terminal fallback) and confirms the request locally.
2. The daemon creates a single-use pairing ticket that expires after 5 minutes. It uses the same persistent P-256 identity used by sessions.
3. It displays a compact `CL2:` Base45 QR containing the temporary endpoint, version, expiry, one-time secret, and persistent daemon certificate fingerprint. The QR contains no private key. The iOS app accepts only this current format; older JSON/Base64 payloads fail closed and require a new pairing code.
4. The iOS app scans the code, generates its own device key pair in the Keychain/Secure Enclave when available, and connects using TLS.
5. The one-time secret authorizes exchange of the two public certificates. Each side stores the peer certificate fingerprint, device identifier, and creation time as its pairing record.
6. The Mac reports the iPhone device name and fingerprint for local confirmation, then invalidates the one-time secret.

The pairing endpoint accepts only one successful exchange. Expired, consumed, or malformed QR payloads fail without creating a device record.

## Session setup

- TCP is protected by TLS 1.3 with client and server certificate authentication.
- The peer certificate must exactly match the stored fingerprint for the selected pairing record.
- TLS errors, certificate changes, protocol-version incompatibility, or missing biometric authorization terminate the attempt before shell creation.
- The app sends `session.open` only after mutual TLS completes. The Mac responds with `session.opened` containing an opaque session ID, a `created` or `resumed` disposition, and a replay-truncation flag. These current fields are required.
- One TLS connection is either a foreground `session.list` subscription or one terminal attachment. Catalog subscriptions never count as terminal attachments.

## Framing

Application records are length-prefixed binary frames over TLS:

| Frame | Direction | Purpose |
| --- | --- | --- |
| `session.open` | iOS → Mac | Create or resume a client-owned shell. |
| `session.opened` | Mac → iOS | Confirm shell creation and return its opaque session ID. |
| `session.list` / `session.list.result` | iOS ↔ Mac | Subscribe to initial and changed catalog snapshots while foregrounded and unlocked. |
| `session.attach` | iOS → Mac | Attach to an existing stable server session ID with an output offset and viewport; never creates a PTY. |
| `attachment.state` | Mac → client | Report attachment count, resize owner, and current output offset. |
| `resize.claim` | client → Mac | Claim resize ownership and immediately apply the attachment's stored viewport. |
| `session.close` | client → Mac | Detach this transport while retaining the PTY for the grace period. |
| `session.terminate` | client → Mac | Explicitly end the shared PTY for every attachment. |
| `pairing.revoke` / `pairing.revoked` | iOS ↔ Mac | Revoke the authenticated iPhone and acknowledge persisted removal. |
| `terminal.input` | iOS → Mac | UTF-8/control bytes to the PTY. |
| `terminal.output` | Mac → iOS | Raw PTY output bytes. |
| `terminal.resize` | iOS → Mac | Terminal columns and rows. |
| `session.error` | Either | Non-sensitive structured failure code. |

Frames have a bounded maximum size and an explicit protocol version. The Mac rejects unknown mandatory frame types and closes malformed or oversized records. The service must apply backpressure so a slow iPhone cannot cause unbounded PTY output buffering.

## Session lifecycle

Each authenticated device ID and stable client session ID maps to one PTY and login shell. A PTY has at most one terminal attachment. Network loss and ordinary navigation detach that attachment; after the final detach the Mac retains the shell for 30 minutes. Detached output does not extend the timer. Up to 1 MiB of output is replayed in order, with oldest bytes discarded and truncation reported. Output is offset-tagged; a bounded slow consumer is evicted without suspending the PTY.

Every input frame is written atomically on the session queue. The active attachment owns the terminal viewport. Explicit `session.terminate`, shell exit, grace expiry, revocation, and daemon shutdown terminate the PTY everywhere. Shell exit sends `session.close` to the current attachment. The iOS app persists only opaque session IDs and labels, never terminal contents.

Successful terminal input and produced output refresh one daemon-wide idle-system-sleep assertion for 30 minutes. Pairing, authentication, resize traffic, and idle connections do not. Display sleep, explicit Sleep, lid close, shutdown, and system policy remain unaffected.

`session.open` may include a working directory. An omitted or empty value uses the Mac user's home directory; the daemon expands `~/`, rejects unavailable directories, and changes directory before starting the login shell. A phone-initiated `pairing.revoke` is bound to the mutual-TLS peer identity and cannot name or revoke another device. The iPhone removes its local pairing only after `pairing.revoked` is received.
