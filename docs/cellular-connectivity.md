# Cellular and direct-WAN connectivity

Cellular access is an opt-in direct connection between a paired iPhone and Mac. The signed macOS menu bar companion must be running and **Allow connection over cellular** must be enabled. LAN Bonjour remains preferred, followed by a configured private VPN, public IPv6, and finally an explicitly configured private-beta public endpoint.

Both apps use the same CloudKit container's private database. A custom zone stores opaque per-device records containing only application-encrypted, five-minute endpoint advertisements, WAN gate tokens, replay metadata, or reachability requests. CloudKit notifications are coalescible hints to fetch current records.

Terminal input, output, shell state, private keys, and PTYs never transit CloudKit or APNs. Every terminal connection still uses TLS 1.3 mutual authentication and the exact certificate pins established by QR pairing. The WAN gate token enforces the Mac's cellular setting; it is not device authentication.

Configure the same CloudKit container and signing team in both apps' `Local.xcconfig` files. Deploy and promote the CloudKit schema before release. Existing pairs must connect once over LAN or their private VPN to exchange rendezvous keys and verify the same Apple Account.

The companion first advertises globally routable IPv6. With explicit owner consent it can instead request a leased TCP mapping using PCP, then NAT-PMP; UPnP is not used. Unsupported routers fall back to a guided manual TCP-forwarding rule and a public hostname or address. Private/shared external addresses are reported as possible double NAT or CGNAT; Clive does not bypass CGNAT and still provides no relay.

Both the menu-bar **Set Up Cellular Access** window and `clive cellular setup` drive the same daemon-owned configuration. The listener defaults to stable port `64236`, while the router may allocate a different external port. A setup is not reported as available until a paired iPhone, with Wi-Fi off, completes a challenge-bound mutual-TLS probe through the advertised route. The probe validates the rotating WAN gate but never creates a PTY or shell.

Disabling cellular access or revoking a phone invalidates local gate tokens before CloudKit deletion. Cached records cannot open a new WAN shell. Network loss always closes the PTY; retrying creates a new shell.
