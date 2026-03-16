// IMAPResponseParser.swift
// mAil — Pure IMAP4rev1 response parser (RFC 3501)
//
// All methods are static — no state, no actor isolation needed.
// IMAPClient feeds raw lines from IMAPConnection into these parsers.
//
// Supported response types:
//   • Tagged:   "A001 OK", "A001 NO", "A001 BAD"
//   • Untagged: "* N EXISTS", "* FETCH", "* SEARCH", "* FLAGS"
//   • Continuation: "+ ..." (not parsed here — IMAPClient handles raw "+")
//
// FETCH envelope fields extracted: subject, from (name + email), date, flags.
// FETCH body (literal octets) is passed through as raw String — not parsed here.

import Foundation

// MARK: - IMAPTaggedResult

/// The result of a tagged IMAP command response (`A001 OK`/`NO`/`BAD`).
nonisolated struct IMAPTaggedResult: Sendable {
    enum Status: Sendable { case ok, no, bad }
    let tag: String
    let status: Status
    let text: String   // Human-readable status text from the server
}

// MARK: - IMAPFetchedMessage

/// Fields extracted from an IMAP FETCH response for a single message.
/// Body text is excluded — fetched separately on demand and never persisted.
nonisolated struct IMAPFetchedMessage: Sendable {
    let uid: UInt32
    let subject: String
    let sender: String       // "Display Name <email@host.com>" or bare "email@host.com"
    let date: Date
    let internalDate: Date?  // IMAP INTERNALDATE (server receive time); nil if unparseable
    let messageId: String    // Message-ID header value (used for dedup)
    let to: String           // Comma-separated bare To email addresses (empty if none)
    let cc: String           // Comma-separated bare Cc email addresses (empty if none)
    let inReplyTo: String    // Value of In-Reply-To header (empty if absent)
    let isSeen: Bool         // True if the \Seen flag is present
}

// MARK: - IMAPResponseParser

nonisolated enum IMAPResponseParser {

    // MARK: - Tagged Response

    /// Parses a tagged response line into an `IMAPTaggedResult`.
    /// Returns `nil` if the line is not a tagged response (e.g. it's untagged `*`).
    ///
    /// Input example: `"A003 OK [READ-WRITE] SELECT completed"`
    /// Output: `IMAPTaggedResult(tag: "A003", status: .ok, text: "[READ-WRITE] SELECT completed")`
    static func parseTagged(_ line: String) -> IMAPTaggedResult? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let tag = String(parts[0])
        guard tag != "*", tag != "+" else { return nil }  // Untagged or continuation

        let statusStr = String(parts[1]).uppercased()
        let text = parts.count >= 3 ? String(parts[2]) : ""

        let status: IMAPTaggedResult.Status
        switch statusStr {
        case "OK":  status = .ok
        case "NO":  status = .no
        case "BAD": status = .bad
        default: return nil
        }
        return IMAPTaggedResult(tag: tag, status: status, text: text)
    }

    // MARK: - UID SEARCH Response

    /// Parses `* SEARCH uid1 uid2 uid3 ...` into an array of `UInt32` UIDs.
    /// Returns an empty array for `* SEARCH` with no UIDs (mailbox empty or no matches).
    ///
    /// Input example: `"* SEARCH 101 102 103"`
    static func parseSearchUIDs(_ line: String) -> [UInt32] {
        // "* SEARCH" followed by zero or more UID integers
        let upper = line.uppercased()
        guard upper.hasPrefix("* SEARCH") else { return [] }
        let remainder = line.dropFirst("* SEARCH".count).trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return [] }
        return remainder.split(separator: " ").compactMap { UInt32($0) }
    }

    // MARK: - FETCH Envelope

    /// Parses lines belonging to a single UID FETCH response and extracts
    /// envelope fields (subject, from, date, flags, message-id).
    ///
    /// The caller feeds all lines of one untagged FETCH response here.
    /// For multi-line FETCH responses containing literals, the literal data
    /// (already read by IMAPConnection) must be spliced into the lines array
    /// as a plain string before calling this method.
    ///
    /// Input example (lines joined as a block):
    /// ```
    /// * 5 FETCH (UID 101 FLAGS (\Seen) ENVELOPE ("Tue, 24 Feb 2026 10:00:00 +0000"
    ///   "Meeting request" (("Alice" NIL "alice" "corp.com")) ...))
    /// ```
    ///
    /// Returns `nil` if the lines cannot be parsed (malformed FETCH).
    static func parseFetchEnvelope(lines: [String]) -> IMAPFetchedMessage? {
        let joined = lines.joined(separator: " ")

        // Extract UID
        guard let uid = extractUInt32(key: "UID", from: joined) else { return nil }

        // Extract FLAGS
        let isSeen = extractFlags(from: joined).contains("\\Seen")

        // Extract INTERNALDATE (server receive time).
        // Format: INTERNALDATE "24-Feb-2026 10:00:00 +0000"
        let internalDate = extractInternalDate(from: joined)

        // Extract ENVELOPE — this is a parenthesised list:
        // (date subject from sender reply-to to cc bcc in-reply-to message-id)
        guard let envelopeContent = extractParenthesised(key: "ENVELOPE", from: joined) else { return nil }
        let envelopeParts = splitEnvelopeParts(envelopeContent)
        // RFC 3501 envelope order: date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id
        guard envelopeParts.count >= 10 else { return nil }

        let rawDate    = envelopeParts[0]
        let rawSubject = envelopeParts[1]
        let rawFrom    = envelopeParts[2]
        let rawTo         = envelopeParts[5]
        let rawCc         = envelopeParts[6]
        let rawInReplyTo  = envelopeParts[8]
        let rawMsgId      = envelopeParts[9]

        let subject   = RFC2047Decoder.decode(decodeIMAPString(rawSubject))
        let sender    = RFC2047Decoder.decode(parseAddressList(rawFrom))
        let date      = parseIMAPDate(rawDate)
        let messageId = decodeIMAPString(rawMsgId)
        let to        = parseAllAddresses(rawTo)
        let cc        = parseAllAddresses(rawCc)
        let inReplyTo = decodeIMAPString(rawInReplyTo)

        return IMAPFetchedMessage(
            uid: uid,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            sender: sender.isEmpty ? "Unknown" : sender,
            date: date ?? Date(),
            internalDate: internalDate,
            messageId: messageId.isEmpty ? "uid-\(uid)" : messageId,
            to: to,
            cc: cc,
            inReplyTo: inReplyTo,
            isSeen: isSeen
        )
    }

    // MARK: - Private Helpers

    /// Extracts a UInt32 value for `KEY N` patterns (e.g. `UID 101`).
    private static func extractUInt32(key: String, from text: String) -> UInt32? {
        let pattern = key + " ([0-9]+)"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match.split(separator: " ").last.flatMap { UInt32($0) }
    }

    /// Extracts FLAGS list as an array of flag strings.
    /// Example: `FLAGS (\Seen \Answered)` → `["\\Seen", "\\Answered"]`
    private static func extractFlags(from text: String) -> [String] {
        guard let flagsRange = text.range(of: #"FLAGS \(([^)]*)\)"#, options: .regularExpression) else {
            return []
        }
        let flagsMatch = String(text[flagsRange])
        // Extract content between first `(` and last `)`
        guard let open = flagsMatch.firstIndex(of: "("),
              let close = flagsMatch.lastIndex(of: ")") else { return [] }
        let inner = String(flagsMatch[flagsMatch.index(after: open)..<close])
        return inner.split(separator: " ").map { String($0) }
    }

    /// Extracts and parses the INTERNALDATE from a FETCH response.
    ///
    /// IMAP INTERNALDATE format (RFC 3501 §7.4.2):
    ///   `INTERNALDATE "24-Feb-2026 10:00:00 +0000"`
    ///
    /// Returns `nil` if INTERNALDATE is absent or the date string cannot be parsed.
    private static func extractInternalDate(from text: String) -> Date? {
        guard let range = text.range(of: #"INTERNALDATE "([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        // Extract the quoted date string between the first and last quote.
        guard let openQuote = match.firstIndex(of: "\""),
              let closeQuote = match.lastIndex(of: "\""),
              openQuote < closeQuote else { return nil }
        let dateStr = String(match[match.index(after: openQuote)..<closeQuote])
        // RFC 3501 date-time format: "dd-Mon-yyyy HH:mm:ss +zzzz"
        let fmt = makeFormatter("d-MMM-yyyy HH:mm:ss Z")
        return fmt.date(from: dateStr.trimmingCharacters(in: .whitespaces))
    }

    /// Extracts the content of a parenthesised IMAP structure for `KEY (...)`.
    private static func extractParenthesised(key: String, from text: String) -> String? {
        guard let keyRange = text.range(of: key + " (", options: .caseInsensitive) else { return nil }
        let start = text.index(keyRange.upperBound, offsetBy: -1)  // points to `(`
        var depth = 0
        var idx = start
        var result: Substring = ""
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1; if depth == 0 { result = text[text.index(after: start)..<idx]; break } }
            idx = text.index(after: idx)
        }
        return result.isEmpty ? nil : String(result)
    }

    /// Splits IMAP envelope parenthesised content into its 10 positional parts.
    /// Handles nested parentheses (address lists) and quoted strings.
    private static func splitEnvelopeParts(_ content: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var prev: Character = " "
        for ch in content {
            if ch == "\"" && prev != "\\" { inQuote.toggle() }
            else if !inQuote && ch == "(" { depth += 1 }
            else if !inQuote && ch == ")" { depth -= 1 }
            if !inQuote && depth == 0 && ch == " " && !current.isEmpty {
                parts.append(current); current = ""
            } else {
                current.append(ch)
            }
            prev = ch
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Decodes a quoted IMAP string or NIL.
    private static func decodeIMAPString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.uppercased() == "NIL" { return "" }
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return trimmed
    }

    /// Parses an IMAP address list `(("Name" NIL "mailbox" "host") ...)` and returns
    /// the first address as `"Name <mailbox@host>"` or `"mailbox@host"`.
    private static func parseAddressList(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased() != "NIL", trimmed.hasPrefix("(") else { return "" }
        // IMAP address list is ((name atDomain mailbox host) ...).
        // First extractParenthesised gets the first address struct: (name atDomain mailbox host)
        // Second extractParenthesised strips those inner parens to get: name atDomain mailbox host
        guard let inner = extractParenthesised(key: "", from: "k " + trimmed) else { return "" }
        guard let addressContent = extractParenthesised(key: "", from: "k " + inner) else { return "" }
        let addrParts = splitEnvelopeParts(addressContent)
        guard addrParts.count >= 4 else { return "" }
        let name    = decodeIMAPString(addrParts[0])
        let mailbox = decodeIMAPString(addrParts[2])
        let host    = decodeIMAPString(addrParts[3])
        let email   = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
        return name.isEmpty ? email : "\(name) <\(email)>"
    }

    /// Parses an IMAP address list `(("Name" NIL "mailbox" "host") ...)` and returns
    /// all bare email addresses as a comma-separated string: `"mailbox@host, mailbox2@host2"`.
    /// Display names are intentionally omitted to avoid comma-in-name splitting issues
    /// when the cc field is later split for reply pre-fill.
    /// Returns empty string for NIL or malformed input.
    private static func parseAllAddresses(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased() != "NIL", trimmed.hasPrefix("(") else { return "" }

        // The address list is a sequence of address structs: ((..)(..)(..))
        // Strip the outer parens to get the inner structs sequence.
        guard let inner = extractParenthesised(key: "", from: "k " + trimmed) else { return "" }

        // Split into individual address structs by scanning for balanced parens.
        var addresses: [String] = []
        var idx = inner.startIndex
        while idx < inner.endIndex {
            // Skip whitespace between address structs.
            while idx < inner.endIndex && inner[idx] == " " {
                idx = inner.index(after: idx)
            }
            guard idx < inner.endIndex, inner[idx] == "(" else { break }

            // Find the matching closing paren for this address struct.
            var depth = 0
            var end = idx
            var i = idx
            while i < inner.endIndex {
                if inner[i] == "(" { depth += 1 }
                if inner[i] == ")" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
                i = inner.index(after: i)
            }
            let addressStruct = String(inner[idx...end])
            if let addressContent = extractParenthesised(key: "", from: "k " + addressStruct) {
                let addrParts = splitEnvelopeParts(addressContent)
                if addrParts.count >= 4 {
                    let mailbox = decodeIMAPString(addrParts[2])
                    let host    = decodeIMAPString(addrParts[3])
                    let email   = host.isEmpty ? mailbox : "\(mailbox)@\(host)"
                    // Store only bare email addresses (no display names) to avoid
                    // comma-in-display-name breaking the split in reply pre-fill.
                    if !email.isEmpty { addresses.append(email) }
                }
            }
            idx = inner.index(after: end)
        }
        return addresses.joined(separator: ", ")
    }

    /// Parses an IMAP ENVELOPE date string into a Swift `Date`.
    ///
    /// Handles common RFC 2822 date variants seen in the wild:
    ///   - `"Tue, 24 Feb 2026 10:00:00 +0000"` (standard)
    ///   - `"24 Feb 2026 10:00:00 +0000"` (no weekday)
    ///   - `"Tue, 24 Feb 2026 10:00:00 PST"` (timezone name)
    ///   - `"Tue, 24 Feb 2026 10:00:00 +0000 (UTC)"` (with parenthesised tz comment)
    ///   - `"2026-02-24T10:00:00+0000"` (ISO 8601; rare)
    private static func parseIMAPDate(_ raw: String) -> Date? {
        var trimmed = decodeIMAPString(raw)
        // Strip parenthesised timezone comment, e.g. "(UTC)" or "(PST)".
        if let parenStart = trimmed.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) {
            trimmed = String(trimmed[trimmed.startIndex..<parenStart.lowerBound])
        }
        let formatters: [DateFormatter] = [
            makeFormatter("EEE, d MMM yyyy HH:mm:ss Z"),
            makeFormatter("d MMM yyyy HH:mm:ss Z"),
            makeFormatter("EEE, d MMM yyyy HH:mm:ss z"),
            makeFormatter("EEE, dd MMM yyyy HH:mm:ss Z"),
            makeFormatter("d MMM yyyy HH:mm:ss z"),
            makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
        ]
        for fmt in formatters {
            if let date = fmt.date(from: trimmed) { return date }
        }
        return nil
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = format
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }
}

// MARK: - BODYSTRUCTURE Parser

nonisolated extension IMAPResponseParser {

    // MARK: Public Entry Point

    /// Parses the untagged BODYSTRUCTURE line returned by `UID FETCH <uid> (BODYSTRUCTURE)`.
    ///
    /// Input example (flat text/plain):
    ///   `* 5 FETCH (UID 101 BODYSTRUCTURE ("text" "plain" ("charset" "utf-8") NIL NIL "7bit" 1024 32))`
    ///
    /// Input example (multipart/mixed with text + PDF):
    ///   `* 5 FETCH (UID 101 BODYSTRUCTURE (("text" "plain" NIL NIL NIL "7bit" 512 10)("application" "pdf" ("name" "report.pdf") NIL NIL "base64" 204800) "mixed"))`
    ///
    /// Returns `nil` if the line contains no parseable BODYSTRUCTURE.
    static func parseBodyStructure(_ line: String) -> IMAPBodyPart? {
        // Extract the content between "BODYSTRUCTURE " and the matching closing paren.
        guard let bodyStructContent = extractParenthesised(key: "BODYSTRUCTURE", from: line) else {
            return nil
        }
        return parseBodyPart(bodyStructContent, sectionPath: "")
    }

    // MARK: - Recursive Part Parser

    /// Parses a single BODYSTRUCTURE part expression (without outer parens).
    /// `sectionPath` is the parent path prefix; empty string means top-level.
    ///
    /// A part expression is either:
    ///   - A multipart: starts with `(` (first token is a child part, not a quoted string)
    ///   - A single part: starts with a quoted type string like `"text"`
    private static func parseBodyPart(_ content: String, sectionPath: String) -> IMAPBodyPart? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Multipart detection: content starts with `(` meaning the first element is
        // itself a parenthesised body part (not a quoted MIME type string).
        if trimmed.hasPrefix("(") {
            return parseMultipart(trimmed, sectionPath: sectionPath)
        } else {
            // Single part — first token must be the quoted MIME type string.
            return parseSinglePart(trimmed, sectionPath: sectionPath)
        }
    }

    // MARK: - Multipart Parser

    /// Parses a multipart body part.
    /// Format: `(<part1>)(<part2>)... "subtype" [ext-data]`
    /// Only parses depth 1 and depth 2. At depth 2, child multipart children
    /// are parsed shallowly (their children are collected but not recursed further).
    ///
    /// `sectionPath`: empty string = top-level (children get paths "1", "2", ...),
    ///                "2"          = second top-level part (children get "2.1", "2.2", ...)
    private static func parseMultipart(_ content: String, sectionPath: String) -> IMAPBodyPart? {
        var parts: [IMAPBodyPart] = []
        var idx = content.startIndex
        var childIndex = 1

        // Consume child parts — each is a parenthesised expression.
        while idx < content.endIndex && content[idx] == "(" {
            guard let (childContent, afterChild) = extractNextParenthesised(content, from: idx) else { break }

            // Build the section path for this child.
            let childPath = sectionPath.isEmpty ? "\(childIndex)" : "\(sectionPath).\(childIndex)"

            // Determine depth: if sectionPath is empty, we're at depth 1 (top-level children).
            // If sectionPath contains no ".", we're at depth 1 (children are depth 2).
            // Do not recurse past depth 2 child parts.
            let depth = sectionPath.isEmpty ? 1 : (sectionPath.components(separatedBy: ".").count + 1)
            let part: IMAPBodyPart?
            if depth <= 2 {
                part = parseBodyPart(childContent, sectionPath: childPath)
            } else {
                // Beyond parse depth — attempt single-part parse only (no further multipart recursion).
                part = parseSinglePart(childContent, sectionPath: childPath)
            }
            if let p = part { parts.append(p) }

            childIndex += 1
            idx = afterChild
            // Skip whitespace between child parts.
            while idx < content.endIndex && content[idx] == " " {
                idx = content.index(after: idx)
            }
        }

        // The next token after the last child part is the multipart subtype (quoted string).
        let remainder = String(content[idx...]).trimmingCharacters(in: .whitespaces)
        let subtypeParts = tokenizeBodyPart(remainder)
        let subtype = subtypeParts.first.map { decodeIMAPString($0) } ?? "mixed"

        guard !parts.isEmpty else { return nil }
        return .multipart(parts: parts, subtype: subtype.lowercased())
    }

    // MARK: - Single Part Parser

    /// Parses a single (non-multipart) body part.
    ///
    /// RFC 3501 §7.4.2 body-type-basic fields (positional):
    ///   0  media-type       — quoted string e.g. "text"
    ///   1  media-subtype    — quoted string e.g. "plain"
    ///   2  body-parameter   — parenthesised parameter list or NIL
    ///   3  body-id          — quoted string or NIL
    ///   4  body-description — quoted string or NIL
    ///   5  body-encoding    — quoted string e.g. "7bit"
    ///   6  body-size        — number (octets)
    ///   (7+ are type-specific extension fields and ignored here)
    ///
    /// Filename is extracted from the body-parameter list (field 2) by looking
    /// for the "name" key. Extension data may include Content-Disposition with
    /// a "filename" parameter — this parser does not attempt to parse extension data.
    private static func parseSinglePart(_ content: String, sectionPath: String) -> IMAPBodyPart? {
        let tokens = tokenizeBodyPart(content)
        guard tokens.count >= 7 else { return nil }

        let type     = decodeIMAPString(tokens[0]).lowercased()
        let subtype  = decodeIMAPString(tokens[1]).lowercased()
        let encoding = decodeIMAPString(tokens[5]).lowercased()
        let size     = Int(tokens[6]) ?? 0

        // Extract filename and charset from the body-parameter list (token index 2).
        // The parameter list is a sequence of "key" "value" pairs inside parens,
        // e.g. `("charset" "utf-8" "name" "report.pdf")`.
        let filename = extractParamValue(tokens[2], key: "name")
        let charset  = extractParamValue(tokens[2], key: "charset")?.lowercased()

        // Determine effective section path.
        // If this is a top-level flat message (sectionPath is empty), use "1".
        let effectivePath = sectionPath.isEmpty ? "1" : sectionPath

        return .singlePart(
            type: type,
            subtype: subtype,
            encoding: encoding,
            size: size,
            sectionPath: effectivePath,
            filename: filename,
            charset: charset
        )
    }

    // MARK: - Tokenizer

    /// Splits a body part content string into top-level tokens.
    /// Tokens are separated by spaces at depth 0 (not inside parens or quotes).
    /// Parenthesised groups and quoted strings are returned as single tokens.
    private static func tokenizeBodyPart(_ content: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var inQuote = false
        var escaped = false

        for ch in content {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuote {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" && depth == 0 {
                inQuote.toggle()
                current.append(ch)
                continue
            }
            if !inQuote {
                if ch == "(" { depth += 1; current.append(ch); continue }
                if ch == ")" { depth -= 1; current.append(ch); continue }
                if ch == " " && depth == 0 {
                    if !current.isEmpty { tokens.append(current); current = "" }
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Parameter Extraction

    /// Extracts the value of a named key from an IMAP body-parameter list token.
    ///
    /// The parameter list is a parenthesised sequence of "key" "value" pairs:
    ///   `("charset" "utf-8" "name" "report.pdf")`
    ///
    /// - Parameters:
    ///   - paramToken: The raw parameter list token (e.g. `("charset" "utf-8")` or `NIL`).
    ///   - key: The key to search for, case-insensitive (e.g. `"name"`, `"charset"`).
    /// - Returns: The decoded value string, or `nil` if the key is absent or the token is NIL.
    private static func extractParamValue(_ paramToken: String, key: String) -> String? {
        let trimmed = paramToken.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased() != "NIL", trimmed.hasPrefix("(") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        let paramTokens = tokenizeBodyPart(inner)
        var i = 0
        while i + 1 < paramTokens.count {
            let k = decodeIMAPString(paramTokens[i]).lowercased()
            let v = decodeIMAPString(paramTokens[i + 1])
            if k == key && !v.isEmpty { return v }
            i += 2
        }
        return nil
    }

    // MARK: - Parenthesis Extraction Helper

    /// Starting at `start` (which must point to `(`), finds the matching `)` and
    /// returns the content inside the parens and the index immediately after `)`.
    private static func extractNextParenthesised(
        _ text: String,
        from start: String.Index
    ) -> (content: String, after: String.Index)? {
        guard start < text.endIndex, text[start] == "(" else { return nil }
        var depth = 0
        var inQuote = false
        var escaped = false
        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]
            if escaped { escaped = false; idx = text.index(after: idx); continue }
            if ch == "\\" && inQuote { escaped = true; idx = text.index(after: idx); continue }
            if ch == "\"" { inQuote.toggle(); idx = text.index(after: idx); continue }
            if !inQuote {
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 {
                        let contentRange = text.index(after: start)..<idx
                        let content = String(text[contentRange])
                        let after = text.index(after: idx)
                        return (content: content, after: after)
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
}

// MARK: - LIST Response Parser

nonisolated extension IMAPResponseParser {

    /// Parses a single untagged `* LIST` response line into an `IMAPFolder`.
    ///
    /// RFC 3501 §6.3.8 LIST response format:
    ///   `* LIST (<flags>) "<delimiter>" <mailbox-name>`
    ///
    /// Examples:
    ///   `* LIST (\HasNoChildren) "/" "INBOX"`               → IMAPFolder(name:"INBOX", delimiter:"/", flags:["\\HasNoChildren"])
    ///   `* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"` → IMAPFolder(name:"[Gmail]/Sent Mail", ...)
    ///   `* LIST (\Noselect) "/" "[Gmail]"`                  → IMAPFolder(name:"[Gmail]", flags:["\\Noselect"])
    ///
    /// Returns `nil` for lines that are not `* LIST` responses or cannot be parsed.
    static func parseListResponse(_ line: String) -> IMAPFolder? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Must start with "* LIST"
        guard trimmed.uppercased().hasPrefix("* LIST") else { return nil }

        // Remove the "* LIST " prefix.
        let afterPrefix = trimmed.dropFirst("* LIST ".count)

        // Extract flags from the first parenthesised group.
        guard let flagsContent = extractParenthesised(key: "", from: "k " + afterPrefix) else {
            return nil
        }
        let flags: [String] = flagsContent.isEmpty
            ? []
            : flagsContent.split(separator: " ").map { String($0) }

        // After flags, find the delimiter and name.
        // The flags group ends at ')'; what follows is: ' "<delimiter>" <name>'
        guard let closeParen = afterPrefix.firstIndex(of: ")") else { return nil }
        let afterFlags = String(afterPrefix[afterPrefix.index(after: closeParen)...])
            .trimmingCharacters(in: .whitespaces)

        // afterFlags is now: `"/" "INBOX"` or `"/" [Gmail]/Sent Mail` or `NIL INBOX`
        let tokens = tokenizeListTokens(afterFlags)
        guard tokens.count >= 2 else { return nil }

        let delimiter = decodeIMAPString(tokens[0])
        let name: String
        // Mailbox name may be quoted ("INBOX") or unquoted ([Gmail]/Sent Mail).
        // Some servers omit quotes for non-special names.
        let rawName = tokens[1...].joined(separator: " ")
        name = decodeIMAPString(rawName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        return IMAPFolder(name: name, delimiter: delimiter, flags: flags)
    }

    /// Splits the post-flags remainder of a LIST response into tokens.
    /// Handles quoted strings and unquoted tokens separated by spaces.
    /// Unlike tokenizeBodyPart, does not treat parentheses specially.
    private static func tokenizeListTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false

        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuote {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" {
                inQuote.toggle()
                current.append(ch)
                continue
            }
            if !inQuote && ch == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
