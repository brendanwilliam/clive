# Security model

## Security goals

- Only an explicitly paired iPhone can open a shell on the Mac.
- Terminal commands and output remain confidential and integrity-protected on the local network.
- The Mac user can see, stop, and revoke remote terminal access at any time.
- A network attacker cannot substitute a discovered Mac or phone for a paired device.

## Trust boundaries

Bonjour and the LAN are untrusted. The QR code is an out-of-band authorization channel and must be treated as sensitive for its 5-minute lifetime. The iOS device protects its P-256 key in the Data Protection Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; Secure Enclave integration is deferred. macOS keeps the P-256 identity in an encrypted PKCS#12 file beside its random password, both owner-only, and stores pairing records with owner-only permissions.

## Controls

WAN, CloudKit records, APNs hints, endpoint metadata, and Apple Account membership are untrusted for terminal authorization. Cellular advertisements are encrypted and signed per paired phone, expire after five minutes, and carry replay metadata plus a random WAN gate token. Non-private inbound connections require that token in addition to pinned mutual TLS; disable and revocation invalidate tokens locally before cloud cleanup.

- TLS 1.3 and mutual certificate authentication protect every session.
- Pairing QR codes are single-use, short-lived, and require a local Mac-user confirmation.
- The iOS app requires biometrics before initiating or resuming a connection.
- Certificate pinning binds each saved Mac and iPhone to the pairing established over the QR flow.
- The macOS service is foreground and user-scoped; it never runs as root and never elevates privileges.
- Device revocation deletes the trust record and ends active connections immediately.
- Logs contain lifecycle metadata only—timestamps, opaque device IDs, and failure codes—not shell commands, output, QR payloads, secrets, or private keys.

## Explicit limitations

Physical access to an unlocked iPhone or Mac user session remains a risk. V1 has no account recovery and no relay; losing a phone requires revocation from the Mac. The service must warn before binding to non-private networks and must provide a configuration option to disable LAN advertising entirely.

The macOS identity password and encrypted identity share the same user-scoped directory, so filesystem access as that macOS user can recover the identity. This prototype does not claim protection from compromise of the invoking user account.

## Validation requirements

Automated tests must demonstrate rejection of expired/reused pairing secrets, untrusted or changed certificates, malformed/oversized frames, and revoked clients. Manual security review must include local-network spoofing attempts, QR interception during the pairing window, biometric cancellation, process termination, and secret/log inspection.
