# iphone-terminal

`iphone-terminal` is a native iOS client and macOS companion for using a paired Mac's terminal from an iPhone.

The first release is deliberately **local-network only**: the iPhone and Mac must be on the same LAN. Pairing and terminal traffic are end-to-end encrypted, and a paired phone never receives access unless the Mac companion is running.

## Product shape

- **iOS app:** SwiftUI terminal client with a touch-friendly terminal view, saved paired Macs, and Face ID/Touch ID protection.
- **macOS companion:** a user-started CLI service that exposes an interactive PTY-backed `zsh` session under the invoking macOS account.
- **Pairing:** the Mac prints a short-lived QR code; scanning it creates a mutually authenticated device relationship.

## Status

This repository currently contains the product and security specification only. No terminal service or iOS application has been implemented yet.

## Documentation

- [Architecture](docs/architecture.md)
- [Protocol and lifecycle](docs/protocol.md)
- [Security model](docs/security.md)
- [Implementation roadmap](docs/roadmap.md)

## Non-goals for version 1

- Internet/WAN access, relays, or cloud accounts
- Background launch daemons and unattended persistent access
- Multi-user shells or privilege escalation beyond the macOS user that started the companion

Secure internet access may be added later using a separately designed mesh VPN or relay architecture; it must not weaken the V1 pairing and mutual-authentication guarantees.
