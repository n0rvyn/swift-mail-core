// SMTPClient.swift
// NorIMAPKit — SMTP command actor (RFC 5321)
//
// Sequence for sending one message:
//   connect -> EHLO -> AUTH LOGIN -> MAIL FROM -> RCPT TO -> DATA -> QUIT
//
// Supports port 465 (implicit TLS / SMTPS) only.
// STARTTLS (port 587) is not implemented in this phase.
//
// Swift 6: actor isolation ensures commands are serialised.

import Foundation
import NorIMAPKit

// MARK: - SMTPError

nonisolated enum SMTPError: Error, Sendable {
    case connectionFailed(String)
    case authenticationFailed
    case recipientRejected(String)
    case messageRejected(String)
    case unexpectedResponse(code: Int, message: String)
}

// MARK: - SMTPClient

actor SMTPClient {

    private var connection: SMTPConnection?

    // MARK: - Connect

    func connect(host: String, port: UInt16 = 465) async throws {
        let conn = SMTPConnection(host: host, port: port)
        let greeting = try await conn.connect()
        guard greeting.hasPrefix("220") else {
            throw SMTPError.connectionFailed("Unexpected greeting: \(greeting)")
        }
        self.connection = conn
    }

    // MARK: - EHLO

    func ehlo(domain: String = "mail.app") async throws {
        let conn = try requireConnection()
        try await conn.send("EHLO \(domain)")
        // EHLO response is multi-line (250-... / 250 ...). Read until 250 SP line.
        var line = try await conn.readLine()
        while line.hasPrefix("250-") {
            line = try await conn.readLine()
        }
        try assertCode(250, in: line)
    }

    // MARK: - AUTH LOGIN

    func authLogin(username: String, password: String) async throws {
        let conn = try requireConnection()
        try await conn.send("AUTH LOGIN")
        let challenge1 = try await conn.readLine()
        try assertCode(334, in: challenge1)

        // Base64-encode username and password.
        let userB64 = Data(username.utf8).base64EncodedString()
        try await conn.send(userB64)
        let challenge2 = try await conn.readLine()
        try assertCode(334, in: challenge2)

        let passB64 = Data(password.utf8).base64EncodedString()
        try await conn.send(passB64)
        let authResult = try await conn.readLine()
        if !authResult.hasPrefix("235") {
            throw SMTPError.authenticationFailed
        }
    }

    // MARK: - MAIL FROM

    func mailFrom(_ address: String) async throws {
        let conn = try requireConnection()
        try await conn.send("MAIL FROM:<\(address)>")
        let response = try await conn.readLine()
        try assertCode(250, in: response)
    }

    // MARK: - RCPT TO

    func rcptTo(_ address: String) async throws {
        let conn = try requireConnection()
        try await conn.send("RCPT TO:<\(address)>")
        let response = try await conn.readLine()
        if !response.hasPrefix("250") && !response.hasPrefix("251") {
            throw SMTPError.recipientRejected(response)
        }
    }

    // MARK: - DATA

    func sendData(from: String, to: String, cc: [String] = [], subject: String, body: String) async throws {
        let conn = try requireConnection()
        try await conn.send("DATA")
        let dataReady = try await conn.readLine()
        try assertCode(354, in: dataReady)

        // Build RFC 5322 message.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        let date = dateFormatter.string(from: Date())

        // Generate Message-ID per RFC 5322 §3.6.4.
        let domain = from.components(separatedBy: "@").last ?? "mail.app"
        let messageId = "<\(UUID().uuidString)@\(domain)>"

        var message = ""
        message += "From: \(from)\r\n"
        message += "To: \(to)\r\n"
        if !cc.isEmpty {
            message += "Cc: \(cc.joined(separator: ", "))\r\n"
        }
        // NO Bcc: header — RFC 5321 §3.6.3: Bcc recipients receive via SMTP envelope only.
        message += "Subject: \(subject)\r\n"
        message += "Date: \(date)\r\n"
        message += "Message-ID: \(messageId)\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "\r\n"
        // Normalize line endings before dot-stuffing: \r\n → \n, then split on \n.
        // Prevents stray \r from pasted text producing \r\r\n in the output.
        let normalizedBody = body.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Dot-stuffing: lines starting with "." must be doubled (RFC 5321 section 4.5.2).
        let stuffedBody = normalizedBody.components(separatedBy: "\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        message += stuffedBody
        message += "\r\n.\r\n"

        // Use sendRaw to avoid conn.send() appending an extra CRLF
        // after the DATA terminator (\r\n.\r\n).
        let rawData = message.data(using: .utf8)!
        try await conn.sendRaw(rawData)
        let result = try await conn.readLine()
        if !result.hasPrefix("250") {
            throw SMTPError.messageRejected(result)
        }
    }

    // MARK: - DATA (multipart/mixed)

    /// Sends a multipart/mixed SMTP DATA payload containing the plain-text body
    /// followed by one attachment part per entry in `attachments`.
    ///
    /// - When `attachments` is empty, callers should use `sendData(from:to:cc:subject:body:)`
    ///   instead; this method always generates a multipart structure even for empty arrays,
    ///   but `EmailService.sendMessage` gates the call on `!attachments.isEmpty`.
    /// - Base64 encoding per RFC 2045 §6.8 (76-char lines, CRLF separated).
    /// - `Content-Disposition: attachment; filename="..."` per RFC 2183.
    /// - Dot-stuffing applied to the entire assembled message per RFC 5321 §4.5.2.
    func sendDataMultipart(
        from: String,
        to: String,
        cc: [String] = [],
        subject: String,
        body: String,
        attachments: [Attachment]
    ) async throws {
        let conn = try requireConnection()
        try await conn.send("DATA")
        let dataReady = try await conn.readLine()
        try assertCode(354, in: dataReady)

        // Date and Message-ID headers (same as sendData).
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        let date = dateFormatter.string(from: Date())

        let domain = from.components(separatedBy: "@").last ?? "mail.app"
        let messageId = "<\(UUID().uuidString)@\(domain)>"

        // Boundary: a UUID string; no whitespace, safe as MIME boundary.
        let boundary = UUID().uuidString

        // --- RFC 5322 headers ---
        var message = ""
        message += "From: \(from)\r\n"
        message += "To: \(to)\r\n"
        if !cc.isEmpty {
            message += "Cc: \(cc.joined(separator: ", "))\r\n"
        }
        message += "Subject: \(subject)\r\n"
        message += "Date: \(date)\r\n"
        message += "Message-ID: \(messageId)\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n"
        message += "\r\n"

        // --- Part 1: plain-text body ---
        message += "--\(boundary)\r\n"
        message += "Content-Type: text/plain; charset=UTF-8\r\n"
        message += "Content-Transfer-Encoding: 7bit\r\n"
        message += "\r\n"
        // Normalize body line endings to \r\n.
        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .joined(separator: "\r\n")
        message += normalizedBody
        message += "\r\n\r\n"

        // --- Attachment parts ---
        for attachment in attachments {
            message += "--\(boundary)\r\n"
            message += "Content-Type: \(attachment.mimeType)\r\n"
            message += "Content-Transfer-Encoding: base64\r\n"
            message += "Content-Disposition: attachment; filename=\"\(attachment.filename)\"\r\n"
            message += "\r\n"
            message += attachment.data.encodedAsBase64MIME()
            message += "\r\n\r\n"
        }

        // --- Final boundary ---
        message += "--\(boundary)--\r\n"

        // Dot-stuffing per RFC 5321 §4.5.2: lines starting with "." are doubled.
        // Apply across the entire assembled message.
        let stuffed = message.components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")

        // DATA terminator.
        let final = stuffed + "\r\n.\r\n"

        let rawData = final.data(using: .utf8)!
        try await conn.sendRaw(rawData)
        let result = try await conn.readLine()
        if !result.hasPrefix("250") {
            throw SMTPError.messageRejected(result)
        }
    }

    // MARK: - QUIT

    func quit() async throws {
        guard let conn = connection else { return }
        try await conn.send("QUIT")
        _ = try? await conn.readLine()   // 221 response; ignore errors on disconnect
        await conn.disconnect()
        self.connection = nil
    }

    // MARK: - Private Helpers

    private func requireConnection() throws -> SMTPConnection {
        guard let conn = connection else {
            throw SMTPError.connectionFailed("Not connected")
        }
        return conn
    }

    private func assertCode(_ expected: Int, in line: String) throws {
        let code = Int(line.prefix(3)) ?? 0
        guard code == expected else {
            throw SMTPError.unexpectedResponse(code: code, message: line)
        }
    }
}
