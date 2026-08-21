---
name: clive-release
description: Prepare, launch, and verify coordinated Clive macOS and iOS releases through GitHub Actions. Use for release readiness, a macOS package plus TestFlight release, or troubleshooting the coordinated release workflow; do not use for ordinary local debug builds.
---

# Clive Release

Use `.github/workflows/coordinated-release.yml` as the production entry point. It releases both platforms from the same `main` commit and version; do not launch the two platform workflows separately unless the user is deliberately recovering a partial release.

## Readiness

- Confirm the requested commit is merged into `main`, the worktree is clean, and local `main` matches `origin/main`.
- Confirm the Mac/iOS compatibility workflow passed for that commit. The release preflight reruns the same `scripts/verify-local.sh` check before publishing anything.
- Confirm the version is new and semantic, without the `v` prefix. The workflow creates the corresponding `v<version>` macOS tag.
- Confirm the `CliveRendezvousV1` CloudKit schema is deployed to Production. Treat the workflow checkbox as an operator attestation, not proof that deployment occurred.
- Inspect recent coordinated, macOS, and TestFlight runs for an existing or partial release before starting another.
- Never print signing certificates, provisioning profiles, API keys, or secret values.

Readiness checks are non-mutating. Launching a workflow, creating a tag or GitHub Release, uploading to TestFlight, or retrying a failed platform requires explicit user authorization.

## Execute

Trigger the workflow on `main` with the shared version, prerelease choice, and CloudKit confirmation. For example:

```sh
gh workflow run coordinated-release.yml --ref main \
  -f version=1.0.0 \
  -f prerelease=true \
  -f cloudkit_production_schema_deployed=true
```

Monitor the resulting run. The workflow intentionally publishes the notarized macOS package first and uploads iOS to TestFlight second. If iOS fails after macOS succeeds, report a partial release and ask before rerunning only TestFlight; never recreate or overwrite the existing macOS tag.

## Verify

- Confirm the GitHub Release contains `clive.pkg` and `clive.pkg.sha256` and is attached to the expected commit.
- Confirm the iOS upload finished; App Store Connect processing and tester assignment can remain pending after CI succeeds.
- For cellular acceptance, install both production builds, connect the pair once over LAN, then run `clive cellular test` with iPhone Wi-Fi disabled.
- Report the shared version, commit, workflow URL, macOS release URL, and TestFlight processing state.
