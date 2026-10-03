import XCTest
@testable import PSTKit

final class MboxTests: XCTestCase {
    func archive() throws -> MboxArchive {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try MboxArchive(url: fixtures.appendingPathComponent("netscape"))
    }

    func folder(_ root: Folder, _ name: String) throws -> Folder {
        try XCTUnwrap(root.allFolders.first { $0.name == name }, "missing folder \(name)")
    }

    func testFolderTree() throws {
        let store = try archive()
        let root = try store.rootFolder()
        // Mail files become folders, .sbd directories their subfolders; .snm and .dat files are skipped.
        XCTAssertEqual(root.children.map(\.name), ["Inbox", "Templates", "Sent", "Projecten"])
        let projecten = try folder(root, "Projecten")
        XCTAssertEqual(projecten.children.map(\.name), ["Klant A"])
        XCTAssertEqual(projecten.contentCount, 0)
        XCTAssertEqual(try folder(root, "Inbox").kind, .inbox)
        XCTAssertEqual(try folder(root, "Sent").kind, .sent)
        XCTAssertEqual(root.totalCount, 6)
    }

    func testOpenedThroughMailStores() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        XCTAssertTrue(try MailStores.open(fixtures.appendingPathComponent("netscape")) is MboxArchive)
        let single = try MailStores.open(fixtures.appendingPathComponent("netscape/Sent"))
        XCTAssertEqual(try single.rootFolder().children.map(\.name), ["Sent"])
        XCTAssertTrue(try MailStores.open(fixtures.appendingPathComponent("dist-list.pst")) is PSTFile)
    }

    func testMessageListSkipsDeletedAndKeepsFromLines() throws {
        let store = try archive()
        let inbox = try folder(try store.rootFolder(), "Inbox")
        let list = try store.messages(in: inbox.nid)
        // The expunged message is hidden; "From " inside a message text doesn't split it.
        XCTAssertEqual(list.map(\.subject), ["Café morgen", "Report with attachment", "HTML mail"])
        XCTAssertEqual(inbox.unreadCount, 1)
        XCTAssertFalse(list[1].isRead)
        XCTAssertTrue(list[1].hasAttachments)
        XCTAssertEqual(list[1].from, "Anna Smith")
        XCTAssertEqual(list[1].importance, 2)
        XCTAssertEqual(list[0].from, "Jan de Vries")
        XCTAssertEqual(list[0].to, "mvberkum@example.nl; Berg, Piet")
        XCTAssertEqual(list[2].from, "René Janssen", "raw 8-bit header in the default code page")
        XCTAssertEqual(list[0].date, Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(list[2].date, Date(timeIntervalSince1970: 941_439_540), "two-digit year and MET zone")
        XCTAssertTrue(store.info.contains { $0.1.hasPrefix("1 ") }, "deleted messages are reported")
    }

    func testQuotedPrintableMessage() throws {
        let store = try archive()
        let inbox = try folder(try store.rootFolder(), "Inbox")
        let m = try store.message(nid: try store.messages(in: inbox.nid)[0].nid)
        XCTAssertEqual(m.subject, "Café morgen")
        XCTAssertEqual(m.from, "Jan de Vries <jan@example.nl>")
        XCTAssertEqual(m.recipients(.to).map(\.email), ["mvberkum@example.nl", "piet@example.nl"])
        XCTAssertEqual(m.recipients(.to).last?.name, "Berg, Piet")
        guard case .text(let t) = m.body else { return XCTFail("expected plain text") }
        XCTAssertEqual(t, "Zullen we morgen naar het café gaan?\nGroet, Jan")
        XCTAssertTrue(m.transportHeaders.contains("Message-ID: <38214A1B.1@example.nl>"))
        XCTAssertEqual(m.messageID, "<38214A1B.1@example.nl>")
    }

    func testMultipartWithAttachment() throws {
        let store = try archive()
        let inbox = try folder(try store.rootFolder(), "Inbox")
        let m = try store.message(nid: try store.messages(in: inbox.nid)[1].nid)
        XCTAssertTrue(m.plainBody.contains("From here on it gets better"))
        XCTAssertTrue(m.plainBody.hasSuffix("Bye"))
        XCTAssertEqual(m.attachments.map(\.filename), ["hello.txt"])
        XCTAssertEqual(String(decoding: try m.data(for: m.attachments[0]), as: UTF8.self), "Hello, world!\n")
        XCTAssertEqual(m.importance, 2)
    }

    func testAlternativePrefersHTML() throws {
        let store = try archive()
        let inbox = try folder(try store.rootFolder(), "Inbox")
        let m = try store.message(nid: try store.messages(in: inbox.nid)[2].nid)
        guard case .html(let h) = m.body else { return XCTFail("expected HTML") }
        XCTAssertTrue(h.contains("<b>Dit is HTML-mail van René.</b>"))
        XCTAssertEqual(m.plainBody, "Dit is HTML-mail van René.")
        XCTAssertTrue(m.attachments.isEmpty)
    }

    func testUUEncodedAndForwardedMessages() throws {
        let store = try archive()
        let sent = try folder(try store.rootFolder(), "Sent")
        let list = try store.messages(in: sent.nid)
        XCTAssertEqual(list.count, 2)

        let uu = try store.message(nid: list[0].nid)
        XCTAssertEqual(uu.attachments.map(\.filename), ["data.bin"])
        XCTAssertEqual([UInt8](try uu.data(for: uu.attachments[0])), Array(0..<60))
        XCTAssertFalse(uu.plainBody.contains("begin 644"))
        XCTAssertTrue(uu.plainBody.contains("Regards"))

        let fwd = try store.message(nid: list[1].nid)
        let att = try XCTUnwrap(fwd.attachments.first)
        XCTAssertTrue(att.isEmbeddedMessage)
        XCTAssertEqual(att.filename, "Original report")
        let inner = try XCTUnwrap(fwd.embeddedMessage(att))
        XCTAssertEqual(inner.subject, "Original report")
        XCTAssertEqual(inner.fromName, "Anna Smith")
        XCTAssertEqual(inner.plainBody, "The original text.")
    }

    func testCarriageReturnLineEndings() throws {
        let store = try archive()
        let klant = try folder(try store.rootFolder(), "Klant A")
        let list = try store.messages(in: klant.nid)
        XCTAssertEqual(list.map(\.subject), ["Project kickoff"])
        let m = try store.message(nid: list[0].nid)
        XCTAssertEqual(m.plainBody, "Saved by a classic Mac OS mail program: CR line endings.")
    }

    func testExportKeepsOriginalMessage() throws {
        let store = try archive()
        let inbox = try folder(try store.rootFolder(), "Inbox")
        let m = try store.message(nid: try store.messages(in: inbox.nid)[0].nid)
        let eml = try EMLWriter.eml(for: m)
        XCTAssertTrue(eml.starts(with: Array("X-Mozilla-Status: 0001\r\n".utf8)))
        XCTAssertTrue(String(decoding: eml, as: UTF8.self).contains("caf=E9"))
        let entry = String(decoding: try EMLWriter.mboxEntry(for: try store.message(nid: try store.messages(in: inbox.nid)[1].nid)), as: UTF8.self)
        XCTAssertTrue(entry.hasPrefix("From anna@example.com "))
        XCTAssertTrue(entry.contains("\n>>From the start"))
        XCTAssertTrue(entry.contains("\n>From here on"))
        XCTAssertFalse(entry.contains("\r"))
    }

    // MARK: - MIME helpers

    func testEncodedWords() {
        XCTAssertEqual(MIME.decodeWords("=?ISO-8859-1?Q?Andr=E9?= Pirard"), "André Pirard")
        XCTAssertEqual(MIME.decodeWords("=?utf-8?B?SGFsbG8=?= =?utf-8?B?IHdlcmVsZA==?="), "Hallo wereld")
        XCTAssertEqual(MIME.decodeWords("a =?x?Q?broken"), "a =?x?Q?broken")
    }

    func testContentTypeParameters() {
        let (t, p) = MIME.parseContentType("Application/Octet-Stream; name*0*=utf-8''r%C3%A9; name*1=sum%C3.pdf; x=\"a;b\"")
        XCTAssertEqual(t, "application/octet-stream")
        XCTAssertEqual(p["name"], "résum%C3.pdf")
        XCTAssertEqual(p["x"], "a;b")
    }

    func testDates() {
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 10:14:51 +0100"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(MIME.parseDate("Thu, 04 Nov 1999 09:14:51 GMT"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 10:14:51 +01:00"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 10:14:51 MET"), Date(timeIntervalSince1970: 941_706_891))
        // Summer time: MET DST is two hours ahead of UTC; a numeric offset wins over the name.
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 11:14:51 MET DST"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 11:14:51 +0200 (MET DST)"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertEqual(MIME.parseDate("Thu, 4 Nov 1999 10:14:51 +0100 (EST)"), Date(timeIntervalSince1970: 941_706_891))
        XCTAssertNil(MIME.parseDate("gisteren"))
    }

    func testAddresses() {
        let a = MIME.parseAddresses("\"Doe, John\" <john@x.org>, jane@y.org (Jane Roe), =?iso-8859-1?Q?Ren=E9?= <r@z.nl>, plain@w.com")
        XCTAssertEqual(a.map(\.name), ["Doe, John", "Jane Roe", "René", ""])
        XCTAssertEqual(a.map(\.email), ["john@x.org", "jane@y.org", "r@z.nl", "plain@w.com"])
    }
}
