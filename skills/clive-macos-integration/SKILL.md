---
name: clive-macos-integration
description: Develop or diagnose Clive macOS daemon integration across the control socket, localhost TLS, PTYs, and session lifecycle. Use when changes cross those runtime boundaries; not for isolated Swift logic or iOS-only work.
---

# Clive macOS Integration

Read the affected contracts in `docs/architecture.md`, `docs/protocol.md`, and `docs/security.md`. Preserve the daemon's ownership of PTYs and child shells, the owner-only local control boundary, authenticated TLS behavior, bounded messages, and documented detach, expiry, revocation, and shutdown semantics.

## Integration boundaries

- Keep control-socket state isolated per test and use owner-only permissions. A local client must not edit live trust or session state independently of the daemon.
- Bind test TLS listeners to localhost and use test-only identities and state. Never read, overwrite, or reuse a developer's pairing records, keys, sockets, ports, or running daemon state.
- Exercise PTYs through observable terminal behavior. Bound input and output, handle partial reads and writes, propagate resize and EOF, reap child processes, and close every descriptor exactly once.
- Make session ownership and transitions explicit across open, attach, detach, expiry, process exit, revocation, transport loss, and daemon shutdown. Ensure failure and cancellation cannot leave tasks, sockets, PTYs, children, or temporary state behind.
- Allocate temporary directories and ephemeral ports for tests. Register cleanup before starting resources, tolerate cleanup after partial setup, and avoid timing-only assertions when an observable readiness signal is available.

## Verification

Add the smallest focused unit or integration test that reproduces the changed behavior, including relevant failure and cleanup paths. Run targeted Swift tests during development, then run:

```sh
./scripts/test-macos-integration.sh
```

Use `clive-local-verify` before submitting a pull request. Also use `clive-security-review` when the integration change affects authentication, authorization, certificates, secrets, logging, permissions, routing, or network exposure. Report the focused tests, macOS integration result, cleanup behavior verified, and any environmental blocker separately.
