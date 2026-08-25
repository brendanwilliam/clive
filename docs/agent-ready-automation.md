# Agent-ready issue automation

Applying the `agent-ready` label asks GitHub Actions to have Codex implement a
triaged issue and open a draft pull request. It is a maintainer gate, not an
automatic response to newly opened issues. Codex never merges the pull request
or bypasses branch protection and required reviews.

## Setup

A repository administrator must add an `OPENAI_API_KEY` GitHub Actions secret.
The key is provided only to `openai/codex-action@v1`; it is not committed,
printed, or passed through the issue content. The administrator must also allow
GitHub Actions to create branches and pull requests with the workflow's scoped
`GITHUB_TOKEN` permissions.

Codex receives only `contents: read` and runs with the workspace-only
permission profile after `sudo` is removed. A separate, fresh job applies its
patch and has the scoped `contents: write`, `issues: write`, and
`pull-requests: write` permissions needed to create the branch, draft PR, and
issue comment.

## Issue format and use

Before applying `agent-ready`, a maintainer must make the issue specific and
include an exact Markdown section headed `## Acceptance criteria`. Give each
criterion an observable, testable result. For example:

```md
## Acceptance criteria

- [ ] The command rejects an expired token.
- [ ] A focused regression test covers the rejection.
```

The workflow comments with the required correction and stops if the heading is
missing. To retry a corrected issue, remove and reapply the label. Treat all
issue text as untrusted input: do not put credentials, pairing data, private
hostnames, fingerprints, or terminal output in an issue.

When successful, the workflow opens a draft PR against `develop`, links the
source issue, summarizes acceptance-criteria coverage, and records verification
reported by the agent. A maintainer must review the changes and the PR template
before marking it ready for review.

## Disable the automation

Remove or rename `.github/workflows/agent-ready.yml`, or disable the workflow
from the repository's **Actions** settings. Removing the `OPENAI_API_KEY`
secret also prevents new agent runs. Existing draft pull requests are not
merged or closed automatically.
