# Pairing links

Secure pairing QR codes contain an HTTPS universal link at
`https://pair.clive.app/pair`. The link has no query string. Its fragment contains
the link version and the existing `CL2:` ticket payload:

```text
https://pair.clive.app/pair#v=1&ticket=CL2:…
```

The ticket remains a five-minute, single-use bearer for one pairing attempt. It
contains no private key, certificate, or reusable credential. The iOS app validates
the link version, payload, expiry, protocol version, endpoint, and certificate
fingerprint before opening a connection. Invalid, expired, cancelled, or unsupported
links fail closed and offer a new code path.

The fragment is deliberately used instead of query parameters. Browsers omit URL
fragments from HTTP requests, so the missing-app landing page cannot receive the
ticket. The landing page must redirect to the public TestFlight invitation without
copying, logging, analytics-tagging, or forwarding the fragment. After installation,
the user returns to the original link or rescans the code; the Mac retains the
pending ticket until it expires or is cancelled.

The `pair.clive.app` deployment must serve an `apple-app-site-association` file at
`/.well-known/apple-app-site-association` with the production iOS application
identifier and the `/pair` path. Unsupported iOS versions receive compatibility
guidance, and app versions that do not understand `v=1` receive an update-required
message rather than attempting legacy payload parsing.
