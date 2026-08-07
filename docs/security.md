# Security model

## Security goals

- Only an explicitly paired iPhone can open a shell on the Mac.
- Terminal commands and output remain confidential and integrity-protected on the local network.
- The Mac user can see, stop, and revoke remote terminal access at any time.
- A network attacker cannot substitute a discovered Mac or phone for a paired device.

## Trust boundaries

Bonjour and the LAN are untrusted. The QR code is an out-of-band authorization channel and must be treated as sensitive for its 5-minute lifetime. The iOS device protects its long-lived private key in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; Secure Enclave storage is used where supported. The Mac stores pairing records with owner-only filesystem permissions in its application-support directory.

## Controls

- TLS 1.3 and mutual certificate authentication protect every session.
- Pairing QR codes are single-use, short-lived, and require a local Mac-user confirmation.
- The iOS app requires biometrics before initiating or resuming a connection.
- Certificate pinning binds each saved Mac and iPhone to the pairing established over the QR flow.
- The macOS service is foreground and user-scoped; it never runs as root and never elevates privileges.
- Device revocation deletes the trust record and ends active connections immediately.
- Logs contain lifecycle metadata only—timestamps, opaque device IDs, and failure codes—not shell commands, output, QR payloads, secrets, or private keys.

## Explicit limitations

Physical access to an unlocked iPhone or Mac user session remains a risk. V1 has no account recovery and no relay; losing a phone requires revocation from the Mac. The service must warn before binding to non-private networks and must provide a configuration option to disable LAN advertising entirely.

## Validation requirements

Automated tests must demonstrate rejection of expired/reused pairing secrets, untrusted or changed certificates, malformed/oversized frames, and revoked clients. Manual security review must include local-network spoofing attempts, QR interception during the pairing window, biometric cancellation, process termination, and secret/log inspection.
