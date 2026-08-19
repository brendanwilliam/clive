# Architecture

## Components

| Component | Responsibility |
| --- | --- |
| iOS app | Discovers paired Macs, unlocks the local identity with biometrics, establishes a secure session, and renders/inputs terminal data. |
| macOS companion app | Signed menu bar owner of listeners, CloudKit rendezvous, pairing state, PTYs, and child `zsh` processes. |
| macOS CLI (`clive`) | Local control client for launch, pairing, status, cellular enablement, revocation, and shutdown. |
| Local network | Carries Bonjour discovery and encrypted point-to-point terminal sessions. It never receives shell data in plaintext. |
| CloudKit/APNs | Same-account private rendezvous and reachability hints; never a terminal transport or authorization source. |

Both clients are native Swift applications. Shared protocol, cryptography, framing, and terminal-model code should live in a Swift package consumed by the iOS app and macOS CLI.

## Connection flow

1. The intended macOS user launches the signed menu bar companion, which advertises `_iphone-term._tcp` through Bonjour.
2. The iOS app displays only discovered Macs that are already paired; unpaired devices are eligible only for the explicit pairing flow.
3. A paired phone unlocks its private key through LocalAuthentication, resolves the Mac over Bonjour, and opens a TLS connection.
4. Both sides verify the peer certificate against the pairing record before any application messages are processed.
5. The Mac allocates one PTY and starts `/bin/zsh -l`; raw terminal bytes flow in framed, encrypted messages until either party disconnects.

## macOS CLI contract

Initial commands:

```text
clive start
clive pair
clive status
clive revoke <device-id>
clive stop
```

`start` remains foreground by default so access is visible and ends when the process exits. `pair` presents a short-lived QR code only after an interactive local confirmation. `status` lists paired devices and active sessions without exposing terminal content. `revoke` immediately removes the device trust record and terminates its active sessions.

The running process owns a mode-`0600` Unix control socket. All other commands use bounded Codable messages over that socket; they never edit live trust state independently.

## iOS UX boundaries

The app requires biometric authentication when opening a saved Mac or resuming after it becomes inactive. It must clearly distinguish a disconnected state, an unpaired Mac, a pairing-in-progress state, and an active shell. Terminal rendering follows standard VT behavior; clipboard and file-transfer capabilities are out of scope for V1.
