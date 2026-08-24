# Releases and versioning

Clive uses Semantic Versioning. Before 1.0 stability is declared, prereleases may change behavior and compatibility. GitHub Releases distribute the notarized Apple-silicon macOS package through the official Homebrew tap; iOS prereleases are distributed only through TestFlight, with no public invitation link currently advertised.

## User installation

On an Apple-silicon Mac running macOS 14 or later, install the macOS companion with:

```sh
brew install --cask brendanwilliam/tap/clive
```

The cask installs `/Applications/Clive.app` and `/usr/local/bin/clive`. Update with `brew upgrade --cask brendanwilliam/tap/clive` and remove the installed payload with `brew uninstall --cask clive`; ordinary uninstall preserves the user-scoped pairing state. Use `brew uninstall --cask --zap clive` only to remove that state and require every device to pair again. The tap tracks prereleases as well as stable versions.

As a manual fallback, download `clive.pkg` and its checksum from [GitHub Releases](https://github.com/brendanwilliam/clive/releases), verify it with `shasum -a 256 -c clive.pkg.sha256`, then open the package. Source builds remain supported through the steps in the root README.

## Maintainer release process

The `Release macOS and iOS` workflow validates a shared version, verifies both platforms, publishes the signed/notarized macOS package, and uploads the same commit to TestFlight. Run it from `main` only after physical-device acceptance and Production CloudKit schema deployment.

The protected `macos-release` environment contains `APPLE_TEAM_ID`, `CLIVE_MAC_BUNDLE_ID`, `CLIVE_ICLOUD_CONTAINER`, App Store Connect API credentials, Developer ID application/installer certificates, the Developer ID provisioning profile, and `HOMEBREW_TAP_TOKEN`. `HOMEBREW_TAP_TOKEN` is a dedicated fine-grained token limited to **Contents: write** on `brendanwilliam/homebrew-tap`; it must not be reused for other repositories or written to logs. The protected `testflight` environment contains the iOS bundle/team variables, App Store Connect API credentials, Apple development/distribution certificates, and app/widget provisioning profiles. Secrets must never be written to logs or committed.

Only a repository owner or administrator may dispatch the coordinated workflow. Use `./scripts/update-builds.sh [version] --cloudkit-production-schema-deployed` from a clean `main` checkout that exactly matches `origin/main`; it validates the caller's repository permission before dispatching, and the workflow repeats that authorization check. When `version` is omitted, the command increments the patch number from the latest stable release tag. Add `--release` for a non-prerelease GitHub Release.

Use a new `vMAJOR.MINOR.PATCH` tag, keep early releases marked prerelease, and never overwrite a published tag. The existing `v1.0.1` prerelease satisfies the initial launch-tag requirement. Platform-specific workflows are reserved for deliberate recovery from a partial coordinated release.

After the GitHub Release is created, the macOS workflow updates `Casks/clive.rb` in `brendanwilliam/homebrew-tap` with its version and SHA-256. A cask-update failure intentionally fails the workflow without replacing the published release or tag. Restore the tap credential or release metadata, then rerun `scripts/update-homebrew-cask.sh <version>` from the release checkout with the dedicated token and the release token available in the environment. The tap CI audits the cask and installs it in a clean macOS environment before verifying the CLI and companion app.

Update `CHANGELOG.md`, confirm checksums and notarization, install on clean devices, verify pairing/revocation/backgrounding/cellular behavior, and confirm logs contain no secrets or terminal content before announcing a release.
