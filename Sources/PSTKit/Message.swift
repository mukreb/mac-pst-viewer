import Foundation

public struct Recipient: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable { case to = 1, cc = 2, bcc = 3, other = 0 }
    public let id: Int
    public let name: String
    public let email: String
    public let kind: Kind

    public var display: String {
        if email.isEmpty || email == name { return name.isEmpty ? email : name }
        if name.isEmpty { return email }
        return "\(name) <\(email)>"
    }
}

public struct Attachment: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let filename: String
    public let size: Int
    public let method: Int
    public let mimeType: String
    public let contentID: String
    public let isHidden: Bool
    let node: NodeRef
    let embeddedNID: UInt32?

    public var isEmbeddedMessage: Bool { method == 5 && embeddedNID != nil }
    /// Attach-by-reference (methods 2, 3, 4, 7): only a link to a file outside the PST.
    public var isExternalReference: Bool { [2, 3, 4, 7].contains(method) }

    var embeddedNode: NodeRef? {
        guard let nid = embeddedNID else { return nil }
        return try? node.subnode(nid)
    }

    public static func == (a: Attachment, b: Attachment) -> Bool { a.id == b.id && a.node.bidData == b.node.bidData }
    public func hash(into h: inout Hasher) { h.combine(id); h.combine(node.bidData) }
}

extension NodeRef: @unchecked Sendable {}

public enum MessageBody {
    case html(String)
    case rtf(Data)
    case text(String)
}

/// A fully loaded message (or contact, appointment, ...).
public final class Message: @unchecked Sendable {
    public let nid: UInt32
    let file: PSTFile
    let node: NodeRef
    let pc: PropertyContext
    public let codepage: Int

    init(file: PSTFile, node: NodeRef) throws {
        self.file = file
        self.node = node
        nid = node.nid
        pc = try PropertyContext(node)
        codepage = Int(pc.value(PropID.messageCodepage)?.intValue
            ?? pc.value(PropID.internetCodepage)?.intValue
            ?? Int64(PSTText.defaultCodepage))
    }

    func string(_ id: UInt16) -> String {
        pc.value(id)?.stringValue(codepage: codepage)?.trimmingCharacters(in: .controlCharacters) ?? ""
    }

    public func value(_ id: UInt16) -> PropertyValue? { pc.value(id) }

    public func named(_ guid: String, _ lid: UInt32) -> PropertyValue? {
        guard let id = file.namedID(guid, lid) else { return nil }
        return pc.value(id)
    }

    /// Set when a body property (text, HTML or RTF) exists but cannot be read.
    public var bodyError: String? {
        for (id, label) in [(PropID.body, tr("text", "tekst")), (PropID.html, "HTML"), (PropID.rtfCompressed, "RTF")] {
            do { _ = try pc.decodedValue(id) } catch { return tr("message body (\(label)) cannot be read (\(error))", "berichttekst (\(label)) kan niet worden gelezen (\(error))") }
        }
        // Compressed RTF that cannot be fully decompressed would otherwise export truncated.
        if case .binary(let b)? = pc.value(PropID.rtfCompressed), !b.isEmpty, RTF.decompress(b) == nil {
            return tr("message body (RTF) is damaged", "berichttekst (RTF) is beschadigd")
        }
        return nil
    }

    public var subject: String { PSTText.cleanSubject(string(PropID.subject)) }
    public var messageClass: String { string(PropID.messageClass) }
    public var kind: ItemKind { ItemKind(messageClass: messageClass) }

    public var fromName: String {
        let n = string(PropID.sentRepresentingName)
        return n.isEmpty ? string(PropID.senderName) : n
    }

    public var fromEmail: String {
        for id in [PropID.sentRepresentingSMTP, PropID.senderSMTP, PropID.sentRepresentingEmail, PropID.senderEmail] {
            let e = string(id)
            if e.contains("@") { return e }
        }
        // Exchange (EX) addresses: try to find the SMTP address in the transport headers.
        if let from = headerValue("From") { return from }
        return ""
    }

    public var from: String {
        let n = fromName, e = fromEmail
        if e.isEmpty || e == n { return n }
        if n.isEmpty { return e }
        if e.contains("<") { return e }
        return "\(n) <\(e)>"
    }

    public var displayTo: String { string(PropID.displayTo) }
    public var displayCc: String { string(PropID.displayCc) }
    public var displayBcc: String { string(PropID.displayBcc) }

    public var date: Date? {
        pc.value(PropID.messageDeliveryTime)?.dateValue ?? pc.value(PropID.clientSubmitTime)?.dateValue
            ?? pc.value(PropID.lastModificationTime)?.dateValue
    }

    public var sentDate: Date? { pc.value(PropID.clientSubmitTime)?.dateValue }
    public var flags: Int { Int(pc.value(PropID.messageFlags)?.intValue ?? 0) }
    public var importance: Int { Int(pc.value(PropID.importance)?.intValue ?? 1) }
    public var messageID: String { string(PropID.internetMessageID) }

    public var transportHeaders: String { string(PropID.transportHeaders) }

    func headerValue(_ name: String) -> String? {
        let headers = transportHeaders
        guard !headers.isEmpty else { return nil }
        let prefix = name.lowercased() + ":"
        var value: String?
        for line in headers.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if value != nil {
                if l.hasPrefix(" ") || l.hasPrefix("\t") { value! += " " + l.trimmingCharacters(in: .whitespaces); continue }
                break
            }
            if l.lowercased().hasPrefix(prefix) {
                value = String(l.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    public var summary: MessageSummary {
        MessageSummary(nid: nid, subject: subject, from: fromName, to: displayTo, cc: displayCc, date: date,
                       size: Int(pc.value(PropID.messageSize)?.intValue ?? 0), flags: flags,
                       messageClass: messageClass, importance: importance)
    }

    // MARK: Recipients

    public var recipients: [Recipient] { recipientLoad.list }

    /// Set when a recipient table exists but cannot be read; exports report it instead of
    /// silently falling back to the display-only To/Cc fields.
    public var recipientError: String? { recipientLoad.error }

    private lazy var recipientLoad: (list: [Recipient], error: String?) = {
        let table: NodeRef?
        do { table = try node.subnode(0x692) } catch { return ([], tr("recipients cannot be found (\(error))", "ontvangers kunnen niet worden gevonden (\(error))")) }
        guard let sub = table else { return ([], nil) }  // no recipient table
        let tc: TableContext
        do { tc = try TableContext(sub) } catch { return ([], tr("recipient table cannot be read (\(error))", "ontvangerstabel kan niet worden gelezen (\(error))")) }
        let rows = tc.rows()
        if rows.contains(where: { $0.failedCells > 0 }) {
            return ([], tr("a recipient's data cannot be read", "gegevens van een ontvanger kunnen niet worden gelezen"))
        }
        let list = rows.enumerated().map { i, row -> Recipient in
            let name = row[PropID.displayName]?.stringValue(codepage: codepage) ?? ""
            var email = row[PropID.smtpAddress]?.stringValue(codepage: codepage) ?? ""
            if email.isEmpty { email = row[PropID.emailAddress]?.stringValue(codepage: codepage) ?? "" }
            if !email.contains("@") { email = "" } // hide Exchange DNs like /O=ORG/OU=...
            let kind = Recipient.Kind(rawValue: Int(row[PropID.recipientType]?.intValue ?? 1) & 0x0F) ?? .other
            return Recipient(id: i, name: name, email: email, kind: kind)
        }
        return (list, nil)
    }()

    public func recipients(_ kind: Recipient.Kind) -> [Recipient] { recipients.filter { $0.kind == kind } }

    public var to: String {
        let r = recipients(.to)
        return r.isEmpty ? displayTo : r.map(\.display).joined(separator: ", ")
    }

    public var cc: String {
        let r = recipients(.cc)
        return r.isEmpty ? displayCc : r.map(\.display).joined(separator: ", ")
    }

    public var bcc: String {
        let r = recipients(.bcc)
        return r.isEmpty ? displayBcc : r.map(\.display).joined(separator: ", ")
    }

    // MARK: Attachments

    public var attachments: [Attachment] { attachmentLoad.list }

    /// Attachments that are listed in the attachment table but could not be decoded.
    /// Exports treat these as failures instead of silently dropping them.
    public var attachmentErrors: [String] { attachmentLoad.errors }

    private lazy var attachmentLoad: (list: [Attachment], errors: [String]) = {
        let table: NodeRef?
        do { table = try node.subnode(0x671) } catch {
            return ([], [tr("attachments cannot be found (\(error))", "bijlagen kunnen niet worden gevonden (\(error))")])
        }
        guard let sub = table else { return ([], []) }  // no attachment table: no attachments
        guard let tc = try? TableContext(sub) else { return ([], [tr("attachment table cannot be read", "bijlagentabel kan niet worden gelezen")]) }
        var result: [Attachment] = []
        var errors: [String] = []
        for row in tc.rows() {
            guard let attNode = try? node.subnode(row.rowID), let apc = try? PropertyContext(attNode) else {
                errors.append(tr("attachment \(result.count + errors.count + 1) cannot be read", "bijlage \(result.count + errors.count + 1) kan niet worden gelezen"))
                continue
            }
            func s(_ id: UInt16) -> String { apc.value(id)?.stringValue(codepage: codepage) ?? "" }
            var name = s(PropID.attachLongFilename)
            if name.isEmpty { name = s(PropID.attachFilename) }
            if name.isEmpty { name = s(PropID.displayName) }
            let method = Int(apc.value(PropID.attachMethod)?.intValue ?? 1)
            var embedded: UInt32?
            if case .object(let enid, _)? = apc.value(PropID.attachData) { embedded = enid }
            if name.isEmpty {
                name = method == 5 ? tr("Attached message", "Bijgevoegd bericht") : tr("attachment-\(result.count + 1)", "bijlage-\(result.count + 1)")
            }
            var size = Int(apc.value(PropID.attachSize)?.intValue ?? 0)
            if case .binary(let b)? = apc.value(PropID.attachData) { size = b.count }
            result.append(Attachment(
                id: row.rowID,
                filename: name.trimmingCharacters(in: .controlCharacters),
                size: size,
                method: method,
                mimeType: s(PropID.attachMimeTag),
                contentID: s(PropID.attachContentID),
                isHidden: apc.value(PropID.attachmentHidden)?.intValue == 1,
                node: attNode,
                embeddedNID: method == 5 ? embedded : nil
            ))
        }
        return (result, errors)
    }()

    public func data(for attachment: Attachment) throws -> Data {
        try file.attachmentData(attachment)
    }

    public func embeddedMessage(_ attachment: Attachment) throws -> Message? {
        guard let n = attachment.embeddedNode else { return nil }
        return try Message(file: file, node: n)
    }

    // MARK: Body

    public var plainBody: String {
        let b = string(PropID.body)
        if !b.isEmpty { return b }
        if let rtf = rtfBody {
            if RTF.isEncapsulatedHTML(rtf) { return HTMLText.toPlain(RTF.extractHTML(rtf)) }
            return RTF.plainText(rtf)
        }
        if let h = htmlBody { return HTMLText.toPlain(h) }
        return ""
    }

    public var htmlBody: String? {
        switch pc.value(PropID.html) {
        case .binary(let b)?:
            guard !b.isEmpty else { return nil }
            let cp = Int(pc.value(PropID.internetCodepage)?.intValue ?? 0)
            return HTMLText.decode(b, codepage: cp == 0 ? codepage : cp)
        case .string(let s)?: return s.isEmpty ? nil : s
        case .string8(let b)?: return PSTText.decode(b, codepage: codepage)
        default: return nil
        }
    }

    public lazy var rtfBody: [UInt8]? = {
        guard case .binary(let b)? = pc.value(PropID.rtfCompressed), !b.isEmpty else { return nil }
        return RTF.decompress(b)
    }()

    /// The richest available body representation.
    public lazy var body: MessageBody = {
        if let h = htmlBody { return .html(h) }
        if let rtf = rtfBody {
            if RTF.isEncapsulatedHTML(rtf) { return .html(RTF.extractHTML(rtf)) }
            if !RTF.isEncapsulatedText(rtf) { return .rtf(Data(rtf)) }
        }
        return .text(plainBody)
    }()

    // MARK: Properties

    public var allProperties: [Property] { pc.all() }

    public func propertyName(_ id: UInt16) -> String { file.propertyName(id) }

    /// Type-specific fields (contacts, appointments, tasks) as label/value pairs.
    public var details: [(String, String)] {
        var out: [(String, String)] = []
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        df.locale = Localization.locale
        func add(_ label: String, _ v: PropertyValue?) {
            guard let v else { return }
            let s: String
            if let d = v.dateValue { s = df.string(from: d) } else { s = v.stringValue(codepage: codepage) ?? "" }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append((label, t)) }
        }
        switch kind {
        case .contact:
            add(tr("Name", "Naam"), pc.value(PropID.displayName))
            add(tr("First name", "Voornaam"), pc.value(PropID.givenName))
            add(tr("Last name", "Achternaam"), pc.value(PropID.surname))
            add(tr("Company", "Bedrijf"), pc.value(PropID.companyName))
            add(tr("Job title", "Functie"), pc.value(PropID.title))
            add(tr("Department", "Afdeling"), pc.value(PropID.department))
            add(tr("Email", "E-mail"), named(PropertySet.address, 0x8083))
            add(tr("Email 2", "E-mail 2"), named(PropertySet.address, 0x8093))
            add(tr("Email 3", "E-mail 3"), named(PropertySet.address, 0x80A3))
            add(tr("Work phone", "Telefoon werk"), pc.value(PropID.businessPhone))
            add(tr("Home phone", "Telefoon thuis"), pc.value(PropID.homePhone))
            add(tr("Mobile", "Mobiel"), pc.value(PropID.mobilePhone))
            add(tr("Work fax", "Fax werk"), pc.value(PropID.businessFax))
            add(tr("Work address", "Adres werk"), pc.value(PropID.businessAddressStreet))
            add(tr("Work city", "Plaats werk"), pc.value(PropID.businessAddressCity))
            add(tr("Home address", "Adres thuis"), pc.value(PropID.homeStreet))
            add(tr("Home city", "Plaats thuis"), pc.value(PropID.homeCity))
            add(tr("Website", "Website"), pc.value(PropID.businessHomePage))
            add(tr("Birthday", "Verjaardag"), pc.value(PropID.birthday))
        case .appointment, .meetingRequest:
            add(tr("Start", "Begin"), named(PropertySet.appointment, 0x820D) ?? pc.value(PropID.startDate))
            add(tr("End", "Einde"), named(PropertySet.appointment, 0x820E) ?? pc.value(PropID.endDate))
            add(tr("Location", "Locatie"), named(PropertySet.appointment, 0x8208))
            add(tr("Organizer", "Organisator"), pc.value(PropID.sentRepresentingName))
        case .task:
            add(tr("Start date", "Begindatum"), named(PropertySet.task, 0x8104))
            add(tr("Due date", "Einddatum"), named(PropertySet.task, 0x8105))
            if let pct = named(PropertySet.task, 0x8102), case .double(let d) = pct {
                out.append((tr("Complete", "Voltooid"), "\(Int(d * 100))%"))
            }
        case .distributionList:
            add(tr("Name", "Naam"), named(PropertySet.address, 0x8053))
        default:
            break
        }
        return out
    }
}
