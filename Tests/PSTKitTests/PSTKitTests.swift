import XCTest
@testable import PSTKit

final class PSTKitTests: XCTestCase {
    func fixture(_ name: String) throws -> PSTFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "pst", subdirectory: "Fixtures"))
        return try PSTFile(url: url)
    }

    func folder(_ root: Folder, named name: String) -> Folder? {
        root.allFolders.first { $0.name == name }
    }

    // MARK: - Formats

    func testUnicodeFolderTree() throws {
        let pst = try fixture("dist-list")
        XCTAssertEqual(pst.format, .unicode)
        XCTAssertEqual(pst.encryption, "compressible")
        let root = try pst.rootFolder()
        let names = Set(root.allFolders.map(\.name))
        for n in ["Inbox", "Calendar", "Contacts", "Sent Items", "Deleted Items"] {
            XCTAssertTrue(names.contains(n), "missing folder \(n)")
        }
    }

    func testANSIWithPermuteEncryption() throws {
        let pst = try fixture("dist-list-ansi")
        XCTAssertEqual(pst.format, .ansi)
        XCTAssertEqual(pst.encryption, "compressible")
        let root = try pst.rootFolder()
        let contacts = try XCTUnwrap(folder(root, named: "Contacts"))
        let items = try pst.messages(in: contacts.nid)
        XCTAssertEqual(Set(items.map(\.subject)), ["contact name 1", "test dist list"])
    }

    func testANSIWithCyclicEncryptionMatchesUnicode() throws {
        let ansi = try fixture("tika-ansi-high")
        let unicode = try fixture("tika-testPST")
        XCTAssertEqual(ansi.format, .ansi)
        XCTAssertEqual(ansi.encryption, "high")

        func subjects(_ pst: PSTFile) throws -> [String] {
            let root = try pst.rootFolder()
            return try root.allFolders.flatMap { try pst.messages(in: $0.nid) }.map(\.subject).sorted()
        }
        let s = try subjects(ansi)
        XCTAssertEqual(s.count, 7)
        XCTAssertEqual(s, try subjects(unicode))
    }

    // MARK: - Messages

    func testMessageListAndHeaders() throws {
        let pst = try fixture("tika-testPST")
        let root = try pst.rootFolder()
        XCTAssertTrue(root.allFolders.contains { $0.name == "Éléments supprimés" }, "accented folder names must decode")
        let all = try root.allFolders.flatMap { try pst.messages(in: $0.nid) }
        let msg = try XCTUnwrap(all.first { $0.subject == "Re: Feature Generators" })
        XCTAssertEqual(msg.from, "Jörn Kottmann")
        XCTAssertNotNil(msg.date)

        let full = try pst.message(nid: msg.nid)
        XCTAssertEqual(full.subject, "Re: Feature Generators")
        XCTAssertFalse(full.plainBody.isEmpty)
        XCTAssertFalse(full.recipients.isEmpty)
    }

    func testEmbeddedMessageAttachment() throws {
        let pst = try fixture("tika-testPST")
        let root = try pst.rootFolder()
        let all = try root.allFolders.flatMap { try pst.messages(in: $0.nid) }
        let fw = try XCTUnwrap(all.first { $0.subject == "FW: First email" })
        XCTAssertTrue(fw.hasAttachments)
        let m = try pst.message(nid: fw.nid)
        let att = try XCTUnwrap(m.attachments.first)
        if att.isEmbeddedMessage {
            let inner = try XCTUnwrap(try m.embeddedMessage(att))
            XCTAssertFalse(inner.subject.isEmpty)
        } else {
            XCTAssertGreaterThan(try m.data(for: att).count, 0)
        }
    }

    func testBodyTypes() throws {
        let pst = try fixture("tika-various-body-types")
        let root = try pst.rootFolder()
        let tmp = try XCTUnwrap(folder(root, named: "tmp"))
        let items = try pst.messages(in: tmp.nid).sorted { $0.nid < $1.nid }
        XCTAssertEqual(items.count, 4)

        var kinds: [String] = []
        for s in items {
            let m = try pst.message(nid: s.nid)
            switch m.body {
            case .html(let h): kinds.append("html"); XCTAssertTrue(h.lowercased().contains("<html"))
            case .rtf(let r): kinds.append("rtf"); XCTAssertTrue(RTF.plainText([UInt8](r)).contains("Forwarded RTF"))
            case .text(let t): kinds.append("text"); XCTAssertTrue(t.contains("Forwarded plain text"))
            }
        }
        XCTAssertTrue(kinds.contains("html"))
        XCTAssertTrue(kinds.contains("rtf"))
        XCTAssertTrue(kinds.contains("text"))
    }

    func testAttachmentsWithContentID() throws {
        let pst = try fixture("inline-cid")
        let root = try pst.rootFolder()
        let inbox = try XCTUnwrap(folder(root, named: "Inbox"))
        let items = try pst.messages(in: inbox.nid)
        XCTAssertEqual(items.count, 3)
        let s = try XCTUnwrap(items.first { $0.subject == "Duplicate inline identifiers" })
        let m = try pst.message(nid: s.nid)
        XCTAssertEqual(m.attachments.map(\.filename), ["first.png", "second.png"])
        let data = try m.data(for: m.attachments[0])
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // PNG signature
    }

    func testContactNamedProperties() throws {
        let pst = try fixture("dist-list")
        let root = try pst.rootFolder()
        let contacts = try XCTUnwrap(folder(root, named: "Contacts"))
        let s = try XCTUnwrap(try pst.messages(in: contacts.nid).first { $0.subject == "contact name 1" })
        let m = try pst.message(nid: s.nid)
        XCTAssertEqual(m.kind, .contact)
        let details = Dictionary(m.details, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(details["E-mail"], "contact1@rjohnson.id.au")
    }

    func testEMLExport() throws {
        let pst = try fixture("inline-cid")
        let root = try pst.rootFolder()
        let inbox = try XCTUnwrap(folder(root, named: "Inbox"))
        let s = try XCTUnwrap(try pst.messages(in: inbox.nid).first)
        let eml = String(decoding: try EMLWriter.eml(for: try pst.message(nid: s.nid)), as: UTF8.self)
        XCTAssertTrue(eml.contains("Subject: "))
        XCTAssertTrue(eml.contains("multipart/mixed"))
        XCTAssertTrue(eml.contains("Content-ID: <"))
    }

    // MARK: - Codecs

    func testRTFDecompression() {
        // Example from [MS-OXRTFCP] section 4.1.
        let compressed: [UInt8] = [
            0x2d, 0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x4c, 0x5a, 0x46, 0x75, 0xf1, 0xc5, 0xc7, 0xa7,
            0x03, 0x00, 0x0a, 0x00, 0x72, 0x63, 0x70, 0x67, 0x31, 0x32, 0x35, 0x42, 0x32, 0x0a, 0xf3, 0x20,
            0x68, 0x65, 0x6c, 0x09, 0x00, 0x20, 0x62, 0x77, 0x05, 0xb0, 0x6c, 0x64, 0x7d, 0x0a, 0x80, 0x0f, 0xa0,
        ]
        let out = RTF.decompress(compressed).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(out, "{\\rtf1\\ansi\\ansicpg1252\\pard hello world}\r\n")
    }

    func testRTFHTMLDeencapsulation() {
        let rtf = Array("{\\rtf1\\ansi\\ansicpg1252\\fromhtml1 {\\*\\htmltag19 <html>}{\\*\\htmltag34 <body>}\\htmlrtf {\\htmlrtf0 caf\\'e9\\htmlrtf }\\htmlrtf0 {\\*\\htmltag35 </body>}}".utf8)
        XCTAssertTrue(RTF.isEncapsulatedHTML(rtf))
        let html = RTF.extractHTML(rtf)
        XCTAssertTrue(html.contains("<html>"))
        XCTAssertTrue(html.contains("café"))
        XCTAssertTrue(html.contains("</body>"))
    }

    func testInflate() throws {
        // zlib.compress(b"hello hello hello hello")
        let z: [UInt8] = [0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0xc8, 0x40, 0x27, 0x01, 0x68, 0x03, 0x08, 0xb1]
        let out = try XCTUnwrap(Inflate.zlib(z))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello hello hello hello")
    }

    func testAddressEncoding() {
        XCTAssertEqual(EMLWriter.address(name: "Jörn Kottmann", email: "kottmann@gmail.com"),
                       "=?utf-8?B?SsO2cm4gS290dG1hbm4=?= <kottmann@gmail.com>")
        XCTAssertEqual(EMLWriter.address(name: "Allison, Timothy B.", email: "Allison, Timothy B. <t@mitre.org>"),
                       "\"Allison, Timothy B.\" <t@mitre.org>")
        XCTAssertEqual(EMLWriter.address(name: "x@y.z", email: "x@y.z"), "x@y.z")
    }

    func testRTFSurrogatePairs() {
        let rtf = Array("{\\rtf1\\ansi smile \\u-10179?\\u-8704? done}".utf8)
        XCTAssertTrue(RTF.plainText(rtf).contains("smile 😀 done"))
    }

    func testLongEncodedWordsAreSplit() {
        let subject = String(repeating: "één twee drie ", count: 8)
        let encoded = EMLWriter.encodeWord(subject)
        let words = encoded.components(separatedBy: "\r\n ")
        XCTAssertGreaterThan(words.count, 1)
        for w in words { XCTAssertLessThanOrEqual(w.count, 75) }
        let decoded = words.map { w -> String in
            let b64 = w.dropFirst("=?utf-8?B?".count).dropLast(2)
            return String(decoding: Data(base64Encoded: String(b64))!, as: UTF8.self)
        }.joined()
        XCTAssertEqual(decoded, subject)
    }

    func testHTMLEntities() {
        XCTAssertEqual(HTMLText.toPlain("<p>caf&eacute; &#233; &#xE9; &amp; &lt;b&gt; &bogus; &euro;</p>"),
                       "café é é & <b> &bogus; €")
    }

    func testQuotedParam() {
        XCTAssertEqual(EMLWriter.quotedParam("report \"final\".pdf"), "\"report \\\"final\\\".pdf\"")
        XCTAssertFalse(EMLWriter.quotedParam("a\r\nX-Evil: 1.txt").contains("\n"))
    }

    func testRTFHugeAdvertisedSize() {
        var bytes: [UInt8] = [0x20, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F, 0x4C, 0x5A, 0x46, 0x75, 0, 0, 0, 0]
        bytes += [UInt8](repeating: 0, count: 16)
        XCTAssertNotNil(RTF.decompress(bytes))
    }

    func testHeaderInjectionIsFlattened() {
        XCTAssertEqual(EMLWriter.flat("<id@x>\r\nBcc: evil@x"), "<id@x>  Bcc: evil@x")
        XCTAssertEqual(EMLWriter.addrSpec("Name <a@b.c>\r\nX: y"), "a@b.c")
        XCTAssertFalse(EMLWriter.address(name: "A\r\nB", email: "a@b.c\r\nX: 1").contains("\n"))
    }

    func testSafeName() {
        XCTAssertEqual(EMLWriter.safeName(".."), "__")
        XCTAssertEqual(EMLWriter.safeName("."), "_")
        XCTAssertEqual(EMLWriter.safeName("a/b:c"), "a_b_c")
        XCTAssertEqual(EMLWriter.safeName("  "), "zonder onderwerp")
    }

    func testCodepages() {
        XCTAssertEqual(PSTText.decode([0x63, 0x61, 0x66, 0xE9], codepage: 1252), "café")
        XCTAssertEqual(PSTText.decode([0x80], codepage: 1252), "€")
    }
}
