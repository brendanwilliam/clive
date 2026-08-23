---
name: clive-local-refresh
description: Rebuild and redeploy Clive to a connected iPhone for deliberate recovery from a development failure. Use only when losing the active terminal is acceptable.
---

# Clive Local Refresh

Use this skill to replace the local development daemon and iPhone app after a development failure.

This is a disruptive operation: `scripts/update-local.sh` stops the current Clive daemon before installing the replacement. That terminates all Mac-owned terminal sessions, including the session from which the command may be run. It is a recovery/redeploy workflow, not a hot update.

Before running it:

1. State that the active Clive terminal will end and cannot be resumed after this refresh.
2. Confirm that the user accepts that interruption. Do not treat permission to build or diagnose as permission to run the refresh.

After confirmation, run the script immediately. It performs its own configuration and connected-device checks, including requiring `CLIVE_IOS_DESTINATION_ID` when necessary:

```sh
./scripts/update-local.sh
```

When the script is run from a Clive-managed terminal, it hands the disruptive work to `launchd`, then that terminal ends. In that case, report that the refresh was handed off and provide `/private/tmp/clive-device-run/refresh.log`; do not claim deployment success before that log is checked in a later turn. Otherwise, report whether the script completed and provide its daemon-log paths on failure. Do not retry automatically: a failed deployment may need investigation, and the original terminal is already gone.

For normal validation that must preserve an active terminal, use `./scripts/verify-local.sh` instead; it builds and tests but does not replace the running daemon or iPhone app.
