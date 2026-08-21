# Contributing to Clive

Thanks for helping make Clive safer and more useful. By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up a development environment

Clive requires an Apple-silicon Mac, macOS 14 or later, Xcode 26.5 or later, Swift 6, and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Clone the repository, then run:

```sh
brew install xcodegen
./scripts/verify-local.sh
./scripts/test-macos-integration.sh
```

The iOS app supports iOS 17 or later. Copy `Apps/Clive/Config/Local.xcconfig.example` to `Local.xcconfig` only when local signing is needed; never commit signing material, credentials, pairing state, or generated Xcode projects.

## Make a change

- Open an issue before a large behavioral or protocol change.
- Use four-space indentation and standard Swift naming conventions.
- Keep protocol frame and CLI command names exactly as documented.
- Add tests with every behavioral change; name tests for the expected outcome.
- Do not make unrelated formatting changes.

Changes to pairing, certificate validation, key storage, logging, permissions, CloudKit, cellular routing, or LAN exposure require focused security review. Describe the threat-model impact in the pull request. Report suspected vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Verify and submit

Run the quick compatibility check and the localhost TLS/PTY integration test before opening a pull request. Use `./scripts/verify-local.sh --signed` when the change affects local signing. Follow the pull request template, link the issue, describe user-visible and security impact, and include sanitized screenshots for UI changes.

By contributing, you agree that your contributions are licensed under GPL-3.0-or-later. The Clive name and branded artwork remain subject to the [trademark policy](TRADEMARKS.md).
