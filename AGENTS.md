# Repository Guidelines

## Project Structure & Module Organization

Clive is a native Swift project with shared packages and platform apps:

- `Sources/CliveCore`, `Sources/CliveSecurity`, and `Sources/CliveCloud` contain shared protocol, security, and rendezvous code.
- `Sources/CliveDaemon` contains the macOS daemon and `clive` command-line implementation.
- `Apps/CliveMac` contains the macOS companion app, and `Apps/Clive` contains the iOS app.
- `Tests/CliveCoreTests` and `Tests/CliveDaemonTests` contain Swift package tests. Keep new tests with the target whose behavior they cover.
- `docs/architecture.md`, `docs/protocol.md`, `docs/security.md`, and
  `docs/human-interface-guidelines.md` define product boundaries and non-negotiable
  behavior. Use `docs/apple-ui-kit-reference.md` for the corresponding native Apple UI
  elements.

Keep the root `README.md` as the project entry point. Do not commit Xcode `DerivedData/`, SwiftPM `.build/`, provisioning files, or local pairing state; these are ignored already.

## Task Routing

Repository skills are cumulative. Use every skill that applies to the requested work:

| Task | Skill |
| --- | --- |
| Initial UI feature-map creation, major rebuild, or new-platform inventory | `clive-create-feature-map` |
| UI work involving agentic workflows or user-facing workflow terminology | Add `clive-hig-audit` |
| Swift implementation or refactoring | `clive-swift-development` |
| Pairing, certificates, key storage, logging, permissions, CloudKit, cellular routing, LAN exposure, or other security-sensitive work | Add `clive-security-review` |
| Daemon, control-socket, localhost TLS, PTY, or macOS session-lifecycle integration | Add `clive-macos-integration` |
| Local compatibility checks or pre-PR verification | `clive-local-verify` |
| Coordinated macOS and iOS releases | `clive-release` |
| Deliberate physical-device recovery when losing the active terminal is acceptable | `clive-local-refresh` |

Use `./scripts/check-fast.sh` for the ordinary development and `develop` pull-request
loop. Reserve `clive-local-verify` and its simulator-based checks for `develop` to
`main` integration, release preparation, or platform build diagnosis. Keep
`clive-local-verify`, `clive-release`, and `clive-local-refresh` as the source of truth
for their scripts, authorization boundaries, and operational procedures.

UI feature-map maintenance is paused during the v1.1.0 epic. Do not update or validate
`docs/ui-feature-map.json`, append review records, or run feature-map freshness checks
until this requirement is explicitly restored.

## Workflow Rules
- At the start of any task that may use GitHub, run `gh auth status`.
- Check `gh auth status` before reporting any CLI or API issues.
- Make all changes on a feature branch based on `develop`
- Do not commit directly to `develop` or `main`
- Make sure to merge `develop` into your feature branch before starting work, running tests, or preparing PRs.

## Build, Test, and Development Commands

Run `./scripts/check-fast.sh` for ordinary changes. Use
`./scripts/rebuild-local.sh cli` or `./scripts/rebuild-local.sh app` to rebuild one
target without a full compatibility run or Simulator boot. Run
`./scripts/verify-local.sh` only for `develop` to `main` integration, release
preparation, or platform diagnosis. Use `./scripts/verify-local.sh --signed` only when
local signing readiness matters. `./scripts/test-macos-integration.sh` and
`./scripts/build-pkg.sh` are pre-main/release checks unless the task specifically
requires them.

The active development scripts record local timing samples automatically. Use
`./scripts/script-performance.sh` to review total runs, average duration, failures,
and the five most recent durations. Do not commit the machine-local metrics file.

## Coding Style & Naming Conventions

Use the [Google Style Guides](https://google.github.io/styleguide/) as the general code-style baseline and the [Google Swift Style Guide](https://google.github.io/swift/) for Swift source. Apply these standards to new and modified code; do not mass-format or otherwise rewrite unrelated code.

Clive's security specification, documented protocol and CLI names, platform constraints, and task-specific test requirements take precedence over external style guidance. Preserve exact names such as `session.open`, `terminal.resize`, and `clive revoke <device-id>`. Prefer small, explicit boundary types over unstructured dictionaries, and follow the existing file's conventions where the external guide permits alternatives.

## Testing Guidelines

Add automated tests with each behavioral change. Test names should describe the expected outcome, for example `testExpiredPairingSecretIsRejected`. At minimum, cover malformed and oversized frames, expired or reused pairing secrets, changed or untrusted certificates, revocation, disconnect cleanup, and bounded output backpressure when affected. Include localhost TLS/PTY integration tests for macOS service changes and UI tests for iOS pairing and biometric cancellation where practical.

Never weaken security controls, platform constraints, or assertions merely to make a test pass. Diagnose the mismatch and preserve the documented requirements.

## Commit & Pull Request Guidelines

Before every `gh` command that inspects or changes GitHub state, run `gh auth status` and resolve any authentication failure first. This applies to all GitHub CLI operations, including issues, pull requests, repository state, releases, workflow runs, and API requests.

If any `gh` command fails, run `gh auth status` again before retrying it or issuing another GitHub CLI command.

Create every working branch for an issue and include its issue number in the branch name, using the format `<issue-number>-<short-description>` (for example, `123-improve-pairing-recovery`). Do not begin implementation without an associated issue, except for emergency operational recovery explicitly authorized by the repository owner.

## Issue Creation Guidelines

Use sentence case for issue titles. Draft every issue description in a Markdown file and create the issue with `gh issue create --body-file <markdown-file>`; do not pass an issue body as shell-quoted inline text. This preserves Markdown formatting and avoids shell escaping changing the issue content.

Use concise, imperative commit subjects, consistent with the existing history: `Add initial product and security specification`. Keep commits focused. Pull requests should explain the user-visible and security impact, link the relevant issue or roadmap item, list tests run, and include screenshots for iOS UI changes. Highlight any change to pairing, certificate validation, logging, permissions, CloudKit, cellular routing, or LAN exposure for focused security review.
