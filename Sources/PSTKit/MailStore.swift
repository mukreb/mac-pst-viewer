import Foundation

/// A source of folders and messages: a PST/OST file or an mbox mail archive.
public protocol MailStore: AnyObject, Sendable {
    var url: URL { get }
    /// The store's own name; for PST files often a generic "Personal Folders".
    var displayName: String { get }
    /// Label/value pairs for the "file info" panel.
    var info: [(String, String)] { get }
    func rootFolder() throws -> Folder
    func messages(in folderNID: UInt32) throws -> [MessageSummary]
    func message(nid: UInt32) throws -> Message
}

extension PSTFile: MailStore {}

public enum MailStores {
    /// Opens a PST/OST file, an mbox file, or a folder of mbox files
    /// (Netscape Communicator, Mozilla, Thunderbird, Eudora, …).
    public static func open(_ url: URL) throws -> any MailStore {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw PSTError.notFound(url.lastPathComponent)
        }
        if isDir.boolValue { return try MboxArchive(url: url) }
        let handle = try FileHandle(forReadingFrom: url)
        let head = handle.readData(ofLength: 5)
        try? handle.close()
        if head.starts(with: Array("!BDN".utf8)) { return try PSTFile(url: url) }
        if MboxArchive.looksLikeMbox(head) || url.pathExtension.lowercased() == "mbox" { return try MboxArchive(url: url) }
        return try PSTFile(url: url)
    }
}
