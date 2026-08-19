# Clive

**Clive - CLI for iOS** is a lightweight, security-first way for developers and coding-agent users to access their Mac terminal from an iPhone.

The default is local-network only. An opt-in same-Apple-Account cellular mode publishes encrypted, short-lived direct-WAN rendezvous metadata through CloudKit; terminal traffic remains direct, mutually authenticated, and available only while the Mac companion is running.

## Product shape

- **iOS app:** SwiftUI terminal client with a touch-friendly terminal view, saved paired Macs, and Face ID/Touch ID protection.
- **macOS companion:** a signed, user-started menu bar app that owns listeners and PTYs; `clive` is its local control client.
- **Pairing:** the Mac prints a short-lived QR code; scanning it creates a mutually authenticated device relationship.

## Prototype status

The end-to-end prototype is implemented: the foreground daemon owns its authenticated listeners and control socket, pairing is QR-pinned and locally approved, each iOS tab owns an independent mutually authenticated TLS/PTY session, and app backgrounding closes and obscures every terminal. Physical-device acceptance remains a required release gate.

## Development

```sh
swift test
./scripts/test-macos-integration.sh
swift run clive status
cd Apps/iPhoneTerminal && xcodegen generate
xcodebuild -project iPhoneTerminal.xcodeproj -scheme iPhoneTerminal -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
./scripts/build-pkg.sh
```

`swift test` runs shared protocol and pairing tests. Startup requires RFC1918 IPv4, IPv6 ULA/link-local, or loopback connectivity unless `--allow-non-private-network` is supplied. The packaging script creates an unsigned arm64 development PKG by default; set `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER`, and optionally `NOTARY_PROFILE` for signing and notarization.

The PKG installs `/Applications/Clive.app` and `/usr/local/bin/clive`, with no launch agent or privileged helper. Run `clive start`, then use `pair`, `status`, `cellular <on|off>`, `revoke <device-id>`, and `stop`. Cellular access is disabled by default and remains visibly indicated in the menu bar while enabled. State remains under `~/Library/Application Support/iphone-terminal` so upgrades preserve identities and pairings; cryptographic identities remain device-local and owner protected.

To remove the prototype, delete `/usr/local/bin/clive` and the compatibility symlink `/usr/local/bin/iphone-terminald`. Remove the Application Support directory separately only when you also intend to erase the companion identity and every pairing.

## Get started

1. Install and open the Clive macOS companion.
2. Install **Clive - CLI for iOS** from the App Store.
3. Run `clive pair` on the Mac.
4. In the iOS app, choose **Pair a Mac**, scan the terminal's short-lived pairing QR code, and approve the displayed device fingerprint on the Mac.
5. Select the paired Mac and open a terminal.

An App Store discovery QR code only opens Clive's store listing. The pairing QR code is generated locally by `clive pair`, expires after five minutes, and authorizes exactly one pairing attempt. Neither QR code contains terminal content, credentials, or private keys.

## Migration from iPhone Terminal

The product and repository are now named Clive. Existing clones continue to work after GitHub's repository redirect; update remotes to `https://github.com/brendanwilliam/clive.git` when the repository rename is complete. The installer retains `iphone-terminald` as a symlink to `clive` for one migration cycle, but new instructions and scripts use `clive`. Existing bundle identifiers, Keychain services, protocol identifiers, and `~/Library/Application Support/iphone-terminal` are intentionally unchanged to preserve trusted devices and local state.

## Physical-device acceptance

Before calling a build complete, install the PKG on an Apple-silicon Mac and the app on an iOS 17+ iPhone, pair and approve the displayed fingerprint, open three tabs, and verify command/resize isolation. Then exercise Wi-Fi loss, app backgrounding, Mac sleep/wake, daemon exit, and revocation. Confirm logs and stored files contain no QR secret or terminal input/output.

## Documentation

- [Architecture](docs/architecture.md)
- [Protocol and lifecycle](docs/protocol.md)
- [Security model](docs/security.md)
- [Brand and product voice](docs/brand.md)
- [Implementation roadmap](docs/roadmap.md)

## Non-goals for version 1

- Automatic IPv4 NAT traversal, CGNAT bypass, or relays
- Background launch daemons and unattended persistent access
- Multi-user shells or privilege escalation beyond the macOS user that started the companion

Secure internet access may be added later using a separately designed mesh VPN or relay architecture; it must not weaken the V1 pairing and mutual-authentication guarantees.
