---
name: clive-attach-terminal
description: Attach the current Mac terminal to an existing Clive session when the user wants to resume a daemon-owned shell, not create or adopt a terminal emulator session.
---

# Clive Attach Terminal

Use this skill when the user wants the terminal running the CLI to become the local attachment for an existing Clive session.

`clive attach` is interactive: it lists active daemon-owned sessions and asks which one to attach. Use `clive attach <session-id>` only when the user already supplied the exact session ID. Add `--device <device-id>` only when a particular paired device is required.

Do not use `clive shell`; it creates a new PTY. Do not claim this adopts an arbitrary Terminal, iTerm, SSH, or tmux session: it only attaches a local terminal client to a Clive-owned session.

Ask for confirmation immediately before running `clive attach`, because it opens an interactive terminal connection and may replace an existing local Mac attachment for that same session. The daemon rejects attachment if the session is currently attached from a different endpoint, including the iPhone; have the user detach or reconnect from the appropriate endpoint instead.
