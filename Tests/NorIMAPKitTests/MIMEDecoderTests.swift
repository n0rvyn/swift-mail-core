// MIMEDecoderTests.swift
// NorIMAPKit

import Testing
import Foundation
@testable import NorIMAPKit

@Suite("MIMEDecoder")
struct MIMEDecoderTests {

    // MARK: - Base64 Decoding

    @Test("Decodes base64 string")
    func decodeBase64() {
        let encoded = "SGVsbG8gV29ybGQ="  // "Hello World"
        let data = Data.decodedFromBase64(string: encoded)
        #expect(data != nil)
        #expect(String(data: data!, encoding: .utf8) == "Hello World")
    }

    @Test("Decodes base64 with line breaks")
    func decodeBase64WithLineBreaks() {
        // "Hello World" split across lines
        let encoded = "SGVs\r\nbG8g\r\nV29y\r\nbGQ="
        let data = Data.decodedFromBase64(string: encoded)
        #expect(data != nil)
        #expect(String(data: data!, encoding: .utf8) == "Hello World")
    }

    @Test("Decodes base64 without padding")
    func decodeBase64NoPadding() {
        let encoded = "SGVsbG8"  // "Hello" without trailing ==
        let data = Data.decodedFromBase64(string: encoded)
        #expect(data != nil)
        #expect(String(data: data!, encoding: .utf8) == "Hello")
    }

    @Test("Empty base64 returns empty Data")
    func decodeBase64Empty() {
        let data = Data.decodedFromBase64(string: "")
        #expect(data == Data())
    }

    // MARK: - Quoted-Printable Decoding

    @Test("Decodes quoted-printable hex escapes")
    func decodeQP() {
        let encoded = "Hello=20World"
        let data = Data.decodedFromQuotedPrintable(string: encoded)
        #expect(String(data: data, encoding: .utf8) == "Hello World")
    }

    @Test("Decodes quoted-printable soft line break")
    func decodeQPSoftBreak() {
        let encoded = "Hello=\nWorld"
        let data = Data.decodedFromQuotedPrintable(string: encoded)
        #expect(String(data: data, encoding: .utf8) == "HelloWorld")
    }

    @Test("Decodes quoted-printable with multiple hex escapes")
    func decodeQPMultipleEscapes() {
        let encoded = "=48=65=6C=6C=6F"  // "Hello"
        let data = Data.decodedFromQuotedPrintable(string: encoded)
        #expect(String(data: data, encoding: .utf8) == "Hello")
    }

    // MARK: - 7bit Decoding

    @Test("7bit returns UTF-8 data")
    func decode7bit() {
        let data = Data.decodedFrom7bit(string: "Hello World")
        #expect(String(data: data, encoding: .utf8) == "Hello World")
    }

    // MARK: - Base64 Encoding (outgoing)

    @Test("Encodes data as base64 MIME with CRLF")
    func encodeBase64MIME() {
        let input = Data(repeating: 0x41, count: 100) // 100 bytes of 'A'
        let encoded = input.encodedAsBase64MIME()
        // Verify CRLF line breaks (not LF)
        #expect(encoded.contains("\r\n"))
        #expect(!encoded.contains("\r\n\r\n")) // No double breaks
        // Verify line length <= 76 + CRLF
        for line in encoded.components(separatedBy: "\r\n") {
            #expect(line.count <= 76)
        }
    }

    // MARK: - RFC 2047 Decoder

    @Test("Decodes RFC 2047 base64 encoded-word")
    func decodeRFC2047Base64() {
        let input = "=?UTF-8?B?5rWL6K+V?="  // "测试"
        let decoded = RFC2047Decoder.decode(input)
        #expect(decoded == "测试")
    }

    @Test("Decodes RFC 2047 Q-encoded word")
    func decodeRFC2047Q() {
        let input = "=?UTF-8?Q?Hello_World?="
        let decoded = RFC2047Decoder.decode(input)
        #expect(decoded == "Hello World")
    }

    @Test("Passes through non-encoded string unchanged")
    func decodeRFC2047Plain() {
        let input = "Just a plain string"
        let decoded = RFC2047Decoder.decode(input)
        #expect(decoded == "Just a plain string")
    }

    @Test("Joins adjacent encoded-words")
    func decodeRFC2047Adjacent() {
        // Two adjacent encoded-words separated by whitespace should be joined (RFC 2047 §6.2)
        let input = "=?UTF-8?B?5rWL?= =?UTF-8?B?6K+V?="
        let decoded = RFC2047Decoder.decode(input)
        #expect(decoded == "测试")
    }

    // MARK: - Charset Mapping

    @Test("Maps UTF-8 charset")
    func charsetUTF8() {
        #expect(Data.stringEncoding(fromCharset: "utf-8") == .utf8)
    }

    @Test("Maps ISO-8859-1 charset")
    func charsetLatin1() {
        #expect(Data.stringEncoding(fromCharset: "iso-8859-1") == .isoLatin1)
    }

    @Test("Maps nil charset to UTF-8")
    func charsetNil() {
        #expect(Data.stringEncoding(fromCharset: nil) == .utf8)
    }

    @Test("Maps unknown charset to UTF-8")
    func charsetUnknown() {
        #expect(Data.stringEncoding(fromCharset: "x-unknown") == .utf8)
    }
}

// MARK: - RFC 2822 Decoder

@Suite("RFC2822Decoder")
struct RFC2822DecoderTests {

    @Test("Extracts text/plain body from simple message")
    func extractSimpleText() {
        let raw = "From: test@example.com\r\nContent-Type: text/plain\r\n\r\nHello World"
        let text = RFC2822Decoder.extractTextBody(raw)
        #expect(text == "Hello World")
    }

    @Test("Strips HTML tags from text/html message")
    func extractHTMLBody() {
        let raw = "Content-Type: text/html\r\n\r\n<p>Hello <b>World</b></p>"
        let text = RFC2822Decoder.extractTextBody(raw)
        #expect(text.contains("Hello"))
        #expect(text.contains("World"))
        #expect(!text.contains("<p>"))
    }

    @Test("Handles empty body")
    func extractEmptyBody() {
        let raw = "From: test@example.com\r\n\r\n"
        let text = RFC2822Decoder.extractTextBody(raw)
        #expect(text.isEmpty)
    }
}
