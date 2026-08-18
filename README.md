# iphone-terminal

`iphone-terminal` is a native iOS client and macOS companion for using a paired Mac's terminal from an iPhone.

The first release is deliberately **local-network only**: the iPhone and Mac must be on the same LAN. Pairing and terminal traffic are end-to-end encrypted, and a paired phone never receives access unless the Mac companion is running.

## Product shape

- **iOS app:** SwiftUI terminal client with a touch-friendly terminal view, saved paired Macs, and Face ID/Touch ID protection.
- **macOS companion:** a user-started CLI service that exposes an interactive PTY-backed `zsh` session under the invoking macOS account.
- **Pairing:** the Mac prints a short-lived QR code; scanning it creates a mutually authenticated device relationship.

## Prototype status

Implemented foundations include the bounded V1 protocol, ticket and trust stores, persistent macOS TLS identity, PTY session state machine with output backpressure, private-interface detection, QR scanning, Keychain paired-Mac storage, a pinned TLS iOS client, and a SwiftTerm bridge. Physical-device pairing and foreground daemon control-socket orchestration remain before this is safe to use as a terminal service.

## Development

```sh
swift test
swift run iphone-terminald status
cd Apps/iPhoneTerminal && xcodegen generate
xcodebuild -project iPhoneTerminal.xcodeproj -scheme iPhoneTerminal -sdk iphonesimulator test
./scripts/build-pkg.sh
```

`swift test` runs shared protocol and pairing tests. Startup requires RFC1918 IPv4, IPv6 ULA/link-local, or loopback connectivity unless `--allow-non-private-network` is supplied. The packaging script creates an unsigned arm64 development PKG by default; set `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER`, and optionally `NOTARY_PROFILE` for signing and notarization.

The PKG installs only `/usr/local/bin/iphone-terminald`, with no launch agent or privileged helper. Remove that binary to uninstall; user state remains under `~/Library/Application Support/iphone-terminal` unless removed separately.

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
