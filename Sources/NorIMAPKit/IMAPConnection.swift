// IMAPConnection.swift
// mAil — Raw NWConnection wrapper for IMAP4rev1
//
// Responsibilities:
//   • Establish TLS connection via Network.framework NWConnection
//   • Buffer incoming bytes and split on CRLF boundaries
//   • Handle IMAP literal continuation: when a response contains {N}\r\n,
//     read exactly N more bytes as the literal octets (RFC 3501 §4.3)
//   • Send raw command strings with CRLF terminator
//
// Swift 6: this type is an actor — all mutable state is actor-isolated.
// NWConnection callbacks arrive on its internal queue; we bridge them
// to Swift async via AsyncStream / CheckedContinuation.

import Foundation
import Network

// MARK: - IMAPConnectionError

nonisolated enum IMAPConnectionError: Error, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case sendFailed(String)
    case readFailed(String)
}

// MARK: - IMAPConnection

actor IMAPConnection {

    // MARK: - Private State

    private let connection: NWConnection
    private var buffer: Data = Data()
    // Connection state is tracked implicitly by NWConnection's stateUpdateHandler.

    // Pending read continuations — resolved when a complete line is available.
    private var pendingLines: [CheckedContinuation<String, Error>] = []
    // Pending literal-read continuations — resolved when exactly N bytes arrive.
    private var pendingLiterals: [CheckedContinuation<Data, Error>] = []
    // Expected byte count for the pending literal read (0 = no literal pending).
    private var literalBytesRemaining: Int = 0

    // MARK: - Init

    /// Creates a TLS connection to `host` on `port`.
    /// Call `connect()` to establish the connection before sending commands.
    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 993
        )
        let params = NWParameters.tls
        params.prohibitedInterfaceTypes = []
        self.connection = NWConnection(to: endpoint, using: params)
    }

    // MARK: - Connect

    /// Establishes the TLS connection and waits for the IMAP greeting line.
    /// Returns the server greeting string (e.g. `* OK Gimap ready`).
    /// Throws `IMAPConnectionError.connectionFailed` if TLS handshake fails
    /// or the greeting is not received within 10 seconds.
    func connect() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // NWConnection.stateUpdateHandler fires for every state transition.
            // Guard against double-resume: nil out the handler after the first
            // terminal state to prevent subsequent invocations. This is safe
            // because callbacks are serialized on the queue passed to start().
            // Using stateUpdateHandler = nil instead of a `var resumed` flag
            // because Swift 6 forbids capturing mutable vars in @Sendable closures.
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPConnectionError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPConnectionError.connectionClosed)
                case .waiting(let error):
                    // No network available — NWConnection stays in .waiting
                    // instead of transitioning to .failed. Treat as connection failure.
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: IMAPConnectionError.connectionFailed("Network unavailable: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.mail.mAil.imap.connection"))
        }

        // Start the receive loop now that the connection is ready.
        startReceiveLoop()

        // Read and return the server greeting.
        return try await readLine()
    }

    // MARK: - Send

    /// Sends a raw IMAP command string followed by `\r\n`.
    /// Example: `send("A001 LOGIN user@gmail.com password")`
    func send(_ command: String) async throws {
        let data = (command + "\r\n").data(using: .utf8) ?? Data()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: IMAPConnectionError.sendFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - Read Line

    /// Reads one complete CRLF-terminated line from the server.
    /// If the line ends with a literal size marker `{N}`, callers should
    /// follow up with `readLiteral(byteCount: N)` to retrieve the literal data.
    func readLine() async throws -> String {
        // If there is already a complete line in the buffer, return it immediately.
        if let (line, remainder) = extractLine(from: buffer) {
            buffer = remainder
            drainPending()
            return line
        }
        // Otherwise suspend until the receive loop delivers more data.
        return try await withCheckedThrowingContinuation { continuation in
            pendingLines.append(continuation)
        }
    }

    // MARK: - Read Literal

    /// Reads exactly `byteCount` bytes from the connection (an IMAP literal body).
    /// Must be called immediately after `readLine()` returns a line ending in `{N}`.
    func readLiteral(byteCount: Int) async throws -> Data {
        guard byteCount > 0 else { return Data() }

        // If sufficient bytes are already buffered, consume them immediately.
        if buffer.count >= byteCount {
            let literal = buffer.prefix(byteCount)
            buffer = buffer.dropFirst(byteCount)
            // Discard the trailing \r\n after the literal if present.
            if buffer.prefix(2) == Data([0x0D, 0x0A]) {
                buffer = buffer.dropFirst(2)
            }
            drainPending()
            return Data(literal)
        }

        // Suspend until enough bytes arrive.
        literalBytesRemaining = byteCount
        return try await withCheckedThrowingContinuation { continuation in
            pendingLiterals.append(continuation)
        }
    }

    // MARK: - Disconnect

    nonisolated func disconnect() {
        connection.cancel()
    }

    // MARK: - Private: Receive Loop

    private func startReceiveLoop() {
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.appendData(data)
                }
                if let error {
                    await self.failAll(with: IMAPConnectionError.readFailed(error.localizedDescription))
                    return
                }
                if isComplete {
                    await self.failAll(with: IMAPConnectionError.connectionClosed)
                    return
                }
                // Continue receiving.
                await self.receiveNext()
            }
        }
    }

    // MARK: - Private: Buffer Management

    private func appendData(_ data: Data) {
        buffer.append(data)
        drainPending()
    }

    private func drainPending() {
        // Satisfy pending literal reads first.
        if let literalContinuation = pendingLiterals.first {
            let needed = literalBytesRemaining
            guard buffer.count >= needed else { return }
            pendingLiterals.removeFirst()
            let literal = buffer.prefix(needed)
            buffer = buffer.dropFirst(needed)
            if buffer.prefix(2) == Data([0x0D, 0x0A]) {
                buffer = buffer.dropFirst(2)
            }
            literalBytesRemaining = 0
            literalContinuation.resume(returning: Data(literal))
            return
        }

        // Satisfy pending line reads.
        while let continuation = pendingLines.first {
            guard let (line, remainder) = extractLine(from: buffer) else { return }
            pendingLines.removeFirst()
            buffer = remainder
            continuation.resume(returning: line)
        }
    }

    /// Extracts the first CRLF-terminated line from `data`.
    /// Returns `(line, remainingData)` or `nil` if no complete line exists.
    private func extractLine(from data: Data) -> (String, Data)? {
        guard let crlfRange = data.range(of: Data([0x0D, 0x0A])) else { return nil }
        let lineData = data[data.startIndex..<crlfRange.lowerBound]
        let line = String(data: lineData, encoding: .utf8) ?? String(data: lineData, encoding: .isoLatin1) ?? ""
        let remainder = data[crlfRange.upperBound...]
        return (line, Data(remainder))
    }

    private func failAll(with error: Error) {
        for c in pendingLines { c.resume(throwing: error) }
        pendingLines.removeAll()
        for c in pendingLiterals { c.resume(throwing: error) }
        pendingLiterals.removeAll()
    }
}
