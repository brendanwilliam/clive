# Development branch policy

Clive uses a two-stage pull-request flow:

```text
feature or fix branch -> develop -> main
```

`develop` is the normal integration branch. Open pull requests for feature, fix,
and documentation changes against `develop`. After the changes intended for a
release are integrated, open one pull request from `develop` to `main`.

## Validation

Pull requests into `develop` run **Verify develop integration / Swift package
tests and static checks**. This fast, required check runs Swift package tests and
whitespace validation. It deliberately does not install XcodeGen, boot an iOS
Simulator, build either app target, or run the localhost TLS/PTY integration
test.

Only a pull request from `develop` into `main` runs **Verify main integration /
Shared tests and app builds**. This complete, required check builds both app
targets with `./scripts/verify-local.sh` and runs
`./scripts/test-macos-integration.sh`. The workflow has no push trigger, so the
expensive check is not duplicated after the pull request merges.

Security-sensitive changes still need the focused review described in
[AGENTS.md](../AGENTS.md); the fast check is not a replacement for that review.

## Administrator configuration

GitHub Actions cannot restrict a pull request's source branch. A repository
administrator must configure the following GitHub branch rules after this pull
request merges:

1. Create and protect `develop`, requiring the **Verify develop integration /
   Swift package tests and static checks** check before merge.
2. Protect `main`, requiring the **Verify main integration / Shared tests and
   app builds** check before merge. Keep existing review requirements and do not
   allow GitHub Actions to bypass them.
3. Add a `main` branch ruleset that requires pull requests and restricts allowed
   source branches to `develop`. Do not grant a bypass to workflows or GitHub
   Actions. Repository administrators may retain a bypass role only for an
   exceptional direct pull request; using it is an explicit, auditable GitHub
   override.

Before completing the configuration, verify in the branch ruleset UI that a
non-`develop` pull request into `main` is blocked and that the override control
identifies the administrator who uses it. Do not create a workflow-based bypass,
auto-merge, review dismissal, or status-check bypass.
