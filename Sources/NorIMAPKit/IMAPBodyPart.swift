// IMAPBodyPart.swift
// mAil — RFC 3501 §7.4.2 BODYSTRUCTURE value type
//
// IMAPBodyPart is a recursive enum that models a MIME message structure.
// It is produced by IMAPResponseParser.parseBodyStructure(_:) and consumed
// by EmailDetailViewModel to identify text parts and attachment parts.
//
// Parsing depth: only depth 1 and depth 2 multipart trees are parsed.
// Depth 3+ nested multipart parts are silently omitted (see feature spec).
//
// Privacy: IMAPBodyPart contains no body data — only metadata (type, size,
// section path). No SwiftData annotation. Ephemeral: lives only in
// EmailDetailViewModel memory during the view's lifetime.

import Foundation

// MARK: - IMAPBodyPart

/// A value type representing one node in an RFC 3501 BODYSTRUCTURE tree.
///
/// `.singlePart` represents a non-multipart body part (text/plain, application/pdf, image/jpeg, etc.).
/// `.multipart` represents a multipart/* container whose children are body parts.
///
/// Section paths follow RFC 3501 §6.4.5:
///   - Flat single-part message: implied path is "1" (the server accepts "BODY[1]" and "BODY[]" equivalently for single-part messages)
///   - First part of multipart: "1", second: "2", nested: "2.1", etc.
public indirect enum IMAPBodyPart: Sendable {

    /// A non-multipart body part.
    ///
    /// - Parameters:
    ///   - type: Primary MIME type, lowercased (e.g. "text", "application", "image").
    ///   - subtype: MIME subtype, lowercased (e.g. "plain", "pdf", "jpeg").
    ///   - encoding: Content-Transfer-Encoding, lowercased (e.g. "base64", "quoted-printable", "7bit").
    ///   - size: Octet count of the encoded part as reported by the server (before decoding).
    ///   - sectionPath: IMAP section path string used in BODY[<sectionPath>] fetch commands.
    ///   - filename: Suggested filename from Content-Disposition or Content-Type name parameter, if present.
    case singlePart(
        type: String,
        subtype: String,
        encoding: String,
        size: Int,
        sectionPath: String,
        filename: String?,
        charset: String?
    )

    /// A multipart/* container.
    ///
    /// - Parameters:
    ///   - parts: Child body parts (may themselves be `.multipart` up to depth 2).
    ///   - subtype: Multipart subtype, lowercased (e.g. "mixed", "alternative", "related").
    case multipart(parts: [IMAPBodyPart], subtype: String)
}

// MARK: - Convenience Accessors

extension IMAPBodyPart {

    /// Returns all `.singlePart` leaves in document order (depth-first).
    public var allSingleParts: [IMAPBodyPart] {
        switch self {
        case .singlePart:
            return [self]
        case .multipart(let parts, _):
            return parts.flatMap { $0.allSingleParts }
        }
    }

    /// Returns true if this part is a text/plain single part.
    public var isTextPlain: Bool {
        if case .singlePart(let type, let subtype, _, _, _, _, _) = self {
            return type == "text" && subtype == "plain"
        }
        return false
    }

    /// Returns true if this part is an attachment (non-text, non-multipart).
    public var isAttachment: Bool {
        if case .singlePart(let type, _, _, _, _, _, _) = self {
            return type != "text" && type != "multipart"
        }
        return false
    }
}
