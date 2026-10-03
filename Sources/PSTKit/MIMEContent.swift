import Foundation

/// What the viewer needs from a MIME message: its text, HTML, attachments and recipients,
/// plus a set of MAPI-like properties so it can be shown like a PST message.
final class MIMEContent: @unchecked Sendable {
    let root: MIMEPart
    private(set) var plain: String?
    private(set) var html: String?
    private(set) var attachments: [Attachment] = []

    init(_ root: MIMEPart) {
        self.root = root
        collect(root, inRelated: false, inAlternative: false)
        if let text = plain {
            plain = extractUUEncoded(text)
        }
    }

    // MARK: Structure

    private func isAttachment(_ p: MIMEPart) -> Bool {
        p.disposition.type == "attachment" || !p.filename.isEmpty
    }

    private func collect(_ p: MIMEPart, inRelated: Bool, inAlternative: Bool) {
        if p.isMultipart {
            let related = inRelated || p.contentType == "multipart/related"
            let alternative = p.contentType == "multipart/alternative"
            for child in p.children { collect(child, inRelated: related, inAlternative: alternative) }
            return
        }
        if p.contentType == "message/rfc822", p.encapsulated != nil {
            addAttachment(p, hidden: false)
            return
        }
        let isText = p.contentType == "text/plain" || p.contentType == "text/html"
        if isText && !isAttachment(p) {
            if p.contentType == "text/html" {
                if html == nil { html = p.text; return }
            } else if plain == nil {
                plain = p.text
                return
            } else if !inAlternative && html == nil {
                // Several inline text parts (e.g. a forwarded message pasted as text): show them all.
                plain! += "\n\n" + p.text
                return
            }
            // A second alternative of something we already have.
            if inAlternative { return }
        }
        addAttachment(p, hidden: inRelated && !p.contentID.isEmpty && !isAttachment(p))
    }

    private func addAttachment(_ p: MIMEPart, hidden: Bool) {
        var name = p.filename
        if name.isEmpty {
            if p.contentType == "message/rfc822", let subject = p.encapsulated?.header("Subject"),
               !subject.trimmingCharacters(in: .whitespaces).isEmpty {
                name = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if p.contentType == "message/rfc822" {
                name = tr("Attached message", "Bijgevoegd bericht")
            } else {
                name = tr("attachment-\(attachments.count + 1)", "bijlage-\(attachments.count + 1)") + Self.fileExtension(for: p.contentType)
            }
        }
        let payload = MIMEPayload(part: p)
        attachments.append(Attachment(
            id: UInt32(attachments.count + 1), filename: name, size: Self.estimatedSize(p),
            method: p.contentType == "message/rfc822" ? 5 : 1, mimeType: p.contentType, contentID: p.contentID,
            isHidden: hidden, node: nil, embeddedNID: nil, payload: payload))
    }

    private static func estimatedSize(_ p: MIMEPart) -> Int {
        switch p.transferEncoding {
        case "base64": return p.rawBody.count * 3 / 4
        default: return p.rawBody.count
        }
    }

    static func fileExtension(for type: String) -> String {
        switch type {
        case "text/plain": return ".txt"
        case "text/html": return ".html"
        case "image/jpeg", "image/pjpeg": return ".jpg"
        case "image/gif": return ".gif"
        case "image/png": return ".png"
        case "application/pdf": return ".pdf"
        case "application/zip", "application/x-zip-compressed": return ".zip"
        case "application/msword": return ".doc"
        case "text/x-vcard", "text/vcard", "text/directory": return ".vcf"
        default: return ""
        }
    }

    /// Moves uuencoded files (`begin 644 name` … `end`) out of the text into attachments,
    /// as pre-MIME mailers attached them.
    private func extractUUEncoded(_ text: String) -> String {
        guard text.contains("begin ") else { return text }
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let parts = line.split(separator: " ", maxSplits: 2)
            if parts.count == 3, parts[0] == "begin", parts[1].count >= 3, parts[1].count <= 4,
               parts[1].allSatisfy({ ("0"..."7").contains($0) }) {
                let rest = lines[(i + 1)...].map { ArraySlice(Array($0.utf8)) }
                let (data, used, complete) = MIME.decodeUULines(ArraySlice(rest))
                if complete {
                    let name = parts[2].trimmingCharacters(in: .whitespaces)
                    attachments.append(Attachment(
                        id: UInt32(attachments.count + 1), filename: name.isEmpty ? "uuencoded" : name, size: data.count,
                        method: 1, mimeType: "application/octet-stream", contentID: "", isHidden: false,
                        node: nil, embeddedNID: nil, payload: MIMEPayload(bytes: data)))
                    out.append(tr("[Attachment: \(name)]", "[Bijlage: \(name)]"))
                    i += 1 + used
                    continue
                }
            }
            out.append(line)
            i += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: Headers

    var recipients: [Recipient] {
        var list: [Recipient] = []
        for (header, kind) in [("To", Recipient.Kind.to), ("Cc", .cc), ("Bcc", .bcc)] {
            for value in root.headers.filter({ $0.name.lowercased() == header.lowercased() }).map(\.raw) {
                for a in MIME.parseAddresses(value) {
                    list.append(Recipient(id: list.count, name: a.name, email: a.email, kind: kind))
                }
            }
        }
        return list
    }

    private func displayList(_ header: String) -> String {
        root.headers.filter { $0.name.lowercased() == header.lowercased() }
            .flatMap { MIME.parseAddresses($0.raw) }
            .map { $0.name.isEmpty ? $0.email : $0.name }
            .joined(separator: "; ")
    }

    var from: MIME.Address? {
        (root.rawHeader("From") ?? root.rawHeader("Sender")).flatMap { MIME.parseAddresses($0).first }
    }

    var date: Date? { root.header("Date").flatMap(MIME.parseDate) }

    var importance: Int {
        let p = (root.header("X-Priority") ?? "").trimmingCharacters(in: .whitespaces)
        if let n = p.first?.wholeNumberValue {
            if n <= 2 { return 2 }
            if n >= 4 { return 0 }
        }
        let i = (root.header("Importance") ?? "").lowercased()
        if i.contains("high") { return 2 }
        if i.contains("low") { return 0 }
        return 1
    }

    /// Properties named like their PST counterparts, so `Message` can read them the same way.
    func properties(size: Int, flags: Int) -> [Property] {
        var props: [Property] = []
        func add(_ id: UInt16, _ v: PropertyValue?) {
            guard let v else { return }
            let type: UInt16
            switch v {
            case .int: type = PropertyValue.PT_LONG
            case .date: type = PropertyValue.PT_SYSTIME
            case .binary: type = PropertyValue.PT_BINARY
            default: type = PropertyValue.PT_UNICODE
            }
            props.append(Property(id: id, type: type, value: v))
        }
        func str(_ s: String?) -> PropertyValue? {
            guard let s, !s.isEmpty else { return nil }
            return .string(s)
        }
        let sender = from
        add(PropID.messageClass, .string("IPM.Note"))
        add(PropID.subject, str(root.header("Subject")?.trimmingCharacters(in: .whitespacesAndNewlines)))
        add(PropID.sentRepresentingName, str(sender.map { $0.name.isEmpty ? $0.email : $0.name }))
        add(PropID.senderName, str(sender.map { $0.name.isEmpty ? $0.email : $0.name }))
        add(PropID.sentRepresentingEmail, str(sender?.email))
        add(PropID.senderEmail, str(sender?.email))
        add(PropID.displayTo, str(displayList("To")))
        add(PropID.displayCc, str(displayList("Cc")))
        add(PropID.displayBcc, str(displayList("Bcc")))
        if let d = date {
            add(PropID.messageDeliveryTime, .date(d))
            add(PropID.clientSubmitTime, .date(d))
        }
        add(PropID.messageFlags, .int(Int64(flags | (attachments.contains { !$0.isHidden } ? 0x10 : 0))))
        add(PropID.messageSize, .int(Int64(size)))
        add(PropID.importance, .int(Int64(importance)))
        add(PropID.internetMessageID, str(root.header("Message-ID")?.trimmingCharacters(in: .whitespaces)))
        add(PropID.transportHeaders, str(root.headerText))
        add(PropID.body, str(plain ?? html.map(HTMLText.toPlain)))
        add(PropID.html, str(html))
        return props
    }
}
