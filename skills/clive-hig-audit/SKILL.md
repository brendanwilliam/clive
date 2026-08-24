---
name: clive-hig-audit
description: Audit Clive agentic workflow UI against Apple Human Interface Guidelines and the shared workflow naming guide. Use for user-facing workflow design or review; not for non-UI automation.
---

# Clive HIG audit

Read [the agentic-workflow HIG reference](../../docs/human-interface-guidelines.md)
and the applicable Apple HIG pages it links before auditing a user-facing agentic workflow.
Use this skill alongside the normal implementation skill; it is a review, not a replacement
for platform development or security review.

Trace the workflow from the user's request through proposal, approval when required,
progress, interruption, completion, failure, cancellation, and recovery. Audit only the
states and controls the change affects.

Check that the UI:

- makes the requested work, its scope, and any approval boundary understandable;
- preserves user control and does not bypass pairing, certificate, or authorization
  requirements;
- provides meaningful feedback and a safe next action for waiting, failure, and
  cancellation states;
- uses appropriate native iOS or macOS patterns instead of inventing parallel controls;
- exposes equivalent workflow names and state through visible copy and accessibility labels;
- uses the preferred terms in the naming guide, while preserving exact protocol and CLI
  names and platform-native terminology.

Report each finding with the affected state or control, the relevant HIG or naming
expectation, and a concrete remediation. Explicitly report when no findings are identified.
Do not treat a passing audit as proof that an automated action is safe or authorized.
