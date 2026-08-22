---
name: clive-local-refresh
description: Rebuild and redeploy Clive to a connected iPhone for deliberate recovery from a development failure. Use only when losing the active terminal is acceptable.
---

# Clive Local Refresh

Use this skill to replace the local development daemon and iPhone app after a development failure.

This is a disruptive operation: `scripts/run-on-iphone.sh` stops the current Clive daemon before installing the replacement. That terminates all Mac-owned terminal sessions, including the session from which the command may be run. It is a recovery/redeploy workflow, not a hot update.

Before running it:

1. State that the active Clive terminal will end and cannot be resumed after this refresh.
2. Confirm that the user accepts that interruption. Do not treat permission to build or diagnose as permission to run the refresh.
3. Confirm `Apps/Clive/Config/Local.xcconfig` exists and a connected, unlocked iPhone is available. If more than one device is connected, require `CLIVE_IOS_DESTINATION_ID` to be set.

After confirmation, run:

```sh
./scripts/run-on-iphone.sh
```

Report whether the script completed and provide its daemon-log paths on failure. Do not retry automatically: a failed deployment may need investigation, and the original terminal is already gone.

For normal validation that must preserve an active terminal, use `./scripts/verify-local.sh` instead; it builds and tests but does not replace the running daemon or iPhone app.
