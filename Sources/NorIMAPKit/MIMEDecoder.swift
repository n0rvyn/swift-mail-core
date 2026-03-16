// MIMEDecoder.swift
// mAil — MIME Content-Transfer-Encoding decoders and encoders
//
// Static Data extension methods for decoding IMAP-fetched body sections,
// and instance methods for encoding outgoing attachment data.
//
// Supported decoding (RFC 2045 §6):
//   base64           — standard base64, may contain line breaks every 76 chars
//   quoted-printable — soft line breaks + =XX hex escapes
//   7bit             — no encoding; convert string to UTF-8 Data directly
//   8bit             — same as 7bit for our purposes
//   binary           — treat as 7bit (rare in practice)
//
// Encoding (outgoing SMTP attachments):
//   encodedAsBase64MIME() — base64 with 76-char line wrapping per RFC 2045 §6.8
//
// Privacy: these methods operate on in-memory Data only. No disk I/O.

import Foundation

// MARK: - RFC 2047 Encoded-Word Decoder

/// Decodes RFC 2047 encoded-words in IMAP header fields (Subject, From display name).
///
/// Encoded-word format: `=?charset?encoding?payload?=`
///   - charset: e.g. "UTF-8", "GB2312"
///   - encoding: "B" (base64) or "Q" (quoted-printable variant)
///   - payload: encoded text
///
/// Example: `=?UTF-8?B?5rWL6K+V?=` → "测试"
///
/// Safety: if the input contains no `=?` substring, returns it unchanged.
/// This prevents double-decoding when the IMAP server (e.g. Gmail) already returns
/// decoded UTF-8 strings in ENVELOPE fields.
nonisolated enum RFC2047Decoder {

    /// Decodes all RFC 2047 encoded-words in `input`.
    /// Adjacent encoded-words separated only by whitespace are joined (RFC 2047 §6.2).
    /// Returns the original string unchanged if no encoded-words are found.
    static func decode(_ input: String) -> String {
        // Fast path: no encoded-words possible.
        guard input.contains("=?") else { return input }

        // Pattern: =?charset?B or Q?payload?=
        // Case-insensitive encoding flag (B/b or Q/q).
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let nsInput = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))

        guard !matches.isEmpty else { return input }

        var result = ""
        var lastEnd = input.startIndex
        var previousWasEncodedWord = false

        for match in matches {
            guard match.numberOfRanges == 4,
                  let fullRange = Range(match.range, in: input),
                  let charsetRange = Range(match.range(at: 1), in: input),
                  let encodingRange = Range(match.range(at: 2), in: input),
                  let payloadRange = Range(match.range(at: 3), in: input)
            else { continue }

            let gap = String(input[lastEnd..<fullRange.lowerBound])

            // RFC 2047 §6.2: whitespace between adjacent encoded-words is ignored.
            if previousWasEncodedWord && gap.allSatisfy({ $0.isWhitespace }) {
                // Skip the inter-word whitespace.
            } else {
                result += gap
            }

            let charset = String(input[charsetRange])
            let encodingFlag = String(input[encodingRange]).uppercased()
            let payload = String(input[payloadRange])

            if let decoded = decodePayload(payload, encoding: encodingFlag, charset: charset) {
                result += decoded
            } else {
                // Decoding failed — preserve the original encoded-word literally.
                result += String(input[fullRange])
            }

            lastEnd = fullRange.upperBound
            previousWasEncodedWord = true
        }

        // Append any remaining text after the last encoded-word.
        result += String(input[lastEnd...])
        return result
    }

    // MARK: - Private

    private static func decodePayload(_ payload: String, encoding: String, charset: String) -> String? {
        let data: Data?
        switch encoding {
        case "B":
            data = Data.decodedFromBase64(string: payload)
        case "Q":
            // RFC 2047 Q-encoding is like quoted-printable but uses `_` for space.
            let qpInput = payload.replacingOccurrences(of: "_", with: " ")
            data = Data.decodedFromQuotedPrintable(string: qpInput)
        default:
            return nil
        }
        guard let data, !data.isEmpty else { return nil }
        let encoding = Data.stringEncoding(fromCharset: charset.lowercased())
        return String(data: data, encoding: encoding)
    }
}

// MARK: - RFC 2822 Full-Message Decoder

/// Extracts readable text from a raw RFC 2822 message (as returned by IMAP BODY.PEEK[]).
///
/// Handles:
///   - Simple text/plain or text/html messages
///   - multipart/alternative (prefers text/plain, falls back to text/html)
///   - multipart/mixed containing nested multipart/alternative
///   - Content-Transfer-Encoding: base64, quoted-printable, 7bit/8bit
///   - Charset conversion via `Data.stringEncoding(fromCharset:)`
///
/// Fallback: if no text part is found, returns the body with headers stripped.
nonisolated enum RFC2822Decoder {

    /// Extracts readable text body from a raw RFC 2822 message string.
    ///
    /// - Parameter rawMessage: Complete RFC 2822 message (headers + body).
    /// - Returns: Decoded text content. Falls back to raw body (headers stripped)
    ///   if MIME parsing fails.
    static func extractTextBody(_ rawMessage: String) -> String {
        let normalized = rawMessage.replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = splitHeadersAndBody(normalized)

        guard !body.isEmpty else { return "" }

        let contentType = extractHeaderValue("content-type", from: headers)?.lowercased() ?? "text/plain"

        if contentType.contains("multipart/") {
            guard let boundary = extractBoundary(from: contentType) else {
                return body.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let decoded = extractTextFromMultipart(body, boundary: boundary, maxDepth: 5) {
                return decoded
            }
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let encoding = extractHeaderValue("content-transfer-encoding", from: headers)?.lowercased()
            .trimmingCharacters(in: .whitespaces) ?? "7bit"
        let charset = extractCharset(from: contentType)

        if contentType.contains("text/html") {
            if let decoded = decodePartBody(body, encoding: encoding, charset: charset) {
                return stripHTMLTags(decoded)
            }
        } else {
            // text/plain or any other text type
            if let decoded = decodePartBody(body, encoding: encoding, charset: charset) {
                return decoded
            }
        }

        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Header/Body Splitting

    /// Splits a normalized (LF-only) RFC 2822 message at the first blank line.
    private static func splitHeadersAndBody(_ message: String) -> (headers: String, body: String) {
        // RFC 2822: headers and body separated by an empty line.
        if let range = message.range(of: "\n\n") {
            let headers = String(message[message.startIndex..<range.lowerBound])
            let body = String(message[range.upperBound...])
            return (headers, body)
        }
        // No blank line found — entire message is headers (no body).
        return (message, "")
    }

    // MARK: - Header Parsing

    /// Extracts a header value by name, handling continuation lines (folded headers).
    /// Returns nil if the header is not found.
    private static func extractHeaderValue(_ name: String, from headers: String) -> String? {
        let lines = headers.components(separatedBy: "\n")
        let prefix = name + ":"
        var value: String?
        var collecting = false

        for line in lines {
            if collecting {
                // Continuation line starts with whitespace (folding per RFC 2822 §2.2.3).
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    value? += " " + line.trimmingCharacters(in: .whitespaces)
                } else {
                    break
                }
            } else if line.lowercased().hasPrefix(prefix) {
                value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                collecting = true
            }
        }
        return value
    }

    /// Extracts the boundary parameter from a Content-Type header value.
    /// Example: `multipart/alternative; boundary="abc123"` → `"abc123"`
    private static func extractBoundary(from contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var boundary = String(contentType[range.upperBound...])
        // Remove any trailing parameters after semicolon.
        if let semi = boundary.firstIndex(of: ";") {
            boundary = String(boundary[boundary.startIndex..<semi])
        }
        boundary = boundary.trimmingCharacters(in: .whitespaces)
        // Strip quotes if present.
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") && boundary.count >= 2 {
            boundary = String(boundary.dropFirst().dropLast())
        }
        return boundary.isEmpty ? nil : boundary
    }

    /// Extracts the charset parameter from a Content-Type header value.
    /// Returns nil if charset is not specified.
    private static func extractCharset(from contentType: String) -> String? {
        guard let range = contentType.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }
        var charset = String(contentType[range.upperBound...])
        if let semi = charset.firstIndex(of: ";") {
            charset = String(charset[charset.startIndex..<semi])
        }
        charset = charset.trimmingCharacters(in: .whitespaces)
        if charset.hasPrefix("\"") && charset.hasSuffix("\"") && charset.count >= 2 {
            charset = String(charset.dropFirst().dropLast())
        }
        return charset.isEmpty ? nil : charset
    }

    // MARK: - Multipart Extraction

    /// Finds the best text part in a multipart body.
    /// Prefers text/plain; falls back to text/html (tag-stripped).
    /// Recurses into nested multipart structures up to `maxDepth`.
    private static func extractTextFromMultipart(
        _ body: String,
        boundary: String,
        maxDepth: Int
    ) -> String? {
        guard maxDepth > 0 else { return nil }

        let delimiter = "--" + boundary
        let parts = body.components(separatedBy: delimiter)

        // First part is preamble (before first boundary), skip it.
        // Last part ending with "--" is epilogue, skip it.
        var textPlain: String?
        var textHTML: String?

        for part in parts.dropFirst() {
            // Skip closing boundary marker.
            if part.hasPrefix("--") { continue }

            let (partHeaders, partBody) = splitHeadersAndBody(part)
            let partCT = extractHeaderValue("content-type", from: partHeaders)?.lowercased() ?? "text/plain"

            if partCT.contains("multipart/") {
                // Nested multipart — recurse.
                if let nestedBoundary = extractBoundary(from: partCT),
                   let nested = extractTextFromMultipart(partBody, boundary: nestedBoundary, maxDepth: maxDepth - 1) {
                    return nested
                }
                continue
            }

            let partEncoding = extractHeaderValue("content-transfer-encoding", from: partHeaders)?
                .lowercased().trimmingCharacters(in: .whitespaces) ?? "7bit"
            let partCharset = extractCharset(from: partCT)

            if partCT.contains("text/plain") {
                if let decoded = decodePartBody(partBody, encoding: partEncoding, charset: partCharset) {
                    textPlain = decoded
                }
            } else if partCT.contains("text/html") && textPlain == nil {
                if let decoded = decodePartBody(partBody, encoding: partEncoding, charset: partCharset) {
                    textHTML = decoded
                }
            }
        }

        if let plain = textPlain { return plain }
        if let html = textHTML { return stripHTMLTags(html) }
        return nil
    }

    // MARK: - Content-Transfer-Encoding Decode

    /// Decodes a MIME part body using the specified Content-Transfer-Encoding and charset.
    private static func decodePartBody(
        _ body: String,
        encoding: String,
        charset: String?
    ) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let data: Data?
        switch encoding {
        case "base64":
            data = Data.decodedFromBase64(string: trimmed)
        case "quoted-printable":
            data = Data.decodedFromQuotedPrintable(string: trimmed)
        case "7bit", "8bit", "binary":
            data = Data.decodedFrom7bit(string: trimmed)
        default:
            // Unknown encoding — treat as 7bit (RFC 2045 §6.1 default).
            data = Data.decodedFrom7bit(string: trimmed)
        }

        guard let data, !data.isEmpty else { return nil }
        let stringEncoding = Data.stringEncoding(fromCharset: charset)
        return String(data: data, encoding: stringEncoding)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - HTML Tag Stripping

    /// Best-effort HTML → plain text conversion.
    /// Strips tags, decodes common HTML entities, normalizes whitespace.
    private static func stripHTMLTags(_ html: String) -> String {
        var text = html
        // Replace <br>, <br/>, <br /> with newlines.
        text = text.replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n",
            options: .regularExpression, range: nil
        )
        // Replace block-level closing tags with newlines.
        text = text.replacingOccurrences(
            of: #"</(?:p|div|li|tr|h[1-6])>"#, with: "\n",
            options: [.regularExpression, .caseInsensitive], range: nil
        )
        // <a href="URL">text</a> → text (URL)
        text = text.replacingOccurrences(
            of: #"<a\s[^>]*href\s*=\s*"([^"]*)"[^>]*>(.*?)</a>"#,
            with: "$2 ($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        // <img alt="text" ...> → [Image: text]
        text = text.replacingOccurrences(
            of: #"<img\s[^>]*alt\s*=\s*"([^"]+)"[^>]*/?>"#,
            with: "[Image: $1]",
            options: [.regularExpression, .caseInsensitive]
        )
        // Remove all remaining tags.
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#, with: "",
            options: .regularExpression, range: nil
        )
        // Decode common HTML entities.
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        // Decode numeric HTML entities (&#NNN; and &#xHHH;).
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                if let hexRange = Range(match.range(at: 1), in: text),
                   let codePoint = UInt32(text[hexRange], radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let fullRange = Range(match.range, in: text)!
                    text.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches.reversed() {
                if let numRange = Range(match.range(at: 1), in: text),
                   let codePoint = UInt32(text[numRange]),
                   let scalar = Unicode.Scalar(codePoint) {
                    let fullRange = Range(match.range, in: text)!
                    text.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        // Collapse multiple blank lines.
        text = text.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n",
            options: .regularExpression, range: nil
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - MIMEDecoder

extension Data {

    /// Decodes a base64-encoded IMAP body section string into raw `Data`.
    ///
    /// IMAP base64 sections are folded with CRLF or LF every 76 characters.
    /// Whitespace is stripped before decoding. Returns `nil` only if the
    /// resulting string is non-empty but produces no valid base64 data.
    nonisolated static func decodedFromBase64(string: String) -> Data? {
        // Strip all whitespace (CRLF folding in base64 MIME output).
        let stripped = string.components(separatedBy: .whitespacesAndNewlines).joined()
        guard !stripped.isEmpty else { return Data() }
        // Swift's Data(base64Encoded:) requires padding; add if needed.
        let padded = stripped.padding(
            toLength: stripped.count + (4 - stripped.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )
        return Data(base64Encoded: padded, options: [])
    }

    /// Decodes a quoted-printable IMAP body section string into raw `Data`.
    ///
    /// Rules (RFC 2045 §6.7):
    ///   - `=XX` where XX is two hex digits: decoded to the corresponding byte.
    ///   - `=\r\n` or `=\n` (soft line break): remove the `=` and the line ending.
    ///   - All other characters: pass through as UTF-8 bytes.
    nonisolated static func decodedFromQuotedPrintable(string: String) -> Data {
        var result = Data()
        var i = string.startIndex

        while i < string.endIndex {
            let ch = string[i]

            if ch == "=" {
                let next = string.index(after: i)
                guard next < string.endIndex else {
                    // Trailing `=` with nothing after — skip.
                    break
                }
                let ch2 = string[next]

                // Soft line break: `=\r\n` or `=\n`
                if ch2 == "\r" || ch2 == "\n" {
                    // Skip `=` and any following CRLF.
                    i = next
                    while i < string.endIndex && (string[i] == "\r" || string[i] == "\n") {
                        i = string.index(after: i)
                    }
                    continue
                }

                // Hex-encoded byte: `=XX`
                let hexEnd = string.index(next, offsetBy: 2, limitedBy: string.endIndex) ?? string.endIndex
                if hexEnd > next {
                    let hexStr = String(string[next..<hexEnd])
                    if let byte = UInt8(hexStr, radix: 16) {
                        result.append(byte)
                        i = hexEnd
                        continue
                    }
                }

                // Not a valid escape — pass `=` through literally.
                result.append(contentsOf: "=".utf8)
                i = string.index(after: i)

            } else {
                // Regular character — append as UTF-8.
                let scalar = ch.unicodeScalars.first!
                if scalar.value < 128 {
                    result.append(UInt8(scalar.value))
                } else {
                    result.append(contentsOf: String(ch).utf8)
                }
                i = string.index(after: i)
            }
        }
        return result
    }

    /// Interprets a 7bit or 8bit encoded string as UTF-8 Data.
    /// No transformation needed — the raw bytes are the content.
    nonisolated static func decodedFrom7bit(string: String) -> Data {
        return Data(string.utf8)
    }

    // MARK: - Charset → String.Encoding

    /// Maps a MIME charset name (lowercased) to a `String.Encoding`.
    ///
    /// Common charsets encountered in email:
    ///   - utf-8, us-ascii, iso-8859-1, iso-8859-2, gb2312, gbk, gb18030, big5
    ///
    /// Returns `.utf8` for nil or unrecognised charset values.
    nonisolated static func stringEncoding(fromCharset charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased() else { return .utf8 }
        switch charset {
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii":
            return .ascii
        case "iso-8859-1", "latin1", "iso-latin-1":
            return .isoLatin1
        case "iso-8859-2", "latin2", "iso-latin-2":
            return .isoLatin2
        case "gb2312", "gbk", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case "big5":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            )
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "iso-2022-jp":
            return .iso2022JP
        case "euc-kr":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
                )
            )
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        default:
            return .utf8
        }
    }

    // MARK: - Encoding (Outgoing)

    /// Encodes `self` as a base64 string with CRLF line breaks every 76 characters,
    /// conforming to RFC 2045 §6.8 for use in SMTP DATA multipart attachment parts.
    ///
    /// Foundation's `.lineLength76Characters` option uses LF (`\n`) as the line break
    /// character. This method replaces each `\n` with `\r\n` to produce the CRLF
    /// line endings required by RFC 2045 and RFC 5321.
    ///
    /// - Returns: A base64 string with 76-character lines separated by `\r\n`.
    public nonisolated func encodedAsBase64MIME() -> String {
        // Foundation produces LF line breaks; RFC 2045 §6.8 requires CRLF.
        let lfEncoded = self.base64EncodedString(options: .lineLength76Characters)
        return lfEncoded
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}
