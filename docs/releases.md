# Releases and versioning

Clive uses Semantic Versioning. Before 1.0 stability is declared, prereleases may change behavior and compatibility. GitHub Releases distribute the notarized Apple-silicon macOS package; iOS prereleases are distributed only through TestFlight, with no public invitation link currently advertised.

## User installation

Download `clive.pkg` and its checksum from [GitHub Releases](https://github.com/brendanwilliam/clive/releases), verify it with `shasum -a 256 -c clive.pkg.sha256`, then open the package. The installer adds `/Applications/Clive.app` and `/usr/local/bin/clive`. Source builds remain supported through the steps in the root README.

## Maintainer release process

The `Release macOS and iOS` workflow validates a shared version, verifies both platforms, publishes the signed/notarized macOS package, and uploads the same commit to TestFlight. Run it from `main` only after physical-device acceptance and Production CloudKit schema deployment.

The protected `macos-release` environment contains `APPLE_TEAM_ID`, `CLIVE_MAC_BUNDLE_ID`, `CLIVE_ICLOUD_CONTAINER`, App Store Connect API credentials, Developer ID application/installer certificates, and the Developer ID provisioning profile. The protected `testflight` environment contains the iOS bundle/team variables, App Store Connect API credentials, Apple development/distribution certificates, and app/widget provisioning profiles. Secrets must never be written to logs or committed.

Only a repository owner or administrator may dispatch the coordinated workflow. Use `./scripts/update-builds.sh [version] --cloudkit-production-schema-deployed` from a clean `main` checkout that exactly matches `origin/main`; it validates the caller's repository permission before dispatching, and the workflow repeats that authorization check. When `version` is omitted, the command increments the patch number from the latest stable release tag. Add `--release` for a non-prerelease GitHub Release.

Use a new `vMAJOR.MINOR.PATCH` tag, keep early releases marked prerelease, and never overwrite a published tag. The existing `v1.0.1` prerelease satisfies the initial launch-tag requirement. Platform-specific workflows are reserved for deliberate recovery from a partial coordinated release.

Update `CHANGELOG.md`, confirm checksums and notarization, install on clean devices, verify pairing/revocation/backgrounding/cellular behavior, and confirm logs contain no secrets or terminal content before announcing a release.
