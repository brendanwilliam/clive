# V1 release readiness

This checklist is the release gate for the Epic 155 V1 connectivity and managed
Codex work. A check marks evidence that has been collected; it does not turn an
unsupported or unavailable environment into a pass.

## Automated evidence

Run from a clean feature branch before opening the release PR:

```sh
swift test
./scripts/check-fast.sh
```

For `develop` to `main` integration, release preparation, or platform diagnosis,
also run `./scripts/verify-local.sh`. Use `--signed` only when signing readiness
is part of the question. Record failures as blocking, environmental, known
limitation, or deferred. Supported V1 failures are blocking.

The automated suite must cover framing limits, pairing expiry and replay,
certificate trust, revocation, route fallback, attachment races, input fencing,
replay offsets and truncation, PTY retention, bounded output, and Codex argument
forwarding. It must not require production relay credentials, CloudKit production
data, cellular networking, a camera, or a physical device.

## Physical and network evidence

Before a supported V1 release, collect sanitized results for:

- camera pairing, explicit Mac approval, cancellation, expiry, and TestFlight
  fallback with pending-ticket resume;
- Wi-Fi to cellular and cellular to Wi-Fi handoff with the same session ID,
  preserved PTY, and no duplicated input;
- private VPN discovery and manual endpoint fallback;
- iPhone background/foreground reattachment, replay offset, and truncation;
- Mac-to-iPhone and iPhone-to-Mac takeover with explicit confirmation and one
  input owner.

Do not include terminal output, prompts, commands, credentials, QR tickets,
private keys, or full environment values in evidence or diagnostics.

Current evidence: on 2026-08-26, PR [#189](https://github.com/brendanwilliam/clive/pull/189)
was validated on a physical iPhone for Wi-Fi→cellular handoff and new cellular
session attachment. The reverse cellular→Wi-Fi transition and the remaining
physical-device, VPN, and takeover scenarios are still pending.

## Upgrade, rollback, and recovery

The macOS cask and package update the companion and CLI together. A normal
uninstall preserves user-scoped pairing state; `--zap` removes it and requires
pairing again. Existing pairings remain valid across compatible upgrades, but a
certificate or identity change must be investigated and the device re-paired
only after the change is understood.

If a release fails, stop distribution, preserve the published artifact and tag,
and roll back by installing the last known-good package. Do not overwrite a
published tag. Revoke affected devices when trust is uncertain. Restore release
metadata or credentials before rerunning the cask update; never copy secrets into
issue comments or logs.

## V1 exclusions

Relay transport is designed but disabled until its operational, abuse, privacy,
quota, incident-response, and independent-security gates are approved. Clive
does not provision VPNs, adopt arbitrary terminal-emulator PTYs, persist terminal
content or credentials, interleave Mac and iPhone input, or provide independently
durable Codex runs. A detached Codex process is retained only with its managed PTY
for the 90-minute retention window.
