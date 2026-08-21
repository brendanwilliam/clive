# Repository Guidelines

## Project Structure & Module Organization

This repository currently contains the product specification; application code has not yet been added. Keep the root `README.md` as the project entry point and keep design requirements in `docs/`:

- `docs/architecture.md` defines the iOS client, macOS CLI, and shared Swift-package boundaries.
- `docs/protocol.md` defines discovery, pairing, TLS sessions, and binary frames.
- `docs/security.md` contains non-negotiable security controls and validation requirements.
- `docs/roadmap.md` sequences implementation work.

When implementation begins, place shared protocol and cryptography code in a Swift package, platform code in clearly named iOS/macOS targets, and tests alongside their target or in conventional `Tests/` directories.

## Build, Test, and Development Commands

Run `./scripts/verify-local.sh` for the authoritative quick compatibility check: it executes `swift test` and builds both app targets. Use `./scripts/verify-local.sh --signed` only when local signing readiness matters. `./scripts/test-macos-integration.sh` covers localhost TLS/PTY behavior, and `./scripts/build-pkg.sh` builds the macOS installer. Do not commit Xcode `DerivedData/`, SwiftPM `.build/`, provisioning files, or local pairing state; these are ignored already.

## Coding Style & Naming Conventions

Use native Swift conventions: four-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and local values. Name protocol frames and CLI commands exactly as specified, such as `session.open`, `terminal.resize`, and `clive revoke <device-id>`. Prefer small, explicit types over unstructured dictionaries. Add the selected formatter/linter and its command when code tooling is introduced.

## Testing Guidelines

Add automated tests with each behavioral change. Test names should describe the expected outcome, e.g. `testExpiredPairingSecretIsRejected`. At minimum, cover malformed and oversized frames, expired or reused pairing secrets, changed/untrusted certificates, revocation, disconnect cleanup, and bounded output backpressure. Include localhost TLS/PTY integration tests for the macOS service and UI tests for iOS pairing and biometric cancellation where practical.

## Commit & Pull Request Guidelines

Use concise, imperative commit subjects, consistent with the existing history: `Add initial product and security specification`. Keep commits focused. Pull requests should explain the user-visible or security impact, link the relevant issue or roadmap item, list tests run, and include screenshots for iOS UI changes. Highlight any change to pairing, certificate validation, logging, permissions, or LAN exposure for focused security review.
