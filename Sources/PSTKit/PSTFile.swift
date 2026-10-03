import Foundation

/// Well-known property-set GUIDs for named properties.
public enum PropertySet {
    public static let common = "{00062008-0000-0000-C000-000000000046}"
    public static let address = "{00062004-0000-0000-C000-000000000046}"
    public static let appointment = "{00062002-0000-0000-C000-000000000046}"
    public static let task = "{00062003-0000-0000-C000-000000000046}"
    public static let mapi = "{00020328-0000-0000-C000-000000000046}"
    public static let publicStrings = "{00020329-0000-0000-C000-000000000046}"
}

/// An opened PST/OST file.
public final class PSTFile: @unchecked Sendable {
    public let url: URL
    let ndb: NDB
    public var format: PSTFormat { ndb.format }
    public var encryption: String {
        switch ndb.cryptMethod {
        case 0: return "geen"
        case 1: return "compressible"
        default: return "high"
        }
    }

    /// Display name of the message store (e.g. "Persoonlijke mappen").
    public private(set) var displayName: String = ""
    public private(set) var rootFolderNID: UInt32 = 0x122

    /// Named property map: (guid, lid or name) -> local property id (0x8000+).
    private var namedByLID: [String: [UInt32: UInt16]] = [:]
    private var namedByName: [String: [String: UInt16]] = [:]
    private var namedReverse: [UInt16: String] = [:]

    public init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        ndb = try NDB(data: data)
        if let store = try? propertyContext(nid: 0x21) {
            displayName = store.value(PropID.displayName)?.stringValue(codepage: PSTText.defaultCodepage) ?? ""
        }
        if displayName.isEmpty { displayName = url.deletingPathExtension().lastPathComponent }
        loadNameMap()
    }

    public var nodeCount: Int { ndb.nodeCount }

    // MARK: - Nodes

    func node(_ nid: UInt32) -> NodeRef? {
        guard let e = ndb.nodes[nid] else { return nil }
        return NodeRef(ndb: ndb, nid: nid, bidData: e.bidData, bidSub: e.bidSub)
    }

    func propertyContext(nid: UInt32) throws -> PropertyContext {
        guard let n = node(nid) else { throw PSTError.notFound("node 0x\(String(nid, radix: 16))") }
        return try PropertyContext(n)
    }

    func table(nid: UInt32) throws -> TableContext {
        guard let n = node(nid) else { throw PSTError.notFound("tabel 0x\(String(nid, radix: 16))") }
        return try TableContext(n)
    }

    // MARK: - Named properties

    private func loadNameMap() {
        guard let pc = try? propertyContext(nid: 0x61) else { return }
        let guids = pc.value(0x0002)?.bytesValue ?? []
        let entries = pc.value(0x0003)?.bytesValue ?? []
        let strings = pc.value(0x0004)?.bytesValue ?? []
        var o = 0
        while o + 8 <= entries.count {
            let idOrOffset = entries.u32(o)
            let guidField = entries.u16(o + 4)
            let propIndex = entries.u16(o + 6)
            o += 8
            let isString = guidField & 1 == 1
            let guidIndex = Int(guidField >> 1)
            let guid: String
            switch guidIndex {
            case 1: guid = PropertySet.mapi
            case 2: guid = PropertySet.publicStrings
            default:
                let go = (guidIndex - 3) * 16
                guard go >= 0, go + 16 <= guids.count else { continue }
                guid = PSTText.guidString(Array(guids[go..<(go + 16)]))
            }
            let localID = 0x8000 &+ propIndex
            if isString {
                let so = Int(idOrOffset)
                let len = Int(strings.u32(so))
                let name = PSTText.utf16(strings.slice(so + 4, len))
                namedByName[guid, default: [:]][name] = localID
                namedReverse[localID] = name
            } else {
                namedByLID[guid, default: [:]][idOrOffset] = localID
                namedReverse[localID] = String(format: "%@ 0x%04X", NamedNames.setName(guid), idOrOffset)
            }
        }
    }

    /// Local property id for a named property (numeric LID).
    public func namedID(_ guid: String, _ lid: UInt32) -> UInt16? { namedByLID[guid]?[lid] }

    /// Local property id for a named property (string name).
    public func namedID(_ guid: String, name: String) -> UInt16? { namedByName[guid]?[name] }

    public func propertyName(_ id: UInt16) -> String {
        if id >= 0x8000, let n = namedReverse[id] { return n }
        return PropertyNames.name(for: id)
    }

    // MARK: - Folders

    /// Loads the complete folder tree, starting at the root folder.
    public func rootFolder() throws -> Folder {
        var visited = Set<UInt32>()
        return try loadFolder(nid: rootFolderNID, depth: 0, visited: &visited)
    }

    private func loadFolder(nid: UInt32, depth: Int, visited: inout Set<UInt32>) throws -> Folder {
        visited.insert(nid)
        let pc = try propertyContext(nid: nid)
        let cp = PSTText.defaultCodepage
        let name = pc.value(PropID.displayName)?.stringValue(codepage: cp) ?? ""
        var folder = Folder(
            nid: nid,
            name: name,
            contentCount: Int(pc.value(PropID.contentCount)?.intValue ?? 0),
            unreadCount: Int(pc.value(PropID.contentUnread)?.intValue ?? 0),
            containerClass: pc.value(PropID.containerClass)?.stringValue(codepage: cp) ?? "",
            children: []
        )
        guard depth < 64 else { return folder }
        let hierarchyNID = (nid & ~0x1F) | 0x0D
        var childNIDs: [UInt32] = []
        if let tc = try? table(nid: hierarchyNID) {
            childNIDs = tc.rows().map(\.rowID)
        }
        if childNIDs.isEmpty {
            // Fallback: use parent pointers from the node index.
            childNIDs = ndb.children(of: nid)
                .filter { $0.nid != nid && ($0.nid & 0x1F) == 0x02 }
                .map(\.nid)
                .sorted()
        }
        for child in childNIDs where !visited.contains(child) && ndb.nodes[child] != nil {
            if let f = try? loadFolder(nid: child, depth: depth + 1, visited: &visited) {
                folder.children.append(f)
            }
        }
        return folder
    }

    // MARK: - Messages

    /// Lists the messages of a folder using its contents table.
    public func messages(in folderNID: UInt32) throws -> [MessageSummary] {
        let contentsNID = (folderNID & ~0x1F) | 0x0E
        var result: [MessageSummary] = []
        var seen = Set<UInt32>()
        if let tc = try? table(nid: contentsNID) {
            for row in tc.rows() {
                let nid = row.rowID
                guard ndb.nodes[nid] != nil, seen.insert(nid).inserted else { continue }
                let cp = Int(row[PropID.messageCodepage]?.intValue ?? row[PropID.internetCodepage]?.intValue ?? Int64(PSTText.defaultCodepage))
                func str(_ id: UInt16) -> String { row[id]?.stringValue(codepage: cp) ?? "" }
                let flags = Int(row[PropID.messageFlags]?.intValue ?? 0)
                var summary = MessageSummary(
                    nid: nid,
                    subject: PSTText.cleanSubject(str(PropID.subject)),
                    from: str(PropID.sentRepresentingName),
                    to: str(PropID.displayTo),
                    date: row[PropID.messageDeliveryTime]?.dateValue ?? row[PropID.clientSubmitTime]?.dateValue
                        ?? row[PropID.lastModificationTime]?.dateValue,
                    size: Int(row[PropID.messageSize]?.intValue ?? 0),
                    flags: flags,
                    messageClass: str(PropID.messageClass),
                    importance: Int(row[PropID.importance]?.intValue ?? 1)
                )
                if summary.from.isEmpty { summary.from = str(PropID.senderName) }
                if summary.subject.isEmpty && summary.from.isEmpty, let m = try? message(nid: nid) {
                    // Sparse contents table: fall back to the message itself.
                    summary = m.summary
                }
                result.append(summary)
            }
        }
        // Fallback / supplement: messages whose parent is this folder but that are missing from the table.
        let orphaned = ndb.children(of: folderNID).filter {
            ($0.nid & 0x1F) == 0x04 && !seen.contains($0.nid)
        }
        for e in orphaned.sorted(by: { $0.nid < $1.nid }) {
            if let m = try? message(nid: e.nid) { result.append(m.summary) }
        }
        return result
    }

    /// Loads the full message.
    public func message(nid: UInt32) throws -> Message {
        guard let n = node(nid) else { throw PSTError.notFound("bericht") }
        return try Message(file: self, node: n)
    }

    /// Loads the message embedded in an attachment (attach method 5).
    public func embeddedMessage(_ attachment: Attachment) throws -> Message? {
        guard let node = attachment.embeddedNode else { return nil }
        return try Message(file: self, node: node)
    }

    /// Reads the binary content of an attachment.
    public func attachmentData(_ attachment: Attachment) throws -> Data {
        let pc = try PropertyContext(attachment.node)
        switch pc.value(PropID.attachData) {
        case .binary(let b)?: return Data(b)
        case .object(let nid, _)?:
            // OLE / embedded object stored in a subnode.
            guard let sub = try attachment.node.subnode(nid) else {
                throw PSTError.corrupt("gegevens van bijlage '\(attachment.filename)' ontbreken")
            }
            return Data(try ndb.dataStream(sub.bidData))
        default:
            // By-reference attachments (methods 2, 3, 4 and 7) only point to a file elsewhere.
            if [2, 3, 4, 7].contains(attachment.method) { return Data() }
            throw PSTError.corrupt("gegevens van bijlage '\(attachment.filename)' ontbreken")
        }
    }

    /// Statistics shown in the "file info" panel.
    public var info: [(String, String)] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? Int64(ndb.data.count)
        return [
            ("Bestand", url.lastPathComponent),
            ("Formaat", format.rawValue),
            ("Versleuteling", encryption),
            ("Grootte", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)),
            ("Nodes", String(ndb.nodeCount)),
            ("Blokken", String(ndb.blockCount)),
        ]
    }
}

enum NamedNames {
    static func setName(_ guid: String) -> String {
        switch guid {
        case PropertySet.common: return "PSETID_Common"
        case PropertySet.address: return "PSETID_Address"
        case PropertySet.appointment: return "PSETID_Appointment"
        case PropertySet.task: return "PSETID_Task"
        case PropertySet.mapi: return "PS_MAPI"
        case PropertySet.publicStrings: return "PS_PUBLIC_STRINGS"
        default: return guid
        }
    }
}

// MARK: - Model types

public struct Folder: Identifiable, Hashable, Sendable {
    public let nid: UInt32
    public let name: String
    public let contentCount: Int
    public let unreadCount: Int
    public let containerClass: String
    public var children: [Folder]

    public var id: UInt32 { nid }
    /// `nil` for leaf folders so SwiftUI's outline views don't show a disclosure triangle.
    public var childrenOrNil: [Folder]? { children.isEmpty ? nil : children }

    public var totalCount: Int { contentCount + children.reduce(0) { $0 + $1.totalCount } }

    public var kind: FolderKind {
        let c = containerClass.lowercased()
        if c.hasPrefix("ipf.contact") { return .contacts }
        if c.hasPrefix("ipf.appointment") { return .calendar }
        if c.hasPrefix("ipf.task") { return .tasks }
        if c.hasPrefix("ipf.stickynote") { return .notes }
        if c.hasPrefix("ipf.journal") { return .journal }
        let n = name.lowercased()
        if ["inbox", "postvak in", "postvak in "].contains(n) { return .inbox }
        if ["sent items", "verzonden items", "sent"].contains(n) { return .sent }
        if ["deleted items", "verwijderde items", "trash"].contains(n) { return .trash }
        if ["drafts", "concepten"].contains(n) { return .drafts }
        if ["outbox", "postvak uit"].contains(n) { return .outbox }
        if ["junk e-mail", "ongewenste e-mail", "junk email", "spam"].contains(n) { return .junk }
        return .mail
    }

    /// Flattened list of this folder and all descendants.
    public var allFolders: [Folder] { [self] + children.flatMap(\.allFolders) }
}

public enum FolderKind: Sendable {
    case mail, inbox, sent, trash, drafts, outbox, junk, contacts, calendar, tasks, notes, journal
}

public struct MessageSummary: Identifiable, Hashable, Sendable {
    public let nid: UInt32
    public var subject: String
    public var from: String
    public var to: String
    public var date: Date?
    public var size: Int
    public var flags: Int
    public var messageClass: String
    public var importance: Int

    public var id: UInt32 { nid }
    public var isRead: Bool { flags & 0x01 != 0 }
    public var hasAttachments: Bool { flags & 0x10 != 0 }
    public var isUnsent: Bool { flags & 0x08 != 0 }

    public var kind: ItemKind { ItemKind(messageClass: messageClass) }

    /// Sort keys usable by SwiftUI Table (non-optional).
    public var sortDate: Date { date ?? .distantPast }
    public var sortSubject: String { subject.lowercased() }
    public var sortFrom: String { from.lowercased() }
}

public enum ItemKind: Sendable {
    case mail, contact, appointment, task, note, distributionList, meetingRequest, report, other

    init(messageClass: String) {
        let c = messageClass.lowercased()
        if c.isEmpty || c.hasPrefix("ipm.note") || c == "ipm" || c.hasPrefix("ipm.post") { self = .mail }
        else if c.hasPrefix("ipm.contact") { self = .contact }
        else if c.hasPrefix("ipm.distlist") { self = .distributionList }
        else if c.hasPrefix("ipm.appointment") { self = .appointment }
        else if c.hasPrefix("ipm.schedule.meeting") { self = .meetingRequest }
        else if c.hasPrefix("ipm.task") { self = .task }
        else if c.hasPrefix("ipm.stickynote") { self = .note }
        else if c.hasPrefix("report.") { self = .report }
        else { self = .other }
    }
}

extension PSTFile {
    /// Human-readable dump of a table context (debugging aid used by `pstdump --table`).
    public func debugTable(nid: UInt32) -> String {
        guard let tc = try? table(nid: nid) else { return "geen tabel" }
        var out = "rows=\(tc.rowCount) rowSize=\(tc.rowSize) ceb=\(tc.cebOffset)\n"
        for c in tc.columns {
            out += String(format: "  col 0x%08X off=%d size=%d bit=%d %@\n", c.tag, c.offset, c.size, c.bit, propertyName(c.id))
        }
        for i in 0..<min(tc.rowCount, 5) {
            if let b = tc.rowBytes(i) { out += "  raw: " + b.map { String(format: "%02x", $0) }.joined() + "\n" }
            if let r = tc.row(i) {
                for (k, v) in r.values.sorted(by: { $0.key < $1.key }) {
                    out += "    \(propertyName(k)) = \(String(v.description.prefix(80)))\n"
                }
            }
        }
        return out
    }
}
