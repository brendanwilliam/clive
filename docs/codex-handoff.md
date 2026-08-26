# Codex handoff contract

This document defines the opt-in handoff boundary for Epic [#155](https://github.com/brendanwilliam/clive/issues/155).
It describes a request to move input authority to an iPhone; it does not adopt
or reparent an existing terminal-emulator process.

## Supported flow

1. A Codex-provided, authenticated local integration identifies the specific
   Clive-managed session and submits a handoff request through the daemon's
   local control plane.
2. The daemon records a short-lived pending request containing only the session
   ID, requester (`codex`), and a Mac-assigned timestamp. It does not record
   prompts, run IDs, terminal bytes, commands, credentials, or environment
   values.
3. The paired iPhone receives the pending state over its authenticated session
   and presents the requester and timestamp with `Take Control` and `Dismiss`.
4. `Take Control` atomically makes the iPhone attachment authoritative for
   input. The Mac/Codex attachment becomes read-only; its output remains
   observable and its PTY is unchanged.
5. `Dismiss`, expiry, disconnect, or a failed safety check leaves the current
   input owner unchanged.

The request expires after five minutes and is single-use. A new request is
required after dismissal, expiry, or a completed handoff.

## Safety invariants

- A request is bound to one stable Clive server session and the authenticated
  local requester; it cannot grant access to another session.
- The iPhone must explicitly confirm. A Codex integration cannot inject input,
  approve its own request, or bypass pairing, certificate validation, revocation,
  or route authentication.
- Approval and input-authority transfer occur on the session serialization
  queue. Old-generation input arriving after approval is rejected and is never
  replayed.
- The PTY, session ID, output offset, and replay ring are preserved. Handoff
  never creates a replacement shell or claims to resume an arbitrary external
  PTY.
- Pending state is sanitized for catalogs, diagnostics, and notifications.

## Safe fallback

If the installed Codex version cannot provide an authenticated handoff request,
the supported recovery path remains `clive codex resume ...`. Clive starts a new
managed PTY and Codex retains responsibility for run identity, credentials,
approvals, and duplicate-run handling.

Implementation must add focused coverage for session binding, expiry,
dismissal, approval, stale approval races, revoked devices, and sanitized
diagnostics before enabling the integration.
