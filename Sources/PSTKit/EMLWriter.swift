import Foundation

/// Builds RFC 5322 / MIME (.eml) messages and mbox files from PST messages.
public enum EMLWriter {
    public static func eml(for m: Message) -> Data {
        var out = ""
        let boundaryMixed = "----=_PSTViewer_mixed_\(m.nid)"
        let boundaryAlt = "----=_PSTViewer_alt_\(m.nid)"

        out += header("From", m.from)
        if !m.to.isEmpty { out += header("To", m.to) }
        if !m.cc.isEmpty { out += header("Cc", m.cc) }
        if !m.bcc.isEmpty { out += header("Bcc", m.bcc) }
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
                    out += "Content-Disposition: attachment; filename=\"\(encodeWord(safeName(a.filename) + ".eml"))\"\r\n\r\n"
                    out += String(decoding: eml(for: em), as: UTF8.self)
                } else {
                    let data = (try? m.data(for: a)) ?? Data()
                    let mime = a.mimeType.isEmpty ? "application/octet-stream" : a.mimeType
                    out += "Content-Type: \(mime); name=\"\(encodeWord(a.filename))\"\r\n"
                    out += "Content-Transfer-Encoding: base64\r\n"
                    if !a.contentID.isEmpty { out += "Content-ID: <\(a.contentID)>\r\n" }
                    out += "Content-Disposition: \(a.contentID.isEmpty ? "attachment" : "inline"); filename=\"\(encodeWord(a.filename))\"\r\n\r\n"
                    out += data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                    out += "\r\n"
                }
            }
            out += "\r\n--\(boundaryMixed)--\r\n"
        }
        return Data(out.utf8)
    }

    /// Appends messages to mbox format (mboxrd quoting).
    public static func mboxEntry(for m: Message) -> Data {
        let eml = String(decoding: eml(for: m), as: UTF8.self)
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

    /// RFC 2047 encoded-word for non-ASCII header values.
    static func encodeWord(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII }) { return s }
        return "=?utf-8?B?\(Data(s.utf8).base64EncodedString())?="
    }

    static func rfc2822(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return df.string(from: d)
    }
}
