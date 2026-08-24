---
name: repository-cleanup
description: Audit and safely clean up a repository's completed GitHub issues and merged remote branches. Use when a user asks to prune stale branches, close completed work, or tidy repository state; do not use for ordinary branch management.
---

# Repository Cleanup

Audit before changing any external state. Preserve active pull-request branches, protected branches, and local worktrees.

1. Before GitHub inspection or mutation, run `gh auth status` and resolve authentication failures.
2. Read open and merged PRs, open issues, and remote branches merged into the integration branch. Fetch with pruning first when a current remote view matters.
3. A branch is eligible for deletion only when it is merged into the integration branch and is not the head branch of an open PR. Delete remote branches only; do not delete local branches or worktrees unless the user explicitly asks.
4. Close an issue only when a merged PR clearly completes it, or when the issue is explicitly superseded. Leave umbrella, roadmap, partially complete, or validation-dependent issues open. Add a concise closure comment linking the completing PR or explaining supersession.
5. Before closing issues or deleting remote branches, present the intended targets and request explicit approval unless the user already clearly authorized that cleanup in the current request.
6. Perform mutations with narrowly scoped commands. Never delete the default or integration branch, and do not delete any active PR branch.
7. Verify the resulting remote branch list, issue states, and remaining open PRs. Report what was removed or closed, and identify intentionally retained items.

Treat an issue's open state as meaningful: a merged PR alone is not enough when its body or linked work leaves acceptance criteria unfinished.
