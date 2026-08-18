# Automatic NAT-traversal design spike

This is the Phase 2 research boundary for Issue 10. It does not authorize a production relay or terminal-data cloud path.

- Measure direct IPv6, IPv4 NAT mapping, symmetric NAT, CGNAT, firewall, sleep/wake, and Wi-Fi/cellular handoff behavior across representative routers and carriers.
- Prototype address discovery and authenticated hole punching behind development-only flags. Carry no terminal bytes until pinned mutual TLS completes.
- Measure success rate, connection latency, background execution, notification coalescing, battery use, retry load, privacy, abuse resistance, and support burden without logging addresses or terminal content.
- Produce an architecture decision record choosing direct traversal, a separately specified and security-reviewed relay, or no automatic path.

Any relay proposal must separately define end-to-end encryption, authentication, metadata retention, quotas, abuse response, operational ownership, cost, and independent security review.
