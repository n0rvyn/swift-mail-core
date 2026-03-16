# NorIMAPKit

Swift IMAP4rev1 and SMTP client library built on Network.framework. Zero external dependencies.

Extracted from [mAil](https://github.com/AskNorv/mAil) for cross-project reuse.

## Products

- **NorIMAPKit** — IMAP4rev1 client: connection, command/response parsing, MIME decoding, BODYSTRUCTURE parsing
- **NorIMAPKitSMTP** — SMTP submission client: AUTH LOGIN, multipart/mixed with attachments

## Requirements

- macOS 14+ / iOS 17+
- Swift 6
- No external dependencies (Network.framework only)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AskNorv/NorIMAPKit.git", branch: "main")
]
```

Then add the products to your targets:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "NorIMAPKit", package: "NorIMAPKit"),
        .product(name: "NorIMAPKitSMTP", package: "NorIMAPKit"),
    ]
)
```

## Overview

### IMAP

- `IMAPConnection` — actor wrapping `NWConnection` for TLS IMAP connections
- `IMAPClient` — actor providing typed async methods for IMAP4rev1 commands (LOGIN, SELECT, UID SEARCH, UID FETCH, UID STORE, LIST, LOGOUT)
- `IMAPResponseParser` — stateless parser for tagged responses, SEARCH results, FETCH envelopes, BODYSTRUCTURE, LIST responses
- `IMAPBodyPart` — recursive enum modeling RFC 3501 BODYSTRUCTURE trees
- `IMAPFolder` — value type for LIST response mailbox entries
- `MIMEDecoder` — base64, quoted-printable, 7bit decoding; RFC 2047 encoded-word decoding; RFC 2822 full-message text extraction
- `Attachment` — value type for outgoing SMTP attachments

### SMTP

- `SMTPConnection` — actor wrapping `NWConnection` for TLS SMTP connections (port 465)
- `SMTPClient` — actor providing typed async methods for SMTP commands (EHLO, AUTH LOGIN, MAIL FROM, RCPT TO, DATA, QUIT)

## License

MIT
