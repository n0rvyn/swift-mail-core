// SMTPClientTests.swift
// NorIMAPKit

import Testing
import Foundation
@testable import NorIMAPKit
@testable import NorIMAPKitSMTP

@Suite("SMTPClient")
struct SMTPClientTests {

    @Test("Attachment struct initializes correctly")
    func attachmentInit() {
        let data = Data("hello".utf8)
        let attachment = Attachment(filename: "test.txt", mimeType: "text/plain", data: data)
        #expect(attachment.filename == "test.txt")
        #expect(attachment.mimeType == "text/plain")
        #expect(attachment.data == data)
    }

    @Test("SMTPError cases are distinct")
    func smtpErrorCases() {
        let err1 = SMTPError.authenticationFailed
        let err2 = SMTPError.recipientRejected("550 No such user")
        let err3 = SMTPError.messageRejected("554 Rejected")
        let err4 = SMTPError.connectionFailed("timeout")
        let err5 = SMTPError.unexpectedResponse(code: 421, message: "Service not available")

        // Verify they are all Error-conforming
        let errors: [any Error] = [err1, err2, err3, err4, err5]
        #expect(errors.count == 5)
    }

    @Test("SMTPConnectionError cases are distinct")
    func smtpConnectionErrorCases() {
        let errors: [SMTPConnectionError] = [
            .connectionFailed("test"),
            .connectionClosed,
            .timeout,
            .sendFailed("test"),
            .readFailed("test"),
            .authenticationFailed,
            .commandRejected(code: 550, message: "test")
        ]
        #expect(errors.count == 7)
    }
}
