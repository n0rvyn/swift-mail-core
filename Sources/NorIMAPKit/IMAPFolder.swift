// IMAPFolder.swift
// mAil — Value type representing a single IMAP mailbox from LIST response.
//
// RFC 3501 §6.3.8 LIST command returns one untagged response per mailbox:
//   * LIST (\HasNoChildren) "/" "INBOX"
//   * LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail"
//
// `flags` stores the raw backslash-prefixed flag strings (e.g. "\\Sent", "\\Noselect").
// `delimiter` is the hierarchy separator character (typically "/" or ".").
// `name` is the full mailbox name including any namespace prefix.

import Foundation

/// A single IMAP mailbox returned by the LIST command.
nonisolated struct IMAPFolder: Identifiable, Sendable {
    /// Stable identifier — the full mailbox name.
    var id: String { name }
    /// Full mailbox name, e.g. "INBOX", "[Gmail]/Sent Mail", "Sent Items".
    let name: String
    /// Hierarchy delimiter, e.g. "/".
    let delimiter: String
    /// RFC 3501 mailbox attribute flags, e.g. ["\\HasNoChildren", "\\Sent"].
    let flags: [String]
}
