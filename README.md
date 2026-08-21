# Clive

**Clive - CLI for iOS** is a lightweight, security-first way for developers and coding-agent users to access their Mac terminal from an iPhone.

The default is local-network only. An opt-in same-Apple-Account cellular mode publishes encrypted, short-lived direct-WAN rendezvous metadata through CloudKit; terminal traffic remains direct, mutually authenticated, and available only while the Mac companion is running.

## Product shape

- **iOS app:** SwiftUI terminal client with a touch-friendly terminal view, saved paired Macs, and Face ID/Touch ID protection.
- **macOS companion:** a signed, user-started menu bar app that owns listeners and PTYs; `clive` is its local control client.
- **Pairing:** the menu-bar app displays a short-lived QR code; scanning it creates a mutually authenticated device relationship.

## Prototype status

The end-to-end prototype is implemented: the foreground daemon owns its authenticated listeners and control socket, pairing is QR-pinned and locally approved, each iOS tab owns an independent mutually authenticated TLS/PTY session, and app backgrounding closes and obscures every terminal. Physical-device acceptance remains a required release gate.

## Development

```sh
swift test
./scripts/verify-local.sh
./scripts/test-macos-integration.sh
swift run clive status
cd Apps/Clive && xcodegen generate
xcodebuild -project Clive.xcodeproj -scheme Clive -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
./scripts/build-pkg.sh
```

`swift test` runs shared protocol and pairing tests. `verify-local.sh` runs those tests plus macOS and generic-iOS Debug builds in parallel; pass `--signed` when local development signing readiness matters. Startup requires RFC1918 IPv4, IPv6 ULA/link-local, or loopback connectivity unless `--allow-non-private-network` is supplied. The packaging script creates an unsigned arm64 development PKG by default; set `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER`, and optionally `NOTARY_PROFILE` for signing and notarization.

Pull requests and pushes to `main` run the same compatibility script in GitHub Actions. The coordinated release workflow reruns it before publishing either platform.

The PKG installs `/Applications/Clive.app` and `/usr/local/bin/clive`, with no launch agent or privileged helper. Run `clive start`, then use `pair`, `status`, `cellular <on|off>`, `cellular setup`, `cellular test`, `revoke <device-id>`, and `stop`. `clive cellular setup` launches the signed companion, guides automatic or manual routing, and waits for a paired iPhone to verify the route over cellular. Scripted forms are `cellular setup --automatic` and `cellular setup --manual --host <host> --external-port <port>`. If an unsigned foreground daemon owns the control socket, stop it before retrying; the CLI never borrows the app's CloudKit entitlement. Cellular access is disabled by default and remains visibly indicated in the menu bar while enabled. State remains under `~/Library/Application Support/clive` so upgrades preserve identities and pairings; cryptographic identities remain device-local and owner protected.

TestFlight uploads are performed by the manually triggered `Deploy iOS to TestFlight` GitHub Actions workflow. Signing and App Store Connect credentials live only in the protected `testflight` GitHub environment; see [the iPhone app release instructions](Apps/Clive/README.md#testflight-deployment) for setup.

### Publishing the macOS package

The manually triggered `Publish macOS package` workflow builds the Apple-silicon CLI and menu-bar app, signs them with Developer ID, notarizes and staples the installer, and publishes `clive.pkg` plus its SHA-256 checksum to a new GitHub Release.

For a coordinated tester release, run the manually triggered `Release macOS and iOS` workflow from `main`. It validates the shared version and Production CloudKit acknowledgement, runs the shared tests, publishes the notarized macOS package, and then uploads the same version and commit to TestFlight. The underlying platform workflows remain available for deliberate partial-release recovery.

Create a protected GitHub environment named `macos-release` with these variables:

- `APPLE_TEAM_ID`
- `CLIVE_MAC_BUNDLE_ID` (for example, `com.brendanwilliam.clive.mac`)
- `CLIVE_ICLOUD_CONTAINER` (the same production CloudKit container used by the iOS app)

Add these environment secrets:

- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`
- `APP_STORE_CONNECT_API_PRIVATE_KEY`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_PROVISIONING_PROFILE_BASE64`

The two certificate values are base64-encoded, password-protected PKCS#12 exports. The provisioning profile must be a **Developer ID** profile for the explicit Mac App ID and include its production iCloud and push-notification entitlements. Base64-encode binary inputs with `base64 -i <file> | pbcopy` on macOS. The App Store Connect API key must have permission to submit software for notarization.

Run the workflow from `main` with a new semantic version tag such as `v0.1.0`. Keep the first release marked as a prerelease until the package passes the physical-device acceptance checks below. A tag is created only after signing and notarization succeed; an existing release tag is never overwritten.

To remove the prototype, delete `/usr/local/bin/clive`. Remove the Application Support directory separately only when you also intend to erase the companion identity and every pairing.

## Get started

1. Install and open the Clive macOS companion.
2. Install **Clive - CLI for iOS** from the App Store.
3. Choose **Pair iPhone** from the Clive menu bar app. `clive pair` remains available when you need a terminal-only fallback.
4. In the iOS app, choose **Pair a Mac**, scan the terminal's short-lived pairing QR code, and approve the displayed device fingerprint on the Mac.
5. Select the paired Mac and open a terminal.

An App Store discovery QR code only opens Clive's store listing. The secure pairing QR code is generated by **Pair iPhone**, expires after five minutes, and authorizes exactly one pairing attempt. Neither QR code contains terminal content, credentials, or private keys.

## Migration notes

The product and repository are named Clive. Existing clones continue to work after GitHub's repository redirect; update remotes to `https://github.com/brendanwilliam/clive.git` when the repository rename is complete. New instructions and scripts use `clive` throughout.

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
