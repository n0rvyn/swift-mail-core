// SMTPConnection.swift
// NorIMAPKit — Raw NWConnection wrapper for SMTP (RFC 5321)
//
// Responsibilities:
//   - Establish TLS connection (port 465) via Network.framework
//   - Buffer incoming bytes and split on CRLF boundaries
//   - Send raw command strings with CRLF terminator
//
// Swift 6: actor isolation serialises all NWConnection callbacks.

import Foundation
import Network

// MARK: - SMTPConnectionError

public nonisolated enum SMTPConnectionError: Error, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case sendFailed(String)
    case readFailed(String)
    case authenticationFailed
    case commandRejected(code: Int, message: String)
}

// MARK: - SMTPConnection

public actor SMTPConnection {

    private let connection: NWConnection
    private var buffer: Data = Data()
    private var pendingLines: [CheckedContinuation<String, Error>] = []

    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        // Port 465 = implicit TLS (SMTPS). Port 587 = STARTTLS (not implemented here).
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        self.connection = NWConnection(to: endpoint, using: params)
    }

    // MARK: - Connect

    public func connect() async throws -> String {
        // Phase 1: wait for NWConnection to reach .ready state.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: SMTPConnectionError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: SMTPConnectionError.connectionClosed)
                case .waiting(let error):
                    self.connection.stateUpdateHandler = nil
                    continuation.resume(throwing: SMTPConnectionError.connectionFailed("Network unavailable: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        // Phase 2: sequentially start receiving and read the 220 greeting.
        // Must be sequential — readLine() depends on startReceiving() having
        // set up the receive loop (matches IMAPConnection.connect() pattern).
        startReceiving()
        return try await readLine()
    }

    // MARK: - Send / Receive

    /// Sends a single SMTP command line (appends CRLF automatically).
    public func send(_ command: String) async throws {
        let data = (command + "\r\n").data(using: .utf8)!
        try await sendRaw(data)
    }

    /// Sends raw data without appending CRLF. Used by SMTPClient.sendData()
    /// for the RFC 5322 message payload which includes its own terminators.
    public func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SMTPConnectionError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func readLine() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            pendingLines.append(continuation)
            drainBuffer()
        }
    }

    // MARK: - Disconnect

    public func disconnect() {
        connection.cancel()
    }

    // MARK: - Private: Receive Loop

    private func startReceiving() {
        // Must NOT use [weak self]: if the actor is deallocated while
        // continuations are pending, they would be permanently suspended.
        // The actor must stay alive until the connection is explicitly
        // disconnected via disconnect().
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            Task {
                await self.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            buffer.append(data)
            drainBuffer()
        }
        if let error {
            let connError = SMTPConnectionError.readFailed(error.localizedDescription)
            for c in pendingLines { c.resume(throwing: connError) }
            pendingLines.removeAll()
            return
        }
        if isComplete {
            let connError = SMTPConnectionError.connectionClosed
            for c in pendingLines { c.resume(throwing: connError) }
            pendingLines.removeAll()
            return
        }
        // Continue receiving.
        startReceiving()
    }

    private func drainBuffer() {
        while !pendingLines.isEmpty {
            guard let range = buffer.range(of: Data("\r\n".utf8)) else { break }
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let line = String(data: lineData, encoding: .utf8) ?? ""
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            let continuation = pendingLines.removeFirst()
            continuation.resume(returning: line)
        }
    }
}
