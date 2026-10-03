import Foundation

/// A mail archive in mbox format: one mbox file, or a folder tree of them as written by
/// Netscape Communicator, Mozilla and Thunderbird. In such a tree every mbox file is a
/// mail folder, `Name.sbd/` holds the subfolders of `Name`, and the summary files
/// next to them (`.snm`, `.msf`) are not needed.
public final class MboxArchive: MailStore, @unchecked Sendable {
    public let url: URL
    public let displayName: String

    private struct FolderInfo {
        let name: String
        let file: URL?
        var children: [UInt32]
    }

    struct Entry {
        let offset: Int
        let length: Int
        let summary: MessageSummary
    }

    private struct FolderIndex {
        let data: Data
        let entries: [Entry]
        /// Messages deleted in the mail program but still in the file (until it was compacted).
        let expunged: Int
    }

    private var folders: [UInt32: FolderInfo] = [:]
    private static let rootNID: UInt32 = 0
    /// Message NIDs are `folder << folderShift | index`.
    private static let folderShift: UInt32 = 20
    private static let maxFolders: UInt32 = 1 << (32 - folderShift) - 1

    private let lock = NSLock()
    private var indexes: [UInt32: FolderIndex] = [:]

    public init(url: URL) throws {
        self.url = url
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var root = FolderInfo(name: url.lastPathComponent, file: nil, children: [])
        let fm = FileManager.default
        if isDir.boolValue {
            // An Apple Mail export ("Name.mbox/mbox") is a single folder.
            let inner = url.appendingPathComponent("mbox")
            if url.pathExtension.lowercased() == "mbox", fm.fileExists(atPath: inner.path) {
                displayName = url.deletingPathExtension().lastPathComponent
                root.children = [add(FolderInfo(name: displayName, file: inner, children: []))]
            } else {
                displayName = url.lastPathComponent
                root.children = try scan(url, depth: 0)
            }
        } else {
            let ext = url.pathExtension.lowercased()
            displayName = ["mbox", "mbx"].contains(ext) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            root.children = [add(FolderInfo(name: displayName, file: url, children: []))]
        }
        folders[Self.rootNID] = root
        if root.children.isEmpty {
            throw PSTError.notFound(tr("no mail folders (mbox files) in \(url.lastPathComponent)",
                                       "geen mailmappen (mbox-bestanden) in \(url.lastPathComponent)"))
        }
    }

    /// True when the data starts like an mbox file.
    static func looksLikeMbox(_ head: Data) -> Bool {
        head.starts(with: Array("From ".utf8))
    }

    private func add(_ info: FolderInfo) -> UInt32 {
        let nid = UInt32(folders.count + 1)
        folders[nid] = info
        return nid
    }

    // MARK: Folder tree

    private struct Node {
        let name: String
        let file: URL?
        let children: [Node]
    }

    private func scan(_ dir: URL, depth: Int) throws -> [UInt32] {
        func register(_ nodes: [Node]) -> [UInt32] {
            nodes.compactMap { n in
                guard UInt32(folders.count + 1) < Self.maxFolders else { return nil }
                let nid = add(FolderInfo(name: n.name, file: n.file, children: []))
                let children = register(n.children)
                folders[nid]?.children = children
                return nid
            }
        }
        return register(try scanNodes(dir, depth: depth))
    }

    private func scanNodes(_ dir: URL, depth: Int) throws -> [Node] {
        guard depth < 32 else { return [] }
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                               options: [.skipsHiddenFiles])
        var files: [(String, URL)] = []
        var subfolders: [String: [Node]] = [:]
        var plainDirs: [Node] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let name = item.lastPathComponent
            if values?.isDirectory == true {
                let ext = item.pathExtension.lowercased()
                if ext == "sbd" {
                    subfolders[String(name.dropLast(4)), default: []] += (try? scanNodes(item, depth: depth + 1)) ?? []
                } else if ext == "mbox", fm.fileExists(atPath: item.appendingPathComponent("mbox").path) {
                    let kids = (try? scanNodes(item, depth: depth + 1)) ?? []
                    plainDirs.append(Node(name: item.deletingPathExtension().lastPathComponent, file: item.appendingPathComponent("mbox"), children: kids))
                } else {
                    let kids = (try? scanNodes(item, depth: depth + 1)) ?? []
                    if !kids.isEmpty { plainDirs.append(Node(name: name, file: nil, children: kids)) }
                }
            } else if Self.isMailFile(item, size: values?.fileSize ?? 0) {
                // "mbox" inside an Apple Mail export folder is handled with the folder.
                if name == "mbox" && dir.pathExtension.lowercased() == "mbox" { continue }
                files.append((name, item))
            }
        }
        var nodes: [Node] = files.map { name, file in
            let ext = file.pathExtension.lowercased()
            let display = ["mbox", "mbx"].contains(ext) ? file.deletingPathExtension().lastPathComponent : name
            return Node(name: display, file: file, children: subfolders.removeValue(forKey: name) ?? [])
        }
        // A .sbd folder without a matching mbox file still holds folders.
        for (name, kids) in subfolders where !kids.isEmpty {
            nodes.append(Node(name: name, file: nil, children: kids))
        }
        nodes += plainDirs
        return nodes.sorted(by: Self.folderOrder)
    }

    /// Netscape's order: Inbox, Unsent Messages, Drafts, Templates, Sent, Trash, then the rest by name.
    private static func folderOrder(_ a: Node, _ b: Node) -> Bool {
        func rank(_ n: Node) -> Int {
            switch n.name.lowercased() {
            case "inbox": return 0
            case "unsent messages", "outbox": return 1
            case "drafts": return 2
            case "templates": return 3
            case "sent", "sent mail", "sent items": return 4
            case "trash", "deleted items": return 5
            default: return 10
            }
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Mbox files have no fixed extension; recognise them by content. Empty files without an
    /// extension are empty folders (Netscape keeps those, e.g. "Templates").
    private static func isMailFile(_ url: URL, size: Int) -> Bool {
        let ext = url.pathExtension.lowercased()
        if size == 0 { return ext.isEmpty || ext == "mbox" || ext == "mbx" }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return looksLikeMbox(h.readData(ofLength: 5))
    }

    // MARK: MailStore

    public func rootFolder() throws -> Folder {
        func build(_ nid: UInt32) -> Folder {
            let info = folders[nid]!
            var count = 0, unread = 0
            if info.file != nil, let idx = try? index(nid) {
                count = idx.entries.count
                unread = idx.entries.filter { !$0.summary.isRead }.count
            }
            return Folder(nid: nid, name: info.name, contentCount: count, unreadCount: unread,
                          containerClass: "IPF.Note", children: info.children.map(build))
        }
        return build(Self.rootNID)
    }

    public func messages(in folderNID: UInt32) throws -> [MessageSummary] {
        guard folders[folderNID]?.file != nil else { return [] }
        return try index(folderNID).entries.map(\.summary)
    }

    public func message(nid: UInt32) throws -> Message {
        let folder = nid >> Self.folderShift
        let i = Int(nid & (1 << Self.folderShift - 1))
        let idx = try index(folder)
        guard i < idx.entries.count else { throw PSTError.notFound(tr("message", "bericht")) }
        let e = idx.entries[i]
        let raw = [UInt8](idx.data[e.offset..<(e.offset + e.length)])
        return Message(nid: nid, raw: raw, flags: e.summary.flags & 0x01)
    }

    public var info: [(String, String)] {
        let all = folders.values.compactMap(\.file)
        let size = all.reduce(Int64(0)) { sum, f in
            sum + ((try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        lock.lock()
        let expunged = indexes.values.reduce(0) { $0 + $1.expunged }
        lock.unlock()
        var out = [
            (tr("Folder", "Map"), url.lastPathComponent),
            (tr("Format", "Formaat"), tr("mbox (Netscape, Mozilla, Thunderbird)", "mbox (Netscape, Mozilla, Thunderbird)")),
            (tr("Mail files", "Mailbestanden"), String(all.count)),
            (tr("Size", "Grootte"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file)),
        ]
        if expunged > 0 {
            out.append((tr("Deleted, not compacted", "Verwijderd, niet gecomprimeerd"),
                        tr("\(expunged) message(s), not shown", "\(expunged) bericht(en), niet getoond")))
        }
        return out
    }

    // MARK: Indexing

    private func index(_ folderNID: UInt32) throws -> FolderIndex {
        lock.lock()
        if let idx = indexes[folderNID] { lock.unlock(); return idx }
        lock.unlock()
        guard let file = folders[folderNID]?.file else { throw PSTError.notFound(tr("folder", "map")) }
        let data = try Data(contentsOf: file, options: [.alwaysMapped])
        let (entries, expunged) = Self.scanMessages(data, folderNID: folderNID)
        let idx = FolderIndex(data: data, entries: entries, expunged: expunged)
        lock.lock()
        indexes[folderNID] = idx
        lock.unlock()
        return idx
    }

    /// Finds the messages in an mbox file and reads the headers needed for the message list.
    static func scanMessages(_ data: Data, folderNID: UInt32) -> ([Entry], Int) {
        data.withUnsafeBytes { raw -> ([Entry], Int) in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n > 0 else { return ([], 0) }
            // Classic Mac OS mail programs ended lines with CR only.
            let sample = b[0..<min(n, 65536)]
            let eol: UInt8 = sample.contains(0x0A) ? 0x0A : (sample.contains(0x0D) ? 0x0D : 0x0A)

            func lineEnd(_ from: Int) -> Int {
                var i = from
                while i < n && b[i] != eol { i += 1 }
                return i
            }

            // (separator line start, message start)
            var starts: [(Int, Int)] = []
            var pos = 0
            while pos < n {
                let end = lineEnd(pos)
                if end - pos >= 5, b[pos] == 0x46, b[pos + 1] == 0x72, b[pos + 2] == 0x6F, b[pos + 3] == 0x6D, b[pos + 4] == 0x20,
                   isSeparator(b, line: pos..<end, next: end + 1, eol: eol, lineEnd: lineEnd) {
                    starts.append((pos, min(end + 1, n)))
                }
                pos = end + 1
            }

            var entries: [Entry] = []
            var expunged = 0
            for (k, (sepStart, msgStart)) in starts.enumerated() {
                var msgEnd = k + 1 < starts.count ? starts[k + 1].0 : n
                // The line break before the next "From " line belongs to the separator.
                if msgEnd > msgStart, b[msgEnd - 1] == eol { msgEnd -= 1 }
                if eol == 0x0A, msgEnd > msgStart, b[msgEnd - 1] == 0x0D { msgEnd -= 1 }
                guard msgEnd > msgStart else { continue }

                // Header block: up to the first empty line (at most 256 KB).
                var h = msgStart
                let limit = min(msgEnd, msgStart + 262_144)
                while h < limit {
                    let e = min(lineEnd(h), msgEnd)
                    var len = e - h
                    if eol == 0x0A, len > 0, b[e - 1] == 0x0D { len -= 1 }
                    if len == 0 { break }
                    h = e + 1
                }
                let headerBytes = MIME.normalizeLineEndings(UnsafeBufferPointer(rebasing: b[msgStart..<min(h, msgEnd)]))
                let headers = MIME.parseHeaders(headerBytes[...])
                func value(_ name: String) -> String? {
                    let l = name.lowercased()
                    return headers.first { $0.name.lowercased() == l }?.raw
                }

                var read = true
                if let s = value("X-Mozilla-Status"), let flags = UInt16(s.trimmingCharacters(in: .whitespaces), radix: 16) {
                    if flags & 0x0008 != 0 { expunged += 1; continue }  // deleted, awaiting compaction
                    read = flags & 0x0001 != 0
                } else if let s = value("Status") {
                    read = s.contains("R")
                }

                let separator = String(decoding: UnsafeBufferPointer(rebasing: b[sepStart..<min(lineEnd(sepStart), n)]), as: UTF8.self)
                let date = value("Date").flatMap { MIME.parseDate(MIME.decodeWords($0)) }
                    ?? MIME.parseDate(String(separator.dropFirst(5)))
                let from = value("From").flatMap { MIME.parseAddresses($0).first }
                func names(_ header: String) -> String {
                    headers.filter { $0.name.lowercased() == header }
                        .flatMap { MIME.parseAddresses($0.raw) }
                        .map { $0.name.isEmpty ? $0.email : $0.name }
                        .joined(separator: "; ")
                }
                let (type, _) = MIME.parseContentType(value("Content-Type"))
                let hasAttachments = type == "multipart/mixed" || !(type.isEmpty || type.hasPrefix("text/")
                    || type == "multipart/alternative" || type == "multipart/related")
                var importance = 1
                if let p = value("X-Priority")?.trimmingCharacters(in: .whitespaces).first?.wholeNumberValue {
                    importance = p <= 2 ? 2 : (p >= 4 ? 0 : 1)
                }
                let index = UInt32(entries.count)
                guard index < 1 << folderShift else { break }
                let summary = MessageSummary(
                    nid: folderNID << folderShift | index,
                    subject: MIME.decodeWords(value("Subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    from: from.map { $0.name.isEmpty ? $0.email : $0.name } ?? "",
                    to: names("to"), cc: names("cc"),
                    date: date, size: msgEnd - msgStart,
                    flags: (read ? 0x01 : 0) | (hasAttachments ? 0x10 : 0),
                    messageClass: "IPM.Note", importance: importance)
                entries.append(Entry(offset: msgStart, length: msgEnd - msgStart, summary: summary))
            }
            return (entries, expunged)
        }
    }

    /// A "From " line starts a message when it carries a time (`From - Thu Nov  4 12:00:00 1999`,
    /// `From user@host Thu Nov 4 …`) and the next line is a header field. That rejects
    /// "From " at the start of a line in the text of a message.
    private static func isSeparator(_ b: UnsafeBufferPointer<UInt8>, line: Range<Int>, next: Int, eol: UInt8,
                                    lineEnd: (Int) -> Int) -> Bool {
        var hasTime = false
        var i = line.lowerBound + 5
        while i + 2 < line.upperBound {
            if b[i] == 0x3A, (0x30...0x39).contains(b[i - 1]), (0x30...0x39).contains(b[i + 1]), (0x30...0x39).contains(b[i + 2]) {
                hasTime = true
                break
            }
            i += 1
        }
        guard hasTime else { return false }
        guard next < b.count else { return true }  // a separator at the very end: an empty message
        let end = lineEnd(next)
        var j = next
        while j < end {
            let c = b[j]
            if c == 0x3A { return j > next }
            if c <= 0x20 || c >= 0x7F { return false }
            j += 1
        }
        return false
    }
}
