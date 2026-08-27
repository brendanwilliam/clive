# Connectivity verification

This matrix is the verification record for Epic #155 issue #164. It separates
repeatable automated coverage from validation that requires a signed app,
physical devices, or networks that are not available in the ordinary local
test environment.

## Automated coverage

Run the package suite and the ordinary development checks with:

```text
swift test
./scripts/check-fast.sh
```

| Area | Coverage | Evidence |
| --- | --- | --- |
| Protocol framing and size limits | Automated | `Tests/CliveCoreTests/ProtocolTests.swift` |
| Route ranking, health, expiry, staleness, debounce, and fallback | Automated | `Tests/CliveCoreTests/ProtocolTests.swift` |
| Pairing payload validation, expiry, cancellation, replay, and secret consumption | Automated | `Tests/CliveCoreTests/PairingLinkTests.swift`, `Tests/CliveCoreTests/ProtocolTests.swift` |
| Session attachment races and input fencing | Automated | `Tests/CliveDaemonTests/TerminalSessionManagerTests.swift` |
| Replay offsets, truncation, retention expiry, and PTY cleanup | Automated | `Tests/CliveDaemonTests/TerminalSessionManagerTests.swift` |
| Bounded output backpressure | Automated | `Tests/CliveCoreTests/ProtocolTests.swift`, `Tests/CliveDaemonTests/TerminalSessionManagerTests.swift` |
| Revocation and owned-session termination | Automated | `Tests/CliveDaemonTests/TerminalSessionManagerTests.swift` |
| Codex managed-session argument forwarding | Automated | `Tests/CliveDaemonTests/ControlSocketTests.swift`, `Tests/CliveDaemonTests/TerminalSessionManagerTests.swift` |
| Secret and terminal-content redaction boundaries | Automated review and focused tests | Pairing and daemon tests; no sensitive values are included in diagnostics |

The automated suite must remain deterministic and must not require CloudKit,
cellular networking, a physical camera, or production relay credentials.

## Physical-device and network validation

These scenarios remain release-blocking for supported V1 paths and require a
signed macOS companion, a physical iPhone, and representative networks:

| Scenario | Required evidence | Current status |
| --- | --- | --- |
| Camera-to-app QR pairing and explicit Mac approval | Sanitized pairing result and cancellation/retry result | Pending physical-device validation |
| TestFlight fallback and pending-ticket resume | Missing-app fallback does not receive the URL fragment; resumed scan succeeds | Pending TestFlight validation |
| Wi-Fi to direct cellular and cellular to Wi-Fi handoff | Stable session ID, preserved PTY, and no duplicated input | Wi-Fi→cellular validated on a physical iPhone with PR #189; cellular→Wi-Fi remains pending |
| Private VPN discovery and fallback | Route selection and documented VPN limitations | Deferred; Clive does not provide VPN setup, and VPN-specific validation is outside V1 |
| iPhone background/foreground reattachment | Replay offset and truncation behavior after foregrounding | Pending physical-device validation |
| Mac-to-iPhone and iPhone-to-Mac takeover | Explicit user confirmation and single input owner | Pending physical-device validation |

Unsupported carrier behavior, NAT limitations, sleep/wake variability, and
relay availability must be recorded as known limitations, environmental
failures, or deferred behavior rather than silently treated as passing.

### Evidence collected

On 2026-08-26, a signed local build containing PR [#189](https://github.com/brendanwilliam/clive/pull/189)
was exercised on a physical iPhone over Wi-Fi and 5G. An existing terminal
resumed after Wi-Fi was disabled, and newly created cellular terminals attached
successfully. The test did not record terminal content or credentials. The
reverse cellular-to-Wi-Fi transition and broader carrier/network matrix remain
release-blocking validation work. Private VPN setup and configured-VPN validation
are explicitly deferred for a later release.

## V1 boundary

Relay transport remains unavailable by design until the launch gates in
[`relay-architecture-and-threat-model.md`](relay-architecture-and-threat-model.md)
are approved. Independently durable Codex runs remain outside V1; a detached
Codex process is retained only with its Clive-managed PTY during the 90-minute
session retention window.
