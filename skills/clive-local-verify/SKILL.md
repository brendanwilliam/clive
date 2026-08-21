---
name: clive-local-verify
description: Verify and restore local compatibility across CliveCore, the macOS companion, and the iOS app after code or configuration changes. Use when checking a change locally, preparing a PR, or diagnosing why one Clive platform no longer builds; do not use to publish releases.
---

# Clive Local Verify

Run `./scripts/verify-local.sh` from the repository root. It generates the ignored iOS Xcode project with XcodeGen when absent, then executes the shared Swift tests and unsigned Debug builds for macOS and generic iOS in parallel, reusing DerivedData under `/private/tmp/clive-local-verify`. Use `--signed` only when the user wants local signing or physical-device readiness and the machine's development configuration is available.

The same script is the source of truth for `.github/workflows/verify.yml` and the coordinated release preflight. Keep platform checks in the script rather than duplicating them in workflow YAML.

## On failure

Read the named log under `/private/tmp/clive-local-verify/logs`. Determine whether the failure is introduced by the current change, stale generated Xcode project state, unavailable dependencies, or local signing/provisioning.

- For source or checked-in configuration incompatibility caused by the current task, make the smallest scoped correction and rerun the complete script.
- If `project.yml` changed, regenerate the affected Xcode project with XcodeGen, review the generated diff, and rerun verification.
- Do not weaken entitlements, security checks, deployment targets, or release signing to make a build pass.
- Do not change code to hide an unavailable network dependency, Apple account, certificate, or provisioning profile. Report that environmental blocker clearly.
- Preserve unrelated worktree changes. Successful builds do not authorize installing apps, changing pairing state, or launching external releases.

Finish only when the script passes or a genuine external blocker is identified. Report the shared-test, macOS, and iOS results separately and list any compatibility correction made.
