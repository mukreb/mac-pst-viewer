import XCTest
@testable import PSTKit

final class MailExportTests: XCTestCase {
    func fixtureURL(_ path: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)).appendingPathComponent(path)
    }

    func temporaryMbox() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).mbox")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Reads an exported file back with the app's own mbox reader.
    func exported(_ url: URL) throws -> (subjects: [String], store: MboxArchive) {
        let store = try MboxArchive(url: url)
        let folder = try XCTUnwrap(try store.rootFolder().children.first)
        return (try store.messages(in: folder.nid).map(\.subject), store)
    }

    func testExportsEverythingWithFolderHeader() throws {
        let out = temporaryMbox()
        let source = try MailStores.open(try fixtureURL("netscape"))
        let report = try MboxExport.export(stores: [source], filter: MailFilter(), to: out)
        XCTAssertEqual(report.written, 6)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertTrue(report.failures.isEmpty)
        let (subjects, _) = try exported(out)
        XCTAssertEqual(subjects.count, 6)
        let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
        XCTAssertTrue(text.contains("\nX-Folder: netscape/Projecten/Klant A\n"))
        XCTAssertTrue(text.hasPrefix("From jan@example.nl "))
    }

    func testSearchMatchesAddressesNotOnlyListNames() throws {
        let out = temporaryMbox()
        let pst = try MailStores.open(try fixtureURL("tika-testPST.pst"))
        // The message list shows "Jörn Kottmann"; the address is only in the full message.
        XCTAssertFalse(try pst.messages(in: try pst.rootFolder().allFolders[1].nid).contains { $0.from.contains("kottmann@") })
        let report = try MboxExport.export(stores: [pst], filter: MailFilter(query: "KOTTMANN@gmail.com"), to: out)
        XCTAssertEqual(report.written, 2)
        XCTAssertTrue(try exported(out).subjects.contains("Re: Feature Generators"))
    }

    func testBodySearchAndFolderFilter() throws {
        let out = temporaryMbox()
        let source = try MailStores.open(try fixtureURL("netscape"))
        // Words must all occur, in any order; "--body" also searches the text.
        XCTAssertEqual(try MboxExport.export(stores: [source], filter: MailFilter(query: "couchbase webinar"), to: out).written, 0)
        let pst = try MailStores.open(try fixtureURL("tika-testPST.pst"))
        XCTAssertEqual(try MboxExport.export(stores: [pst], filter: MailFilter(query: "server couchbase", searchBodies: true), to: out).written, 1)

        let sent = try MboxExport.export(stores: [source], filter: MailFilter(query: "piet", folder: "sent"), to: out)
        XCTAssertEqual(sent.written, 1)
        XCTAssertEqual(try exported(out).subjects, ["Fwd: Report with attachment"])
    }

    func testDuplicatesAcrossArchivesAreWrittenOnce() throws {
        let out = temporaryMbox()
        let url = try fixtureURL("tika-testPST.pst")
        let report = try MboxExport.export(stores: [try MailStores.open(url), try MailStores.open(url)], filter: MailFilter(), to: out)
        XCTAssertEqual(report.written, 7)
        XCTAssertEqual(report.duplicates, 7)
    }

    func testAppend() throws {
        let out = temporaryMbox()
        let source = try MailStores.open(try fixtureURL("netscape"))
        try MboxExport.export(stores: [source], filter: MailFilter(folder: "inbox"), to: out)
        try MboxExport.export(stores: [source], filter: MailFilter(folder: "klant"), to: out, append: true)
        XCTAssertEqual(try exported(out).subjects.count, 4)
        try MboxExport.export(stores: [source], filter: MailFilter(folder: "klant"), to: out)
        XCTAssertEqual(try exported(out).subjects, ["Project kickoff"])
    }

    func testAppendToFileWithoutTrailingNewline() throws {
        let out = temporaryMbox()
        try Data("From a@b.c Thu Jan 01 00:00:00 1998\nSubject: Existing\n\nlast line without newline".utf8).write(to: out)
        let source = try MailStores.open(try fixtureURL("netscape"))
        try MboxExport.export(stores: [source], filter: MailFilter(folder: "klant"), to: out, append: true)
        XCTAssertEqual(try exported(out).subjects, ["Existing", "Project kickoff"])
    }

    func testOverlapWithSources() throws {
        let netscape = try fixtureURL("netscape")
        let pst = try fixtureURL("tika-testPST.pst")
        XCTAssertTrue(MboxExport.overlaps(pst, sources: [netscape, pst]))
        XCTAssertTrue(MboxExport.overlaps(netscape.appendingPathComponent("Inbox"), sources: [netscape]))
        XCTAssertTrue(MboxExport.overlaps(netscape.appendingPathComponent("../netscape/x.mbox"), sources: [netscape]))
        XCTAssertFalse(MboxExport.overlaps(netscape.deletingLastPathComponent().appendingPathComponent("netscape.mbox"), sources: [netscape]))
    }

    func testHardLinkedSourceIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Inbox")
        try FileManager.default.copyItem(at: try fixtureURL("netscape/Inbox"), to: source)
        let alias = dir.appendingPathComponent("alias.mbox")
        try FileManager.default.linkItem(at: source, to: alias)
        let before = try Data(contentsOf: source)
        XCTAssertTrue(MboxExport.overlaps(alias, sources: [source]))
        XCTAssertThrowsError(try MboxExport.export(stores: [try MailStores.open(source)], filter: MailFilter(), to: alias, append: true))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testAppendToClassicMacFileIsRefused() throws {
        let out = temporaryMbox()
        let original = Data("From a@b.c Thu Jan 01 00:00:00 1998\rSubject: Existing\r\rtext\r".utf8)
        try original.write(to: out)
        let source = try MailStores.open(try fixtureURL("netscape"))
        XCTAssertThrowsError(try MboxExport.export(stores: [source], filter: MailFilter(), to: out, append: true))
        XCTAssertEqual(try Data(contentsOf: out), original)
    }

    func testOutputInsideSourceFolderByAnotherNameIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        let mail = dir.appendingPathComponent("Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        // A second name for the source folder whose path doesn't share the source's prefix.
        let other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let alias = other.appendingPathComponent("mail")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: mail)
        XCTAssertTrue(MboxExport.overlaps(alias.appendingPathComponent("Inbox"), sources: [mail]))
        XCTAssertTrue(MboxExport.overlaps(mail.appendingPathComponent("new.mbox"), sources: [alias]))
        XCTAssertFalse(MboxExport.overlaps(other.appendingPathComponent("new.mbox"), sources: [mail]))
    }

    func testHardLinkToFileInsideSourceFolderIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        let mail = dir.appendingPathComponent("Mail")
        try FileManager.default.createDirectory(at: mail.appendingPathComponent("Projects.sbd"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let member = mail.appendingPathComponent("Projects.sbd/Client")
        try FileManager.default.copyItem(at: try fixtureURL("netscape/Inbox"), to: member)
        let alias = dir.appendingPathComponent("export.mbox")
        try FileManager.default.linkItem(at: member, to: alias)
        XCTAssertTrue(MboxExport.overlaps(alias, sources: [mail]))
        XCTAssertFalse(MboxExport.overlaps(dir.appendingPathComponent("new.mbox"), sources: [mail]))
    }

    func testReexportingMboxDoesNotQuoteTwice() throws {
        let source = temporaryMbox()
        try Data("From a@b.c Thu Jan 01 00:00:00 1998\nSubject: Quoted\n\n>From the start\n>>From deeper\nplain\n\n".utf8).write(to: source)
        var file = source
        for _ in 0..<2 {
            let out = temporaryMbox()
            try MboxExport.export(stores: [try MailStores.open(file)], filter: MailFilter(), to: out)
            let text = String(decoding: try Data(contentsOf: out), as: UTF8.self)
            XCTAssertTrue(text.contains("\n>From the start\n>>From deeper\n"), text)
            file = out
        }
    }
}
