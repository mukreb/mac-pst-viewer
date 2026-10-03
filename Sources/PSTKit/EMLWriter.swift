import Foundation

/// Builds RFC 5322 / MIME (.eml) messages and mbox files from PST messages.
public enum EMLWriter {
    public static func eml(for m: Message) throws -> Data {
        var out = ""
        let boundaryMixed = "----=_PSTViewer_mixed_\(m.nid)"
        let boundaryAlt = "----=_PSTViewer_alt_\(m.nid)"

        out += "From: \(address(name: m.fromName, email: m.fromEmail))\r\n"
        for (name, kind, display) in [("To", Recipient.Kind.to, m.displayTo), ("Cc", .cc, m.displayCc), ("Bcc", .bcc, m.displayBcc)] {
            let list = m.recipients(kind)
            if !list.isEmpty {
                out += "\(name): " + list.map { address(name: $0.name, email: $0.email) }.joined(separator: ",\r\n ") + "\r\n"
            } else if !display.isEmpty {
                out += header(name, display)
            }
        }
        out += header("Subject", m.subject)
        if let d = m.sentDate ?? m.date { out += "Date: \(rfc2822(d))\r\n" }
        if !m.messageID.isEmpty { out += "Message-ID: \(m.messageID)\r\n" }
        out += "X-PST-Message-Class: \(m.messageClass)\r\n"
        out += "MIME-Version: 1.0\r\n"

        let text = m.plainBody
        var html: String? = nil
        if case .html(let h) = m.body { html = h }
        let attachments = m.attachments

        var bodyPart = ""
        if let html {
            bodyPart += "Content-Type: multipart/alternative; boundary=\"\(boundaryAlt)\"\r\n\r\n"
            bodyPart += "--\(boundaryAlt)\r\n" + textPart(text, subtype: "plain")
            bodyPart += "--\(boundaryAlt)\r\n" + textPart(html, subtype: "html")
            bodyPart += "--\(boundaryAlt)--\r\n"
        } else {
            bodyPart += textPart(text, subtype: "plain")
        }

        if attachments.isEmpty {
            out += bodyPart
        } else {
            out += "Content-Type: multipart/mixed; boundary=\"\(boundaryMixed)\"\r\n\r\n"
            out += "This is a multi-part message in MIME format.\r\n\r\n"
            out += "--\(boundaryMixed)\r\n" + bodyPart
            for a in attachments {
                out += "\r\n--\(boundaryMixed)\r\n"
                if a.isEmbeddedMessage, let em = try? m.embeddedMessage(a) {
                    out += "Content-Type: message/rfc822\r\n"
                    out += "Content-Disposition: attachment; filename=\(quotedParam(safeName(a.filename) + ".eml"))\r\n\r\n"
                    out += String(decoding: try eml(for: em), as: UTF8.self)
                } else {
                    // Fail loudly rather than export a silently empty attachment.
                    let data: Data
                    do { data = try m.data(for: a) } catch {
                        throw PSTError.corrupt("bijlage '\(a.filename)' kan niet worden gelezen (\(error))")
                    }
                    let mimeTag = a.mimeType.components(separatedBy: .whitespacesAndNewlines).joined()
                    let mime = mimeTag.contains("/") ? mimeTag : "application/octet-stream"
                    out += "Content-Type: \(mime); name=\(quotedParam(a.filename))\r\n"
                    out += "Content-Transfer-Encoding: base64\r\n"
                    let cid = a.contentID.components(separatedBy: .whitespacesAndNewlines).joined()
                        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    if !cid.isEmpty { out += "Content-ID: <\(cid)>\r\n" }
                    out += "Content-Disposition: \(a.contentID.isEmpty ? "attachment" : "inline"); filename=\(quotedParam(a.filename))\r\n\r\n"
                    out += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                    out += "\r\n"
                }
            }
            out += "\r\n--\(boundaryMixed)--\r\n"
        }
        return Data(out.utf8)
    }

    /// Appends messages to mbox format (mboxrd quoting).
    public static func mboxEntry(for m: Message) throws -> Data {
        let eml = String(decoding: try eml(for: m), as: UTF8.self)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
        let sender = m.fromEmail.contains("@") ? m.fromEmail.replacingOccurrences(of: " ", with: "") : "MAILER-DAEMON"
        var out = "From \(sender) \(df.string(from: m.date ?? Date(timeIntervalSince1970: 0)))\n"
        for line in eml.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var l = line
            var probe = Substring(l)
            while probe.hasPrefix(">") { probe = probe.dropFirst() }
            if probe.hasPrefix("From ") { l = ">" + l }
            out += l + "\n"
        }
        out += "\n"
        return Data(out.utf8)
    }

    public static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        var r = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        // Avoid "." / ".." path components and hidden files.
        let dots = r.prefix { $0 == "." }.count
        r = String(repeating: "_", count: dots) + r.dropFirst(dots)
        if r.isEmpty { r = "zonder onderwerp" }
        return String(r.prefix(120))
    }

    static func textPart(_ s: String, subtype: String) -> String {
        "Content-Type: text/\(subtype); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + Data(s.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            + "\r\n"
    }

    static func header(_ name: String, _ value: String) -> String {
        "\(name): \(encodeWord(value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")))\r\n"
    }

    /// Formats a mailbox, encoding only the display name (RFC 5322 / 2047).
    static func address(name: String, email rawEmail: String) -> String {
        var email = rawEmail.trimmingCharacters(in: .whitespaces)
        // Header-derived values look like `Name <user@host>`.
        if let lt = email.lastIndex(of: "<"), let gt = email.lastIndex(of: ">"), lt < gt {
            email = String(email[email.index(after: lt)..<gt])
        }
        let cleanName = name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        guard email.contains("@") else { return encodeWord(cleanName.isEmpty ? email : cleanName) }
        if cleanName.isEmpty || cleanName == email { return email }
        let displayName: String
        if cleanName.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let escaped = cleanName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            displayName = "\"\(escaped)\""
        } else {
            displayName = encodeWord(cleanName)
        }
        return "\(displayName) <\(email)>"
    }

    /// A MIME parameter value as a quoted string (RFC 2045/2047), safe against quotes and line breaks.
    static func quotedParam(_ value: String) -> String {
        let flat = value.components(separatedBy: .newlines).joined(separator: " ")
        if flat.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let escaped = flat.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        // Encoded words never contain quotes or backslashes.
        return "\"\(encodeWord(flat).replacingOccurrences(of: "\r\n ", with: " "))\""
    }

    /// RFC 2047 encoded-word for non-ASCII header values.
    static func encodeWord(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        // RFC 2047 §2: an encoded word may be at most 75 characters, so split the text into
        // chunks of at most 45 UTF-8 bytes (never inside a character) and fold the header.
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if chunk.utf8.count + String(ch).utf8.count > 45, !chunk.isEmpty {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?utf-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    static func rfc2822(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return df.string(from: d)
    }
}
