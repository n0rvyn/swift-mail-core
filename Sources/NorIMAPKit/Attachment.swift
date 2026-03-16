// Attachment.swift
// NorIMAPKit — Attachment for SMTP multipart messages

import Foundation

/// An attachment for inclusion in an outgoing SMTP message.
public struct Attachment: Sendable {
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
