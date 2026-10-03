import Foundation

/// Selects messages by words in their subject, sender and recipients (names and addresses),
/// optionally also in the message text, and by folder.
public struct MailFilter: Sendable {
    /// Lowercased words that must all occur.
    public let terms: [String]
    public let searchBodies: Bool
    /// Lowercased text the folder path ("Inbox", "Projects/Client A") must contain.
    public let folder: String?

    public init(query: String = "", searchBodies: Bool = false, folder: String? = nil) {
        terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        self.searchBodies = searchBodies
        let f = folder?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        self.folder = f.isEmpty ? nil : f
    }

    public func includes(folderPath: String) -> Bool {
        guard let folder else { return true }
        return folderPath.lowercased().contains(folder)
    }

    /// Cheap check on the message list fields; a miss can still match on the full message.
    public func matches(_ s: MessageSummary) -> Bool {
        matches(s.subject + " " + s.from + " " + s.to + " " + s.cc)
    }

    /// Full check: list fields plus the complete sender and recipient addresses, and the text
    /// and attachment names when `searchBodies` is set.
    public func matches(_ m: Message, summary: MessageSummary) -> Bool {
        var hay = summary.subject + " " + summary.from + " " + summary.to + " " + summary.cc
        hay += " " + m.subject + " " + m.from + " " + m.to + " " + m.cc + " " + m.bcc
        if matches(hay) { return true }
        guard searchBodies else { return false }
        return matches(hay + " " + m.plainBody + " " + m.attachments.map(\.filename).joined(separator: " "))
    }

    func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        return terms.allSatisfy { t.contains($0) }
    }
}

/// Writes messages from one or more mail stores to a single mbox file.
public enum MboxExport {
    public struct Report: Sendable {
        /// Messages checked against the filter.
        public var scanned = 0
        public var written = 0
        /// Copies of a message already written (same store entry, or same Message-ID).
        public var duplicates = 0
        public var failures: [String] = []
    }

    /// True when `output` is one of the `sources` or lies inside a source folder, so writing it
    /// would overwrite or change an archive that is being read.
    public static func overlaps(_ output: URL, sources: [URL]) -> Bool {
        let out = output.standardizedFileURL.resolvingSymlinksInPath().path
        return sources.contains { src in
            let s = src.standardizedFileURL.resolvingSymlinksInPath().path
            return out == s || out.hasPrefix(s.hasSuffix("/") ? s : s + "/")
        }
    }

    /// Exports the messages of `stores` that pass `filter` to `url` (overwritten, or appended to
    /// with `append`). Every message gets an `X-Folder` header with its archive and folder.
    /// Messages listed in several folders (search folders) or archives are written once.
    @discardableResult
    public static func export(stores: [any MailStore], filter: MailFilter, to url: URL, append: Bool = false,
                              progress: ((Report) -> Void)? = nil) throws -> Report {
        let fm = FileManager.default
        if !append || !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        // A file that doesn't end in a newline would glue the next "From " line to its last line.
        let end = try handle.seekToEnd()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { try handle.write(contentsOf: Data([0x0A, 0x0A])) }
        }

        var report = Report()
        var seenMessageIDs = Set<String>()
        for store in stores {
            var seenNIDs = Set<UInt32>()
            let archive = store.url.lastPathComponent
            func walk(_ f: Folder, path: String) {
                let location = path.isEmpty ? archive : archive + "/" + path
                if filter.includes(folderPath: path) {
                    let summaries: [MessageSummary]
                    do { summaries = try store.messages(in: f.nid) } catch {
                        report.failures.append("\(location): \(error)")
                        summaries = []
                    }
                    for s in summaries {
                        report.scanned += 1
                        defer { progress?(report) }
                        guard seenNIDs.insert(s.nid).inserted else {
                            report.duplicates += 1
                            continue
                        }
                        do {
                            let m = try store.message(nid: s.nid)
                            guard filter.matches(s) || filter.matches(m, summary: s) else { continue }
                            let id = m.messageID.trimmingCharacters(in: .whitespaces)
                            if !id.isEmpty, seenMessageIDs.contains(id) {
                                report.duplicates += 1
                                continue
                            }
                            try handle.write(contentsOf: EMLWriter.mboxEntry(for: m, headers: [("X-Folder", location)]))
                            // Only now: a copy that failed to export must not hide a readable copy elsewhere.
                            if !id.isEmpty { seenMessageIDs.insert(id) }
                            report.written += 1
                        } catch {
                            let subject = s.subject.isEmpty ? "(no subject)" : s.subject
                            report.failures.append("\(location) / \(subject): \(error)")
                        }
                    }
                }
                for c in f.children {
                    walk(c, path: path.isEmpty ? c.name : path + "/" + c.name)
                }
            }
            walk(try store.rootFolder(), path: "")
        }
        return report
    }
}
