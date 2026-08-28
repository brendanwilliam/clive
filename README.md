# Clive

[![Continuous integration](https://github.com/brendanwilliam/clive/actions/workflows/verify-develop.yml/badge.svg?branch=develop)](https://github.com/brendanwilliam/clive/actions/workflows/verify-develop.yml)
[![Main compatibility](https://github.com/brendanwilliam/clive/actions/workflows/verify.yml/badge.svg?branch=main)](https://github.com/brendanwilliam/clive/actions/workflows/verify.yml)
[![Release](https://img.shields.io/github/v/release/brendanwilliam/clive?include_prereleases)](https://github.com/brendanwilliam/clive/releases)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-0a84ff)
![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![License: GPL v3+](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

Securely access your Mac terminal from your iPhone, over your LAN or direct cellular connections.

Clive combines a native SwiftUI terminal client with a user-started macOS menu bar companion and CLI. Pair with a short-lived QR code, approve the Mac's displayed fingerprint, and open independently isolated terminal tabs over mutually authenticated TLS.

> [!WARNING]
> Clive is prerelease software. It has not completed every physical-device release gate; do not rely on it for unattended or production access.

## Contents

- [Quick install for users](#quick-install-for-users)
- [Install for local development](#install-for-local-development)
  - [Install prerequisites](#1-install-prerequisites)
  - [Clone and test the repository](#2-clone-and-test-the-repository)
  - [Generate and open the app projects](#3-generate-and-open-the-app-projects)
- [Architecture and security](#architecture-and-security)
- [Troubleshooting](#troubleshooting)
- [Project](#project)
- [License and trademarks](#license-and-trademarks)

## Quick install for users

Use this path if you want to run Clive without building the project yourself.
You need an Apple-silicon Mac running macOS 14 or later and an iPhone running
iOS 17 or later. The devices should be on the same LAN, unless you have
configured optional direct cellular access.

Install the Apple-silicon macOS companion with Homebrew (macOS 14 or later):

```sh
brew install --cask brendanwilliam/tap/clive
```

This installs `/Applications/Clive.app` and `/usr/local/bin/clive`. Use `brew upgrade --cask brendanwilliam/tap/clive` to update. Ordinary uninstall preserves your local pairing state:

```sh
brew uninstall --cask clive
```

Use `brew uninstall --cask --zap clive` only when you want to erase Clive's local pairing state and pair every device again. The tap follows prereleases as well as stable releases, so prerelease updates may be offered before the next stable version.

If Homebrew is unavailable, download `clive.pkg` and `clive.pkg.sha256` from [GitHub Releases](https://github.com/brendanwilliam/clive/releases), verify the checksum, and open the installer:

```sh
shasum -a 256 -c clive.pkg.sha256
```

Clive for iPhone is available through the public [TestFlight invitation](https://testflight.apple.com/join/SUcN1FkH). This invitation only installs the iPhone app; it is not a pairing code. Contributors and testers can also build it from source.

1. Open `/Applications/Clive.app` on the Mac.
2. In Terminal, run `clive pair`. If the companion is installed but not running, the command starts it automatically and waits for the control socket.
3. In the iOS app, choose **Pair a Mac**, scan the separately labeled secure **Pair this iPhone** code, and approve the displayed device fingerprint on the Mac. That code is single-use and expires after one minute.
4. Select the paired Mac and open a terminal.

Press Ctrl-C during `clive pair` to invalidate the pending code. If the daemon
cannot be started, the command reports the recovery action without exposing the
pairing ticket or other secrets. Pairing and macOS configuration are CLI-owned;
the menu bar companion reports status and active terminals.

The macOS companion owns resumable shells. Closing a window or briefly losing transport detaches a session; stopping Clive, revoking the device, closing the terminal, shell exit, or the 90-minute detached-session expiry ends it.

Connectivity prefers LAN, then an available private VPN, direct WAN/cellular, and
finally the disabled-by-default relay extension. A route change authenticates the
new path and resumes the same session; it does not create a replacement shell.
See the [connectivity architecture](docs/connectivity-architecture.md) and
[connectivity verification](docs/connectivity-verification.md) for the V1 boundary
and release-blocking checks.

To start Codex in a managed, resumable terminal, run:

```sh
clive codex [codex arguments...]
clive codex resume [codex resume arguments...]
```

The wrapper uses the daemon's controlled environment and never logs Codex
arguments or terminal content. A resume command starts Codex in a new
Clive-managed PTY; Clive does not adopt an existing terminal emulator session.

## Install for local development

Use this path if you are contributing code, building features locally, or
running Clive from a checkout. The shared packages and CLI build without Apple
signing credentials. Building or running the iOS and macOS apps requires an
Apple-silicon Mac running macOS 14 or later, Xcode 26.5 or later, Swift 6, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Physical-device development
also requires local signing setup.

### 1. Install prerequisites

Use an Apple-silicon Mac running macOS 14 or later with Xcode 26.5 or later and
Swift 6. Install [Homebrew](https://brew.sh/) if it is not already available,
then install XcodeGen:

```sh
brew install xcodegen
```

Open Xcode once and accept its license and any requested additional components.

### 2. Clone and test the repository

```sh
git clone https://github.com/brendanwilliam/clive.git
cd clive
swift package resolve
swift test
swift build --product clive
swift run --product clive status
```

### 3. Generate and open the app projects

The Xcode projects are generated from `project.yml` files. Regenerate them after
changing a project definition or checking out a branch that changes one:

```sh
xcodegen generate --spec Apps/Clive/project.yml
xcodegen generate --spec Apps/CliveMac/project.yml
open Apps/Clive/Clive.xcodeproj
open Apps/CliveMac/CliveMac.xcodeproj
```

For the normal development loop, run `./scripts/check-fast.sh`. Rebuild only the
target you need with `./scripts/rebuild-local.sh cli` or
`./scripts/rebuild-local.sh app`; the app rebuild does not boot a Simulator. Run
`./scripts/verify-local.sh` only for `develop` to `main` integration, release
preparation, or platform diagnosis. Pass `--signed` only when checking local
signing readiness.
Use `./scripts/script-performance.sh` to see each development script's total runs,
average duration, failed runs, and five most recent durations. Samples stay local in
`scripts/script-runs.tsv`, which is gitignored. Script logs and run artifacts are
collected under the gitignored `scripts/outputs/` folder; full verification logs
are in `scripts/outputs/local-verify/logs`.
Local bundle identifiers and signing settings belong in an ignored `Local.xcconfig`;
see the example files in each app's `Config` directory.

For the quickest physical-device development loop, connect and unlock an iPhone, configure `Apps/Clive/Config/Local.xcconfig` and `Apps/CliveMac/Config/Local.xcconfig`, then run `./scripts/update-local.sh`. It builds and launches the locally signed macOS companion, preserving the CloudKit entitlement required for cellular testing; then it builds, installs, and launches the iOS app on the connected phone. Use `./scripts/update-local.sh --without-cellular` to run the standalone development daemon instead. Cellular setup remains subject to the companion's owner-controlled setting and the iPhone's cellular-route opt-in. Both refresh modes replace the current Mac owner and end its active terminal sessions. When launched from a Clive terminal, the script automatically hands the rebuild to `launchd` before restarting the owner, because that restart closes the terminal that initiated it. Progress is written to `scripts/outputs/device-run/refresh.log`; the app reconnects when the deployment finishes. Set `CLIVE_IOS_DESTINATION_ID` when more than one physical iOS device is connected.

To publish a coordinated `main` release, an administrator runs `./scripts/update-builds.sh [version] --cloudkit-production-schema-deployed`. It verifies that local `main` exactly matches `origin/main`, requires administrator permission, then dispatches the signed/notarized macOS package and TestFlight upload workflow. If `version` is omitted, it increments the patch number from the latest stable release tag. Add `--release` to create a non-prerelease GitHub Release.

## Architecture and security

The shared Swift package defines frames, pairing, trust, backpressure, rendezvous, and security primitives. The macOS app owns authenticated listeners and PTYs; the `clive` executable controls it over a user-only local socket. The iOS app stores paired Macs and opens one mutually authenticated TLS/PTY session per terminal tab.

Local-network access is the default. Optional cellular access publishes encrypted, short-lived rendezvous metadata in the user's private CloudKit account; terminal traffic stays direct and CloudKit never transports terminal input or output. Cryptographic identities remain device-local and owner protected. Backgrounding the iOS app closes and obscures terminals.

Read the [architecture](docs/architecture.md), [wire protocol](docs/protocol.md), and [security model](docs/security.md) before changing trust boundaries.

## Troubleshooting

- **No Mac appears:** confirm the companion is running and both devices are on a LAN that permits Bonjour and peer connections.
- **Startup rejects the network:** Clive requires RFC1918 IPv4, IPv6 ULA/link-local, or loopback by default. `--allow-non-private-network` is for deliberate development testing only.
- **The CLI cannot reach the companion:** stop any separately launched foreground daemon that owns the control socket, then reopen the app.
- **Pairing expired:** generate a new QR code; pairing codes expire after one minute and cannot be reused.
- **A certificate changed:** do not bypass the warning. Revoke the device and pair again only after verifying why its identity changed.

Please use the [bug form](https://github.com/brendanwilliam/clive/issues/new?template=bug_report.yml) for reproducible problems and [report vulnerabilities privately](SECURITY.md).

## Project

- [Contributing](CONTRIBUTING.md)
- [Development branch policy](docs/development-branch-policy.md)
- [Agent-ready issue automation](docs/agent-ready-automation.md)
- [Roadmap](docs/roadmap.md)
- [Changelog](CHANGELOG.md)
- [Releases and versioning](docs/releases.md)
- [V1 release readiness](docs/release-readiness.md)
- [Privacy](PRIVACY.md)
- [Governance](GOVERNANCE.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

## License and trademarks

Copyright © 2026 Brendan Keane. Source code and documentation are licensed under [GPL-3.0-or-later](LICENSE). The Clive name, logo, app icons, and branded launch artwork are not licensed under the GPL; see the [trademark and brand policy](TRADEMARKS.md).
