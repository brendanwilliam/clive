# Privacy policy

_Effective August 21, 2026_

Clive is designed to connect an iPhone directly to a paired Mac. Clive does not operate an analytics, advertising, account, or terminal relay service.

## Data Clive handles

- Pairing identities, trusted-device metadata, preferences, and resumable-session metadata are stored on the user's devices.
- Terminal input and output travel directly between the paired devices over mutually authenticated TLS. Clive does not send terminal contents through CloudKit.
- If the user opts into cellular access, Clive stores encrypted, short-lived rendezvous metadata in the user's private iCloud/CloudKit account so paired devices can establish a direct connection.
- Apple and GitHub may process diagnostic, TestFlight, download, or service data under their own policies when those services are used.

Clive does not sell personal information. Removing pairings, deleting the apps, and deleting Clive's local application-support data removes device-local Clive data. CloudKit records expire and may also be removed by disabling cellular access.

Questions or privacy requests may be sent to `clive.maintainers@gmail.com`.
