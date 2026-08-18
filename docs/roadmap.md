# Implementation roadmap

## 1. Foundation — implemented

- Create the shared Swift package for protocol types, TLS identity handling, bounded framing, and test fixtures.
- Define protocol compatibility/versioning and secure local pairing-record storage.

## 2. macOS companion — implemented

- Implement the foreground CLI, Bonjour advertisement, QR pairing, mutual-TLS listener, PTY management, and revocation/status commands.
- Add integration tests that drive a shell through a localhost TLS session.

## 3. iOS client — implemented

- Build the SwiftUI paired-Mac list, QR scanner, biometric gate, connection states, and VT-compatible terminal view.
- Add Keychain identity storage and UI tests for pairing, reconnecting, errors, and revocation.

## 4. Hardening and release preparation — automated; device acceptance pending

- Exercise the security validation requirements in [security.md](security.md).
- Test real-device pairing across common home and office LANs, connection loss, macOS sleep/wake, terminal resizing, and CLI shutdown.
- Add privacy documentation and a clear user-facing warning that terminal access has the permissions of the Mac account running the CLI.

## Future: secure internet access

Design WAN connectivity as a new trust boundary. Evaluate a user-managed mesh VPN (such as Tailscale/WireGuard) before any hosted relay. Reuse the V1 mutual-TLS pairing identity; do not treat network membership or a cloud account as a substitute for device authentication.
