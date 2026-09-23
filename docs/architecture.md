# Architecture

The macOS daemon owns shared PTYs. Authenticated iOS connections and the owner-only local control socket attach to them; `clive sessions`, `clive attach`, and `clive shell` switch to framed terminal traffic after the control response. Closing or breaking a local control socket immediately detaches its attachment; repeated cleanup is harmless. The final detach starts the documented 90-minute reattachment grace period, while explicit termination, shell exit, revocation, and shutdown close every attachment.

## Components

| Component | Responsibility |
| --- | --- |
| iOS app | Discovers paired Macs, unlocks the local identity with biometrics, establishes a secure session, and renders/inputs terminal data. |
| macOS companion app | Signed menu bar owner of listeners, CloudKit rendezvous, pairing state, PTYs, and child `zsh` processes. |
| macOS CLI (`clive`) | Local control client for launch, pairing, status, cellular enablement, revocation, and shutdown. |
| Local network | Carries Bonjour discovery and encrypted point-to-point terminal sessions. It never receives shell data in plaintext. |
| CloudKit/APNs | Same-account private rendezvous and reachability hints; never a terminal transport or authorization source. |

Both clients are native Swift applications. Shared protocol, cryptography, framing, and terminal-model code should live in a Swift package consumed by the iOS app and macOS CLI.

Connectivity route selection follows the transport-independent contract in
[`connectivity-architecture.md`](connectivity-architecture.md). Route changes
reattach to the existing stable session and never create a replacement PTY.
An encrypted relay is a designed fallback extension described in
[`relay-architecture-and-threat-model.md`](relay-architecture-and-threat-model.md);
it is unavailable in V1 and is not an authorization or terminal-data endpoint.

## Connection flow

1. The intended macOS user launches the signed menu bar companion, which advertises `_iphone-term._tcp` through Bonjour.
2. The iOS app displays only discovered Macs that are already paired; unpaired devices are eligible only for the explicit pairing flow.
3. A paired phone unlocks its private key through LocalAuthentication, resolves the Mac over Bonjour, and opens a TLS connection.
4. Both sides verify the peer certificate against the pairing record before any application messages are processed.
5. The Mac allocates one PTY and starts `/bin/zsh -l`; raw terminal bytes flow in framed, encrypted messages. A lost transport may reattach to that PTY for 90 minutes after biometric authorization, without persisting screen contents.

## macOS CLI contract

Initial commands:

```text
clive start
clive pair
clive status
clive revoke <device-id>
clive stop
clive reset
```

`start` remains foreground by default so access is visible and ends when the process exits. The menu bar app's **Pair iPhone** window is the standard local pairing path; `pair` remains its terminal fallback and presents the same short-lived QR code after an interactive local confirmation. `status` lists paired devices and active sessions without exposing terminal content. `clive attach` lets an interactive local terminal select and attach to an existing Clive PTY; it does not adopt an unrelated terminal emulator session. `revoke` immediately removes the device trust record and terminates its active sessions. `reset` is interactive-only, refuses while a daemon is running, and removes only Clive's user-scoped daemon state. It intentionally requires every device to pair again and does not remove system Keychain entries.

The running process holds an owner-only lock for its state directory and owns a mode-`0600` Unix control socket. A second daemon using the same state directory fails before removing or replacing that socket. On shutdown, a daemon removes the socket path only when it still identifies the socket that process bound. All other commands use bounded Codable messages over that socket; they never edit live trust state independently.

## iOS UX boundaries

The app requires biometric authentication on initial launch and when more than five minutes have elapsed since the last successful verification. The in-memory grace period remains valid through exactly 300 seconds; foregrounding does not extend it. It must clearly distinguish a disconnected state, an unpaired Mac, a pairing-in-progress state, and an active shell. Terminal rendering follows standard VT behavior; clipboard and file-transfer capabilities are out of scope for V1.

When iOS becomes inactive, Clive immediately detaches every live transport and removes terminal previews from memory. On foreground it reconnects from opaque local and server session IDs only after the in-memory biometric grace check or successful authorization. Reconnection always sends `session.attach`; an expired, exited, revoked, or daemon-restarted PTY is shown as ended and never replaced implicitly. Only an explicit New Shell action sends `session.open`. Authentication cancellation leaves the workspace locked and opens no catalog or terminal connection. Process termination, a missing timestamp, or clock rollback invalidates the grace period.

The biometric and daemon clocks are independent. Returning at or before 300 seconds can reattach without another prompt, but does not extend the Mac's detached-session lifetime. Returning later requires Face ID first; if the Mac's 90-minute retention has also elapsed, the descriptor becomes ended and the user must explicitly create a new shell.
