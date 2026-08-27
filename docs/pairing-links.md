# Pairing links

Secure pairing QR codes contain a Clive app link at `clive://pair`. The link has
no query string. Its fragment contains the link version and the existing `CL2:`
ticket payload:

```text
clive://pair#v=1&ticket=CL2:…
```

The ticket remains a one-minute, single-use bearer for one pairing attempt. It
contains no private key, certificate, or reusable credential. The iOS app validates
the link version, payload, expiry, protocol version, endpoint, and certificate
fingerprint before opening a connection. Invalid, expired, cancelled, or unsupported
links fail closed and offer a new code path.

The fragment is deliberately used instead of query parameters. The app URL scheme
opens the installed iOS app directly without sending the ticket to a website. If
Clive is not installed, the Camera app cannot complete pairing; install Clive and
rescan the code. The Mac retains the pending ticket until it expires or is
cancelled.

HTTPS links at `https://pair.clive.app/pair` remain accepted for compatibility and
may be used by a future website fallback. If enabled, that deployment must serve
an `apple-app-site-association` file at `/.well-known/apple-app-site-association`
with the production iOS application identifier and the `/pair` path. Unsupported
iOS versions receive compatibility guidance, and app versions that do not
understand `v=1` receive an update-required message rather than attempting legacy
payload parsing.
