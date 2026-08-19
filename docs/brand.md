# Clive brand guide

## Name and positioning

- Product name: **Clive**
- App Store title: **Clive - CLI for iOS**
- CLI command: `clive`
- Repository name: `clive`
- Positioning: A lightweight, security-first way for developers and coding-agent users to access their Mac terminal from iOS.

Use “Clive” in interface labels and prose. Use the full App Store title when identifying the iOS listing.

## Voice and visual direction

Write in direct, calm language. Explain security boundaries concretely without claiming that CloudKit transports terminal data or grants access. Prefer native Apple typography, system terminal and shield symbols, high contrast, and restrained color. Screenshots and App Store materials should show the connection journey without exposing real hostnames, terminal content, credentials, fingerprints, or pairing secrets.

## QR codes

An App Store discovery QR code opens only the store listing and should be labeled **Get Clive for iPhone**. A secure pairing QR code is generated locally by `clive pair`, expires after five minutes, and should be labeled **Pair this iPhone**. Never reuse one design or label for the other purpose.
