# iphone-terminal

`iphone-terminal` is a native iOS client and macOS companion for using a paired Mac's terminal from an iPhone.

The first release is deliberately **local-network only**: the iPhone and Mac must be on the same LAN. Pairing and terminal traffic are end-to-end encrypted, and a paired phone never receives access unless the Mac companion is running.

## Product shape

- **iOS app:** SwiftUI terminal client with a touch-friendly terminal view, saved paired Macs, and Face ID/Touch ID protection.
- **macOS companion:** a user-started CLI service that exposes an interactive PTY-backed `zsh` session under the invoking macOS account.
- **Pairing:** the Mac prints a short-lived QR code; scanning it creates a mutually authenticated device relationship.

## Prototype status

The end-to-end prototype is implemented: the foreground daemon owns its authenticated listeners and control socket, pairing is QR-pinned and locally approved, each iOS tab owns an independent mutually authenticated TLS/PTY session, and app backgrounding closes and obscures every terminal. Physical-device acceptance remains a required release gate.

## Development

```sh
swift test
./scripts/test-macos-integration.sh
swift run iphone-terminald status
cd Apps/iPhoneTerminal && xcodegen generate
xcodebuild -project iPhoneTerminal.xcodeproj -scheme iPhoneTerminal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
./scripts/build-pkg.sh
```

`swift test` runs shared protocol and pairing tests. Startup requires RFC1918 IPv4, IPv6 ULA/link-local, or loopback connectivity unless `--allow-non-private-network` is supplied. The packaging script creates an unsigned arm64 development PKG by default; set `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER`, and optionally `NOTARY_PROFILE` for signing and notarization.

The PKG installs only `/usr/local/bin/iphone-terminald`, with no launch agent or privileged helper. Run `iphone-terminald start` in one terminal, then use `pair`, `status`, `revoke <device-id>`, and `stop` from another. The control socket and state live under `~/Library/Application Support/iphone-terminal`; the certificate and encrypted P-256 PKCS#12 identity are mode `0600`.

To remove the prototype, delete `/usr/local/bin/iphone-terminald`. Remove the Application Support directory separately only when you also intend to erase the daemon identity and every pairing.

## Physical-device acceptance

Before calling a build complete, install the PKG on an Apple-silicon Mac and the app on an iOS 17+ iPhone, pair and approve the displayed fingerprint, open three tabs, and verify command/resize isolation. Then exercise Wi-Fi loss, app backgrounding, Mac sleep/wake, daemon exit, and revocation. Confirm logs and stored files contain no QR secret or terminal input/output.

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
