# Connectivity architecture

The connectivity orchestrator chooses a transport independently of terminal
session ownership. Route providers publish `RouteCandidate` values in CliveCore;
the daemon verifies candidates using the existing mutual-TLS protocol before a
candidate becomes healthy.

## Route order and state

Routes are ranked LAN, private VPN, direct WAN/cellular, then relay. Private VPN
is opportunistic: Clive discovers or accepts a configured endpoint but does not
provision VPN credentials. Relay is an extension point and is not enabled in V1.

Each candidate exposes `unavailable`, `available`, `selected`, or `failed` as its
external state. Probe and drain details remain internal. A candidate is usable
only when it is available, authorized, healthy, and not expired.

The selector immediately fails over when the selected route becomes unusable. A
higher-priority healthy route must remain available for five seconds before a
handoff, preventing brief Wi-Fi/VPN changes from flapping the connection. Route
providers own probing and retry scheduling; the selector supplies bounded retry
constants for consistent behavior.

## Handoff invariants

Handoff is an overlap between transports, never a replacement shell:

1. Authenticate and verify the new route.
2. Attach it to the existing stable session ID and request replay from its known
   output offset.
3. Keep the old route authoritative for input until attachment and replay
   position are confirmed.
4. Transfer input authority and close the old route.

Failed handoffs leave the old route authoritative. Input is never replayed or
duplicated, and route changes never create a replacement PTY.
