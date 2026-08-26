# Epic 155 implementation plan

This document is the working map for Epic [#155](https://github.com/brendanwilliam/clive/issues/155).
It records the agreed V1 boundaries, implementation order, verification work, and
the current state of each workstream. GitHub issue comments remain the detailed
decision record; this document is the implementation index for humans and agents.

## V1 outcome

Clive provides a Mac-owned terminal session that can move between LAN,
opportunistic private VPN, and direct WAN/cellular routes without replacing the
PTY. Codex commands can run inside that managed session and be resumed through a
user-pasted Codex resume command. Relay transport and independently durable Codex
runs are designed as extension points but are not enabled in V1.

## Status legend

- `[ ]` not started
- `[-]` in design or implementation
- `[x]` complete and verified
- `Deferred` intentionally outside V1

## Dependency order

```text
#156 architecture
 ├── #157 → #158 → #159 pairing and onboarding
 ├── #160 → #161 route selection and handoff
 │          └── #166 → #167 → #168 Codex sessions and handoff
 ├── #162 relay design → #163 relay implementation (deferred)
 └── #164 verification → #165 documentation and release readiness
```

Implementation should establish the architecture contract before adding route or
Codex behavior. Focused tests belong with each implementation step. The full
local verification workflow is reserved for PR preparation.

## Workstreams

### 1. Connectivity architecture — #156

Status: `[-]` architecture contract and deterministic selector implemented;
daemon/provider integration remains in #160.

Agreed behavior:

- Route order is LAN → private VPN → direct WAN/cellular → relay.
- Private VPN is opportunistic. Users configure it outside Clive; Clive does not
  provision VPNs or credentials. Discovery uses private DNS/Bonjour when available
  plus an optional manual endpoint.
- All route providers publish a common candidate shape: route kind, endpoint,
  availability, authorization, last verification, staleness/expiry, and health.
- Externally visible route states are `unavailable`, `available`, `selected`, and
  `failed`. Probing and draining are internal states.
- A higher-priority route may replace a healthy lower-priority route after a
  debounce period. Hysteresis prevents flapping.
- A route transition probes and authenticates the new path, attaches to the same
  stable session ID, confirms replay position, then transfers authority.
- User disablement cancels retries immediately. Revocation terminates the active
  attachment and invalidates route credentials. Temporary network loss detaches
  only the transport and retains the PTY.

Implementation tasks:

- [x] Define route candidate and route-provider types.
- [x] Define route ranking, health, backoff, debounce, and staleness constants.
- [x] Document the state machine and transition invariants.
- [x] Add deterministic state-machine tests.

### 2. QR onboarding links — #157

Status: `[-]` design decisions recorded; implementation not started.

Agreed behavior:

- The HTTPS universal link carries a short-lived, single-use pairing ticket, not
  long-term credentials, certificates, private keys, or reusable pairing material.
- The installed app handles the link directly. Missing-app links open TestFlight
  without forwarding the ticket; the Mac retains the pending ticket until expiry
  or cancellation so installation can be followed by resume or rescan.
- In-app scanning always has an explicit Close/Cancel action.
- Old or unsupported app versions fail safely with update/compatibility guidance.
  Invalid, expired, or cancelled links offer a new-code path.

Implementation tasks:

- [ ] Define link version and routing states.
- [x] Implement installed-app and missing-app universal-link handling.
- [x] Implement safe pending-ticket resume after installation.
- [x] Add scanner cancellation and URL-routing tests.
- [ ] Add physical-device coverage for Camera and TestFlight paths.

### 3. CLI installation and pairing — #158

Status: `[-]` design decisions recorded; implementation not started.

Agreed behavior:

- `clive pair` activates the daemon when possible, generates a short-lived QR,
  waits for the request, and requires explicit Mac approval.
- The menu-bar item is status-only. Pairing and Mac configuration are CLI-owned.
- The terminal approval prompt shows the device name and Mac-authoritative scan
  timestamp, then requires explicit `y/N` input.
- Ctrl-C cancels and invalidates the ticket. Transient network failures allow
  bounded retries before expiry; rejection requires a new ticket.

Implementation tasks:

- [x] Refine `clive pair` output and terminal QR rendering.
- [x] Add daemon activation and actionable failure handling.
- [x] Remove menu-bar pairing/configuration actions, retaining status only.
- [x] Add approval, cancellation, retry, and secret-redaction tests.

### 4. QR security lifecycle — #159

Status: `[x]` implemented and covered by focused tests; physical-device coverage
remains a release validation task.

Agreed behavior:

- Tickets expire after one minute, are bound to the intended Mac identity and
  certificate, and can create at most one pairing through atomic consumption.
- Cancellation, rejection, expiry, malformed data, and replay fail closed without
  creating trust records.
- The Mac is authoritative for the scan timestamp and returns the same timestamp
  plus a non-secret pairing-event identifier to the iPhone.
- Pairing secrets and ticket contents are never logged or shown in diagnostics.

Implementation tasks:

- [x] Update the payload/version contract and ticket storage lifecycle.
- [x] Implement atomic consume, cancellation, expiry, and replay rejection.
- [x] Implement Mac-authoritative timestamp correlation in the UI/protocol.
- [x] Add malformed, intercepted, expired, reused, cancelled, and redaction tests.
- [x] Complete focused security review before implementation is considered done.

### 5. Transport-independent routes — #160

Status: `[-]` design decisions recorded; implementation not started.

Agreed behavior:

- Every route adapter provides connect, authenticate, attach, input, resize,
  output, and close operations.
- Session attachment, replay, handoff, input authority, and error handling do not
  depend on the underlying transport.
- Discovery failures are separate from session failures. Expired or unauthorized
  candidates cannot be selected.

Implementation tasks:

- [x] Add the common route adapter interface.
- [ ] Adapt LAN and existing direct WAN/cellular paths to the interface.
- [ ] Add opportunistic private VPN discovery and optional endpoint configuration.
- [x] Add route candidate refresh and health reporting.
- [ ] Add focused route-selection and fallback tests.

### 6. Loss-safe reattachment — #161

Status: `[-]` attachment fencing and bounded retention implemented; integration
coverage for sleep/wake and daemon restart remains.

Agreed behavior:

- Old and new connections may overlap, but only one attachment generation owns
  input. The new connection becomes authoritative only after authentication,
  stable-session attachment, and replay-position confirmation.
- Output is replayed by byte offset; input is never replayed or duplicated.
- A detached PTY is retained for 90 minutes, with a bounded 1 MiB replay ring.
  Truncation is explicitly reported.
- Sleep/network loss may detach transport without ending the PTY. Daemon restart,
  shutdown, crash, or reboot ends sessions in V1.
- Disablement, revocation, shell exit, retention expiry, and explicit termination
  have distinct fail-closed behavior.

Implementation tasks:

- [x] Add attachment generations and input fencing.
- [x] Make handoff and replay confirmation atomic on the session queue.
- [x] Update PTY retention to 90 minutes and preserve truncation reporting.
- [ ] Add race, offset, truncation, sleep/wake, expiry, and restart tests.

### 7. Relay design — #162

Status: `[-]` architecture decision record and threat model implemented;
production relay deferred pending launch gates.

Agreed boundary:

- Relay is fallback-only after direct routes fail and never preferred over a
  healthy direct route.
- Relay credentials are short-lived, single-use, connection-scoped, revocable,
  and cannot authorize a Clive session.
- Mac and iPhone retain end-to-end Clive TLS; the relay forwards opaque bytes.
- The relay retains no terminal content and only minimal active routing metadata,
  subject to duration, bandwidth, concurrency, and idle limits.
- Production launch requires an identified operator, abuse/cost/incident plan,
  privacy-preserving monitoring, independent security review, and a kill switch.

Implementation tasks:

- [x] Produce the architecture decision record and threat model.
- [x] Define operational ownership, credential issuance, quotas, and monitoring.
- [x] Define deterministic relay-unavailable behavior and launch gates.

### 8. Relay implementation — #163

Status: `Deferred`.

Do not implement or enable a production relay until #162 launch gates are
approved. The route abstraction must still tolerate relay absence cleanly.

### 9. Managed Codex launcher — #166

Status: `[x]` implemented and covered by focused tests; physical-device and
full iOS attachment coverage remain release validation work.

Agreed behavior:

- `clive codex` launches the standard `codex` executable found on `PATH` inside
  a daemon-owned PTY. `--directory` defaults to the CLI’s current directory, and
  `--label` is optional.
- Codex options may follow the wrapper command; the paste-friendly form is
  `clive codex resume ...`.
- The daemon’s controlled environment is used; the full CLI environment is not
  copied because it may contain secrets.
- Codex runs in the same persistent terminal session as its shell. When Codex
  exits, the user returns to an ordinary shell and retains Codex’s visible output,
  including summaries, token counts, and resume commands.
- The iPhone catalog distinguishes active Codex sessions from ordinary shells,
  while the session returns to ordinary-shell presentation after Codex exits.

Implementation tasks:

- [x] Add a Codex session classification and launcher request.
- [x] Resolve `codex` from the daemon-compatible `PATH`.
- [x] Preserve current directory, terminal size, label, and controlled environment.
- [x] Implement paste-friendly argument forwarding without secret logging.
- [x] Add focused launcher, classification, handoff, retention, and argument coverage.

### 10. Existing Codex handoff — #167

Status: `[-]` design decisions recorded; paste-friendly resume forwarding is
implemented and covered; local handoff requests remain future work.

Agreed behavior:

- Clive never adopts or reparents an arbitrary existing terminal-emulator PTY.
- A resume starts Codex in a new Clive-managed PTY using the user’s pasted command.
- Codex remains responsible for run identity, resume semantics, credentials,
  approvals, and duplicate-run enforcement.
- An optional Clive Codex skill may request handoff through the local control plane.
  The iPhone must explicitly confirm `Take Control`; the skill cannot grant
  remote control or inject keystrokes.
- iOS shows pending handoff with requester and Mac-authoritative timestamp; the
  request can be dismissed or expires without changing current control.

Implementation tasks:

- [x] Implement `clive codex resume ...` argument forwarding.
- [x] Preserve native Codex resume errors and recovery guidance in the managed terminal.
- [ ] Define and implement the authenticated local handoff request.
- [ ] Add the opt-in Codex handoff skill and iPhone confirmation flow.
- [ ] Test pending, accepted, dismissed, expired, and rejected handoffs.

### 11. Durable Codex runs — #168

Status: `Deferred` for V1; extension boundary documented.

V1 permits detached Codex work only while the managed PTY remains within the
90-minute retention window. The shell/process, in-memory PTY state, bounded replay
ring, session metadata, and retention deadline remain available. Clive does not
persist prompts, commands, terminal content, credentials, or environment values.

Both devices may observe the same session, but one attachment owns input at a
time. Explicit termination stops the process, clears in-memory state, and removes
the session. A future durable-run design may separate an agent run from terminal
attachments without changing the V1 safety boundary.

## Verification and release

### #164 End-to-end verification

Status: `[-]` automated coverage matrix and release-validation split recorded;
physical-device execution remains pending.

- Automated tests cover framing, state transitions, retries, races, fencing,
  replay, expiry, revocation, disablement, and relay absence.
- Physical-device tests cover Camera links, TestFlight fallback, biometric
  cancellation, Wi-Fi/cellular transitions, private VPN discovery, backgrounding,
  and Mac/iPhone handoff in both directions.
- Failures are classified as blocking, known limitation, environmental failure,
  or deferred. Supported V1 failures block release.

Verification record: [`connectivity-verification.md`](connectivity-verification.md).

### #165 Documentation and release readiness

Status: `[-]` documentation structure and checklist recorded; updates not started.

Required documentation updates:

- README setup and CLI pairing flow.
- Protocol/session/route/handoff contracts.
- Security and ticket lifecycle.
- Cellular and private VPN behavior.
- CLI help and Codex wrapper syntax.
- Release notes, migration behavior, diagnostics, rollback, and V1 exclusions.

Required release evidence:

- Focused tests plus the full local verification script.
- Physical-device results and known limitations.
- Sanitized diagnostics with no terminal content, prompts, credentials, QR tickets,
  or private keys.
- Explicit confirmation that relay and independently durable Codex runs are not
  enabled in V1.

## Current implementation board

Update this table as work lands. Link the implementation PR or commit in the
`Evidence` column; do not mark a row complete based only on design discussion.

| Workstream | Status | Evidence |
| --- | --- | --- |
| #156 Architecture | Design recorded | — |
| #157 QR links | Design recorded | — |
| #158 CLI pairing | Design recorded | — |
| #159 QR security | Design recorded | — |
| #160 Route abstraction | Design recorded | — |
| #161 Reattachment | Design recorded | — |
| #162 Relay design | ADR and threat model | [`relay-architecture-and-threat-model.md`](relay-architecture-and-threat-model.md) |
| #163 Relay implementation | Deferred | — |
| #166 Codex launcher | Design recorded | — |
| #167 Existing-run handoff | Design recorded | — |
| #168 Durable runs | Deferred | — |
| #164 Verification | Automated matrix recorded; physical validation pending | [`connectivity-verification.md`](connectivity-verification.md) |
| #165 Docs/release | Design recorded | — |

## V1 exclusions

- No production relay until #162 launch gates pass.
- No arbitrary PTY adoption or reparenting.
- No independently durable Codex-run catalog or retention beyond the managed PTY.
- No Clive VPN provisioning or credential management.
- No automatic interleaving of Mac and iPhone terminal input.
- No persistence of terminal content, prompts, commands, credentials, or private
  environment values by Clive.
