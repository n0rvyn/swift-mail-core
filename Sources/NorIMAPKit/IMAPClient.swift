// IMAPClient.swift
// mAil — IMAP4rev1 command actor
//
// Wraps IMAPConnection with:
//   • Auto-incrementing command tag (A001, A002, ...)
//   • Typed async methods for each needed IMAP command
//   • Reads untagged `*` responses until the matching tagged response arrives
//
// Gmail-specific configuration:
//   • Host: imap.gmail.com, Port: 993, TLS (direct — no STARTTLS)
//   • LOGIN command (not AUTHENTICATE) — requires App Password
//   • INBOX folder, [Gmail]/All Mail for archive
//
// Swift 6: `actor` isolation ensures all IMAPConnection calls are serialised —
// no concurrent IMAP commands can interleave their responses.

import Foundation

// MARK: - IMAPError

nonisolated enum IMAPError: Error, Sendable {
    case authenticationFailed
    case commandFailed(tag: String, text: String)
    case unexpectedResponse(String)
    case sessionConfigurationMissing
    case notConnected
}

// MARK: - IMAPClient

actor IMAPClient {

    // MARK: - Constants (Gmail)

    static let gmailHost = "imap.gmail.com"
    static let gmailPort: UInt16 = 993
    static let inboxFolder = "INBOX"
    static let archiveFolder = "[Gmail]/All Mail"

    // MARK: - Private State

    private var connection: IMAPConnection?
    private var tagCounter: UInt32 = 0

    // MARK: - Tag Generation

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "A%03d", tagCounter)
    }

    // MARK: - Connect & Greeting

    /// Connects to the IMAP server and reads the greeting.
    /// Must be called before any other method.
    func connect(host: String, port: UInt16) async throws {
        let conn = IMAPConnection(host: host, port: port)
        let greeting = try await conn.connect()
        // Greeting must start with "* OK" (ready) or "* PREAUTH".
        // "* BYE" means the server rejected the connection.
        if greeting.uppercased().hasPrefix("* BYE") {
            throw IMAPConnectionError.connectionFailed("Server rejected connection: \(greeting)")
        }
        self.connection = conn
    }

    // MARK: - LOGIN

    /// Authenticates using the IMAP LOGIN command.
    /// Throws `IMAPError.authenticationFailed` on `NO` response.
    func login(email: String, password: String) async throws {
        let conn = try requireConnection()
        let tag = nextTag()
        // Escape special characters in password using IMAP quoted-string rules.
        let safePassword = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try await conn.send("\(tag) LOGIN \(email) \"\(safePassword)\"")
        let result = try await readTagged(tag: tag, connection: conn)
        if result.status != .ok {
            throw IMAPError.authenticationFailed
        }
    }

    // MARK: - SELECT

    /// Opens a mailbox for read-write access.
    ///
    /// Returns the UIDVALIDITY value from the server's SELECT response.
    /// UIDVALIDITY changes when the server has reassigned UIDs (e.g. mailbox rebuild),
    /// meaning all previously cached UIDs for this mailbox are invalid.
    @discardableResult
    func select(folder: String) async throws -> UInt32 {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) SELECT \"\(folder)\"")

        var uidValidity: UInt32 = 0
        while true {
            let line = try await conn.readLine()
            // Parse UIDVALIDITY from untagged OK response:
            //   * OK [UIDVALIDITY 1234] UIDs valid
            if line.uppercased().contains("[UIDVALIDITY") {
                let pattern = #"\[UIDVALIDITY (\d+)\]"#
                if let range = line.range(of: pattern, options: .regularExpression) {
                    let match = String(line[range])
                    let digits = match.filter { $0.isNumber }
                    uidValidity = UInt32(digits) ?? 0
                }
            }
            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                if result.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: result.text)
                }
                break
            }
        }
        return uidValidity
    }

    // MARK: - LIST

    /// Sends `LIST "" "*"` and returns all mailboxes the server reports.
    ///
    /// RFC 3501 §6.3.8: The reference name "" and mailbox name "*" pattern
    /// returns all mailboxes available to the authenticated user.
    ///
    /// Mailboxes with the `\Noselect` attribute cannot be SELECTed but are
    /// still returned here so callers can build a complete folder tree.
    ///
    /// Returns an empty array if the server responds with no untagged LIST lines.
    func listFolders() async throws -> [IMAPFolder] {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) LIST \"\" \"*\"")

        var folders: [IMAPFolder] = []
        while true {
            let line = try await conn.readLine()
            if line.uppercased().hasPrefix("* LIST") {
                if let folder = IMAPResponseParser.parseListResponse(line) {
                    folders.append(folder)
                }
            }
            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                if result.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: result.text)
                }
                break
            }
        }
        return folders
    }

    // MARK: - UID SEARCH

    /// Searches for UIDs matching `criteria`. Returns a sorted array of UIDs.
    ///
    /// Common criteria:
    ///   `"ALL"` — all messages in the selected folder
    ///   `"UID \(minUID):*"` — UIDs >= minUID (incremental sync)
    ///   `"SINCE 24-Feb-2026"` — since a date
    func uidSearch(criteria: String) async throws -> [UInt32] {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) UID SEARCH \(criteria)")

        var uids: [UInt32] = []
        while true {
            let line = try await conn.readLine()
            if line.uppercased().hasPrefix("* SEARCH") {
                uids = IMAPResponseParser.parseSearchUIDs(line)
            }
            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                if result.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: result.text)
                }
                break
            }
        }
        return uids.sorted()
    }

    // MARK: - UID FETCH (envelope + flags)

    /// Fetches envelope (subject, from, date) and flags for the given UIDs.
    /// Does NOT fetch body. Returns one `IMAPFetchedMessage` per UID.
    ///
    /// UIDs are batched into a comma-separated set string, e.g. `"101,102,103"`.
    /// For large batches, callers should chunk into groups of 50 to avoid
    /// exceeding server line-length limits.
    func uidFetchEnvelope(uids: [UInt32]) async throws -> [IMAPFetchedMessage] {
        guard !uids.isEmpty else { return [] }
        let conn = try requireConnection()
        let tag = nextTag()
        let uidSet = uids.map { String($0) }.joined(separator: ",")
        try await conn.send("\(tag) UID FETCH \(uidSet) (UID FLAGS INTERNALDATE ENVELOPE)")

        var messages: [IMAPFetchedMessage] = []
        var fetchLines: [String] = []
        var inFetch = false

        while true {
            let line = try await conn.readLine()

            // Check for literal marker {N} at end of line.
            if let literalSize = extractLiteralSize(line) {
                let literalData = try await conn.readLiteral(byteCount: literalSize)
                let literalString = String(data: literalData, encoding: .utf8) ?? ""
                fetchLines.append(line + literalString)
                continue
            }

            // Detect start of FETCH response.
            if line.hasPrefix("* ") && line.uppercased().contains("FETCH") {
                if inFetch, let message = IMAPResponseParser.parseFetchEnvelope(lines: fetchLines) {
                    messages.append(message)
                }
                fetchLines = [line]
                inFetch = true
                continue
            }

            if inFetch {
                fetchLines.append(line)
            }

            // Tagged response ends the command.
            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                if inFetch, let message = IMAPResponseParser.parseFetchEnvelope(lines: fetchLines) {
                    messages.append(message)
                }
                if result.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: result.text)
                }
                break
            }
        }
        return messages
    }

    // MARK: - UID FETCH (body text, on demand)

    /// Fetches the raw RFC 2822 body for a single message as a UTF-8 string.
    /// Callers MUST NOT persist this string to disk or SwiftData.
    func uidFetchBody(uid: UInt32) async throws -> String {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) UID FETCH \(uid) (BODY.PEEK[])")

        var bodyLines: [String] = []
        var bodyStarted = false

        while true {
            let line = try await conn.readLine()

            if let literalSize = extractLiteralSize(line) {
                let data = try await conn.readLiteral(byteCount: literalSize)
                let bodyText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                // Must consume remaining lines (closing paren + tagged response)
                // to avoid leaving stale data in IMAPConnection's buffer.
                while true {
                    let remaining = try await conn.readLine()
                    if let result = IMAPResponseParser.parseTagged(remaining), result.tag == tag {
                        if result.status != .ok {
                            throw IMAPError.commandFailed(tag: tag, text: result.text)
                        }
                        break
                    }
                }
                return bodyText
            }

            if line.uppercased().contains("BODY[]") {
                bodyStarted = true
                continue
            }

            if bodyStarted {
                bodyLines.append(line)
            }

            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                if result.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: result.text)
                }
                break
            }
        }
        return bodyLines.joined(separator: "\n")
    }

    // MARK: - UID FETCH (BODYSTRUCTURE)

    /// Fetches the BODYSTRUCTURE for a single message.
    /// Returns an `IMAPBodyPart` tree representing the MIME structure.
    /// Returns `nil` if the server response cannot be parsed (malformed or missing).
    ///
    /// Callers MUST NOT persist the result to SwiftData.
    /// The BODYSTRUCTURE contains only metadata (type, size, encoding), not body data.
    func uidFetchBodyStructure(uid: UInt32) async throws -> IMAPBodyPart? {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) UID FETCH \(uid) (BODYSTRUCTURE)")

        var result: IMAPBodyPart? = nil

        while true {
            let line = try await conn.readLine()

            // The BODYSTRUCTURE response is inline (no literal — it's a parenthesised list).
            if line.uppercased().contains("BODYSTRUCTURE") {
                result = IMAPResponseParser.parseBodyStructure(line)
            }

            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                if tagged.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: tagged.text)
                }
                break
            }
        }
        return result
    }

    // MARK: - UID FETCH (BODY[section])

    /// Fetches the raw (encoded) bytes for a specific MIME section of a message.
    ///
    /// `section` is the IMAP section path string, e.g. "1", "2", "2.1".
    /// The returned `Data` is the encoded bytes as-is from the server.
    /// Content-Transfer-Encoding decoding (base64, quoted-printable) is performed
    /// by the caller using `MIMEDecoder` — this method does NOT decode.
    ///
    /// Callers MUST NOT persist the returned `Data` to SwiftData.
    func uidFetchBodySection(uid: UInt32, section: String) async throws -> Data {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) UID FETCH \(uid) (BODY.PEEK[\(section)])")

        while true {
            let line = try await conn.readLine()

            if let literalSize = extractLiteralSize(line) {
                let data = try await conn.readLiteral(byteCount: literalSize)
                // Consume the remaining response lines until the tagged result.
                while true {
                    let remaining = try await conn.readLine()
                    if let tagged = IMAPResponseParser.parseTagged(remaining), tagged.tag == tag {
                        if tagged.status != .ok {
                            throw IMAPError.commandFailed(tag: tag, text: tagged.text)
                        }
                        break
                    }
                }
                return data
            }

            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                if tagged.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: tagged.text)
                }
                // Tagged OK with no literal means the section was empty or not found.
                return Data()
            }
        }
    }

    // MARK: - UID FETCH (header fields)

    /// Checks which UIDs contain specific header fields.
    ///
    /// Fetches `BODY.PEEK[HEADER.FIELDS (field1 field2)]` for the given UIDs
    /// and returns the set of UIDs where at least one of the requested fields is present.
    ///
    /// Used for List-Unsubscribe detection during sync — avoids fetching full bodies.
    func uidFetchHasHeader(uids: [UInt32], field: String) async throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        let conn = try requireConnection()
        let tag = nextTag()
        let uidSet = uids.map { String($0) }.joined(separator: ",")
        try await conn.send("\(tag) UID FETCH \(uidSet) (UID BODY.PEEK[HEADER.FIELDS (\(field))])")

        var result = Set<UInt32>()
        var currentUID: UInt32?

        while true {
            let line = try await conn.readLine()

            // Extract UID from FETCH response line.
            if line.uppercased().contains("FETCH") && line.uppercased().contains("UID") {
                let uidPattern = #"UID (\d+)"#
                if let range = line.range(of: uidPattern, options: .regularExpression) {
                    let match = String(line[range])
                    currentUID = match.split(separator: " ").last.flatMap { UInt32($0) }
                }
            }

            // Handle literal — contains the header field value (or empty if absent).
            if let literalSize = extractLiteralSize(line) {
                let data = try await conn.readLiteral(byteCount: literalSize)
                if let uid = currentUID, !data.isEmpty {
                    // Non-empty literal means the header field is present.
                    // Check it's not just blank lines (empty header section = "\r\n").
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        result.insert(uid)
                    }
                }
                currentUID = nil
                continue
            }

            if let tagged = IMAPResponseParser.parseTagged(line), tagged.tag == tag {
                if tagged.status != .ok {
                    throw IMAPError.commandFailed(tag: tag, text: tagged.text)
                }
                break
            }
        }
        return result
    }

    // MARK: - UID STORE (flag update)

    /// Adds or removes IMAP flags for the given UID.
    ///
    /// - Parameters:
    ///   - uid: The message UID.
    ///   - addFlags: Flags to add, e.g. `["\\Seen"]`.
    ///   - removeFlags: Flags to remove.
    func uidStore(uid: UInt32, addFlags: [String] = [], removeFlags: [String] = []) async throws {
        let conn = try requireConnection()
        if !addFlags.isEmpty {
            let tag = nextTag()
            let flagList = addFlags.joined(separator: " ")
            try await conn.send("\(tag) UID STORE \(uid) +FLAGS (\(flagList))")
            _ = try await readTagged(tag: tag, connection: conn)
        }
        if !removeFlags.isEmpty {
            let tag = nextTag()
            let flagList = removeFlags.joined(separator: " ")
            try await conn.send("\(tag) UID STORE \(uid) -FLAGS (\(flagList))")
            _ = try await readTagged(tag: tag, connection: conn)
        }
    }

    // MARK: - UID COPY (archive)

    /// Copies a message to `destinationFolder` (used for archive).
    func uidCopy(uid: UInt32, to destinationFolder: String) async throws {
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) UID COPY \(uid) \"\(destinationFolder)\"")
        let result = try await readTagged(tag: tag, connection: conn)
        if result.status != .ok {
            throw IMAPError.commandFailed(tag: tag, text: result.text)
        }
    }

    // MARK: - UID STORE + EXPUNGE (delete)

    /// Marks the message `\Deleted` and issues EXPUNGE to remove it permanently.
    func uidDelete(uid: UInt32) async throws {
        try await uidStore(uid: uid, addFlags: ["\\Deleted"])
        let conn = try requireConnection()
        let tag = nextTag()
        try await conn.send("\(tag) EXPUNGE")
        _ = try await readTagged(tag: tag, connection: conn)
    }

    // MARK: - LOGOUT

    /// Sends LOGOUT and closes the connection.
    func logout() async throws {
        guard let conn = connection else { return }
        let tag = nextTag()
        try? await conn.send("\(tag) LOGOUT")
        _ = try? await readTagged(tag: tag, connection: conn)
        conn.disconnect()
        connection = nil
    }

    // MARK: - Private Helpers

    private func requireConnection() throws -> IMAPConnection {
        guard let conn = connection else { throw IMAPError.notConnected }
        return conn
    }

    /// Reads and discards untagged `*` lines until the line matching `tag` arrives.
    @discardableResult
    private func readTagged(tag: String, connection: IMAPConnection) async throws -> IMAPTaggedResult {
        while true {
            let line = try await connection.readLine()
            if let result = IMAPResponseParser.parseTagged(line), result.tag == tag {
                return result
            }
            // Untagged lines (capabilities, EXISTS, etc.) are discarded here.
            // IMAPClient callers that need untagged data (e.g. uidSearch) handle
            // the read loop themselves.
        }
    }

    /// Extracts the literal byte count from a line ending in `{N}`.
    /// Example: `"* 3 FETCH (BODY[] {1234}"` → `1234`
    private func extractLiteralSize(_ line: String) -> Int? {
        guard line.hasSuffix("}") else { return nil }
        guard let open = line.lastIndex(of: "{") else { return nil }
        let sizeStr = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(sizeStr)
    }
}
