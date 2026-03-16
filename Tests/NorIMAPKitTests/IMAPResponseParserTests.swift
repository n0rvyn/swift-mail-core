// IMAPResponseParserTests.swift
// NorIMAPKit

import Testing
@testable import NorIMAPKit

@Suite("IMAPResponseParser")
struct IMAPResponseParserTests {

    // MARK: - parseTagged

    @Test("Parses OK tagged response")
    func parseTaggedOK() {
        let result = IMAPResponseParser.parseTagged("A001 OK SELECT completed")
        #expect(result != nil)
        #expect(result?.tag == "A001")
        #expect(result?.status == .ok)
        #expect(result?.text == "SELECT completed")
    }

    @Test("Parses NO tagged response")
    func parseTaggedNO() {
        let result = IMAPResponseParser.parseTagged("A002 NO [AUTHENTICATIONFAILED] Invalid credentials")
        #expect(result != nil)
        #expect(result?.tag == "A002")
        #expect(result?.status == .no)
    }

    @Test("Parses BAD tagged response")
    func parseTaggedBAD() {
        let result = IMAPResponseParser.parseTagged("A003 BAD Command syntax error")
        #expect(result != nil)
        #expect(result?.status == .bad)
    }

    @Test("Returns nil for untagged response")
    func parseTaggedUntagged() {
        let result = IMAPResponseParser.parseTagged("* OK [UIDVALIDITY 1] UIDs valid")
        #expect(result == nil)
    }

    @Test("Returns nil for continuation response")
    func parseTaggedContinuation() {
        let result = IMAPResponseParser.parseTagged("+ Ready for additional command text")
        #expect(result == nil)
    }

    // MARK: - parseSearchUIDs

    @Test("Parses SEARCH UIDs")
    func parseSearchUIDs() {
        let uids = IMAPResponseParser.parseSearchUIDs("* SEARCH 101 102 103")
        #expect(uids == [101, 102, 103])
    }

    @Test("Parses empty SEARCH")
    func parseSearchEmpty() {
        let uids = IMAPResponseParser.parseSearchUIDs("* SEARCH")
        #expect(uids.isEmpty)
    }

    @Test("Returns empty for non-SEARCH line")
    func parseSearchWrongLine() {
        let uids = IMAPResponseParser.parseSearchUIDs("* FLAGS (\\Seen)")
        #expect(uids.isEmpty)
    }

    // MARK: - parseFetchEnvelope

    @Test("Parses FETCH envelope with standard fields")
    func parseFetchEnvelope() {
        let lines = [
            "* 5 FETCH (UID 101 FLAGS (\\Seen) INTERNALDATE \"24-Feb-2026 10:00:00 +0000\" ENVELOPE (\"Tue, 24 Feb 2026 10:00:00 +0000\" \"Meeting request\" ((\"Alice\" NIL \"alice\" \"corp.com\")) ((\"Alice\" NIL \"alice\" \"corp.com\")) ((\"Alice\" NIL \"alice\" \"corp.com\")) ((\"Bob\" NIL \"bob\" \"corp.com\")) NIL NIL NIL \"<msg001@corp.com>\"))"
        ]
        let msg = IMAPResponseParser.parseFetchEnvelope(lines: lines)
        #expect(msg != nil)
        #expect(msg?.uid == 101)
        #expect(msg?.subject == "Meeting request")
        #expect(msg?.sender.contains("alice@corp.com") == true)
        #expect(msg?.isSeen == true)
        #expect(msg?.messageId == "<msg001@corp.com>")
    }

    @Test("Returns nil for malformed FETCH")
    func parseFetchMalformed() {
        let msg = IMAPResponseParser.parseFetchEnvelope(lines: ["garbage data"])
        #expect(msg == nil)
    }

    // MARK: - parseBodyStructure

    @Test("Parses simple text/plain BODYSTRUCTURE")
    func parseBodyStructureSimple() {
        let line = "* 1 FETCH (UID 101 BODYSTRUCTURE (\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 1024 32))"
        let part = IMAPResponseParser.parseBodyStructure(line)
        #expect(part != nil)
        if case .singlePart(let type, let subtype, let encoding, let size, let path, _, let charset) = part {
            #expect(type == "text")
            #expect(subtype == "plain")
            #expect(encoding == "7bit")
            #expect(size == 1024)
            #expect(path == "1")
            #expect(charset == "utf-8")
        } else {
            Issue.record("Expected singlePart")
        }
    }

    @Test("Parses multipart/mixed BODYSTRUCTURE")
    func parseBodyStructureMultipart() {
        let line = "* 1 FETCH (UID 101 BODYSTRUCTURE ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 512 10)(\"application\" \"pdf\" (\"name\" \"report.pdf\") NIL NIL \"base64\" 204800) \"mixed\"))"
        let part = IMAPResponseParser.parseBodyStructure(line)
        #expect(part != nil)
        if case .multipart(let parts, let subtype) = part {
            #expect(subtype == "mixed")
            #expect(parts.count == 2)
            // First part is text/plain
            if case .singlePart(let type, let subtype, _, _, _, _, _) = parts[0] {
                #expect(type == "text")
                #expect(subtype == "plain")
            }
            // Second part is application/pdf with filename
            if case .singlePart(let type, _, _, _, _, let filename, _) = parts[1] {
                #expect(type == "application")
                #expect(filename == "report.pdf")
            }
        } else {
            Issue.record("Expected multipart")
        }
    }

    // MARK: - parseListResponse

    @Test("Parses LIST response with flags")
    func parseListResponse() {
        let folder = IMAPResponseParser.parseListResponse(#"* LIST (\HasNoChildren) "/" "INBOX""#)
        #expect(folder != nil)
        #expect(folder?.name == "INBOX")
        #expect(folder?.delimiter == "/")
        #expect(folder?.flags == ["\\HasNoChildren"])
    }

    @Test("Parses LIST response with Gmail path")
    func parseListGmail() {
        let folder = IMAPResponseParser.parseListResponse(#"* LIST (\HasNoChildren \Sent) "/" "[Gmail]/Sent Mail""#)
        #expect(folder != nil)
        #expect(folder?.name == "[Gmail]/Sent Mail")
    }

    @Test("Returns nil for non-LIST line")
    func parseListNonList() {
        let folder = IMAPResponseParser.parseListResponse("A001 OK LIST completed")
        #expect(folder == nil)
    }
}
