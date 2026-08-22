---
name: clive-swift-development
description: Implement or refactor Swift in Clive with project-specific type, concurrency, lifecycle, and testing conventions. Use for Swift source changes; add the security or macOS integration skills when those boundaries are involved.
---

# Clive Swift Development

Read the affected architecture, protocol, or security documentation before changing a documented boundary. Preserve exact wire-frame and CLI names and the supported macOS and iOS platform constraints.

## Implementation

- Follow the [Google Swift Style Guide](https://google.github.io/swift/) for new and modified Swift. Clive's specifications and existing public names take precedence. Match local style where the guide allows alternatives, and do not reformat unrelated code.
- Prefer small, readable types with explicit inputs, outputs, ownership, and failure cases. Use typed protocol and trust boundaries instead of unstructured dictionaries, strings, or loosely related booleans.
- Handle recoverable errors explicitly. Preserve useful error context without exposing secrets, terminal contents, keys, pairing material, or credentials in logs.
- Keep concurrency ownership visible. Avoid detached work unless its lifetime is intentionally independent; propagate cancellation, bound buffers and tasks, and make teardown idempotent.
- Close sockets, streams, PTYs, child processes, observers, and continuations on success, error, cancellation, disconnect, and shutdown as applicable. Do not rely only on deinitialization for externally visible cleanup.
- Keep the change focused. Do not rename public protocol or CLI vocabulary, mass-format files, or fold unrelated cleanup into the patch.

## Tests and handoff

Add or update behavioral tests for each changed outcome, including error, cancellation, and cleanup paths that the change affects. Run the smallest relevant test target or filter during development, then use `clive-local-verify` for authoritative pre-PR verification.

If the work touches pairing, certificates, authorization, key storage, logging, permissions, CloudKit, cellular routing, or LAN exposure, also use `clive-security-review`. If it crosses the daemon, control socket, localhost TLS, PTY, or macOS session lifecycle, also use `clive-macos-integration`.
