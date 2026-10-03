import Foundation

/// Builds RFC 5322 / MIME (.eml) messages and mbox files from PST messages.
public enum EMLWriter {
    public static func eml(for m: Message) throws -> Data {
        try eml(for: m, depth: 0)
    }

    /// `depth` limits nested embedded messages, so a corrupt file whose attachments point back
    /// to their own message cannot recurse forever.
    static func eml(for m: Message, depth: Int) throws -> Data {
        guard depth < 16 else { throw PSTError.corrupt("te diep geneste bijgevoegde berichten") }
        if let problem = m.recipientError ?? m.bodyError { throw PSTError.corrupt("\(m.subject): \(problem)") }
        var out = ""
        // NIDs of embedded messages are only unique within their parent, so add randomness.
        let unique = UUID().uuidString
        let boundaryMixed = "----=_PSTViewer_mixed_\(unique)"
        let boundaryAlt = "----=_PSTViewer_alt_\(unique)"

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
        let messageID = flat(m.messageID)
        if !messageID.isEmpty { out += "Message-ID: \(messageID)\r\n" }
        out += "X-PST-Message-Class: \(flat(m.messageClass))\r\n"
        out += "MIME-Version: 1.0\r\n"

        let text = m.plainBody
        var html: String? = nil
        if case .html(let h) = m.body { html = h }
        if let problem = m.attachmentErrors.first {
            throw PSTError.corrupt("\(m.subject): \(problem)")
        }
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
                if a.isEmbeddedMessage {
                    guard let em = try m.embeddedMessage(a) else {
                        throw PSTError.corrupt("bijgevoegd bericht '\(a.filename)' kan niet worden gelezen")
                    }
                    out += "Content-Type: message/rfc822\r\n"
                    out += "Content-Disposition: attachment; \(mimeParam("filename", safeName(a.filename) + ".eml"))\r\n\r\n"
                    out += String(decoding: try eml(for: em, depth: depth + 1), as: UTF8.self)
                } else if a.isExternalReference {
                    // The PST only holds a link to a file elsewhere: say so instead of an empty file.
                    // Base64 like every other UTF-8 part: the name may be non-ASCII or very long.
                    let note = "Deze bijlage (\(flat(a.filename))) was een koppeling naar een extern bestand en zit niet in het PST-bestand.\r\n"
                    out += "Content-Type: text/plain; charset=utf-8; \(mimeParam("name", a.filename + ".txt"))\r\n"
                    out += "Content-Transfer-Encoding: base64\r\n"
                    out += "Content-Disposition: attachment; \(mimeParam("filename", a.filename + ".txt"))\r\n\r\n"
                    out += Data(note.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                    out += "\r\n"
                } else {
                    // Fail loudly rather than export a silently empty attachment.
                    let data: Data
                    do { data = try m.data(for: a) } catch {
                        throw PSTError.corrupt("bijlage '\(a.filename)' kan niet worden gelezen (\(error))")
                    }
                    let mimeTag = a.mimeType.components(separatedBy: .whitespacesAndNewlines).joined()
                    let mime = mimeTag.contains("/") ? mimeTag : "application/octet-stream"
                    out += "Content-Type: \(mime); \(mimeParam("name", a.filename))\r\n"
                    out += "Content-Transfer-Encoding: base64\r\n"
                    let cid = a.contentID.components(separatedBy: .whitespacesAndNewlines).joined()
                        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                    if !cid.isEmpty { out += "Content-ID: <\(cid)>\r\n" }
                    out += "Content-Disposition: \(a.contentID.isEmpty ? "attachment" : "inline"); \(mimeParam("filename", a.filename))\r\n\r\n"
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
        let email = addrSpec(m.fromEmail)
        let sender = email.contains("@") ? email : "MAILER-DAEMON"
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
        // File systems limit a name to 255 bytes; keep room for " (123)" and an extension.
        var limited = ""
        for ch in r {
            if limited.utf8.count + String(ch).utf8.count > 200 { break }
            limited.append(ch)
        }
        return limited
    }

    static func textPart(_ s: String, subtype: String) -> String {
        "Content-Type: text/\(subtype); charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            + Data(s.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            + "\r\n"
    }

    /// Folds a long ASCII value at spaces (RFC 5322 §2.2.3) so lines stay short; a single word too
    /// long to fold is sent as encoded words instead, keeping every line under the 998-character limit.
    static func fold(_ s: String) -> String {
        guard s.count > 70 else { return s }
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        if words.contains(where: { $0.count > 900 }) { return encodeWord(s, force: true) }
        var lines: [String] = []
        var line = ""
        for w in words {
            if !line.isEmpty, line.count + 1 + w.count > 70 {
                lines.append(line)
                line = String(w)
            } else {
                line = line.isEmpty && lines.isEmpty ? String(w) : (line.isEmpty ? String(w) : line + " " + w)
            }
        }
        lines.append(line)
        return lines.joined(separator: "\r\n ")
    }

    static func header(_ name: String, _ value: String) -> String {
        "\(name): \(encodeWord(flat(value)))\r\n"
    }

    /// Formats a mailbox, encoding only the display name (RFC 5322 / 2047).
    /// Replaces line breaks (and other control characters) so a value can't break out of its header.
    static func flat(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// The bare `user@host` part of an address value, without whitespace, brackets or control characters.
    static func addrSpec(_ raw: String) -> String {
        var email = raw
        // Header-derived values look like `Name <user@host>`.
        if let lt = email.lastIndex(of: "<"), let gt = email.lastIndex(of: ">"), lt < gt {
            email = String(email[email.index(after: lt)..<gt])
        }
        return String(email.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
                && $0 != "<" && $0 != ">" && $0 != "\"" && $0 != ","
        }.map(Character.init))
    }

    static func address(name: String, email rawEmail: String) -> String {
        let email = addrSpec(rawEmail)
        let cleanName = flat(name).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        guard email.contains("@") else { return encodeWord(cleanName.isEmpty ? email : cleanName) }
        if cleanName.isEmpty || cleanName == email { return email }
        let displayName: String
        if cleanName.unicodeScalars.allSatisfy({ $0.isASCII }) && cleanName.count <= 70 {
            let escaped = cleanName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            displayName = "\"\(escaped)\""
        } else {
            // Non-ASCII or long names: split encoded words that fold onto continuation lines.
            displayName = encodeWord(cleanName, force: true)
        }
        return "\(displayName) <\(email)>"
    }

    /// An ASCII MIME parameter value as a quoted string, safe against quotes and line breaks.
    static func quotedParam(_ value: String) -> String {
        let escaped = flat(value).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// `key="value"`, or for non-ASCII values an ASCII fallback plus an RFC 2231 extended
    /// parameter (`key*=utf-8''…`), since RFC 2047 encoded words are not allowed in parameters.
    static func mimeParam(_ key: String, _ value: String) -> String {
        let v = flat(value)
        // Short ASCII values stay a plain quoted string; long ones use the continuation path below.
        if v.unicodeScalars.allSatisfy({ $0.isASCII }) && v.count <= 70 { return "\(key)=\(quotedParam(v))" }
        var fallback = String(v.unicodeScalars.map { $0.isASCII ? Character($0) : "_" })
        if fallback.count > 60 { fallback = String(fallback.prefix(50)) + "…" + String(fallback.suffix(9)) }
        fallback = String(fallback.unicodeScalars.map { $0.isASCII ? Character($0) : "_" })
        let attrChar = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")
        let encoded = v.utf8.map { b -> String in
            let s = Unicode.Scalar(b)
            return b < 0x80 && attrChar.contains(s) ? String(Character(s)) : String(format: "%%%02X", b)
        }.joined()
        // RFC 2231 §3: split long values into numbered continuations on folded lines,
        // never inside a %XX escape.
        var segments: [String] = []
        var current = ""
        var i = encoded.startIndex
        while i < encoded.endIndex {
            let step = encoded[i] == "%" ? 3 : 1
            let end = encoded.index(i, offsetBy: step, limitedBy: encoded.endIndex) ?? encoded.endIndex
            if current.count + step > 60 { segments.append(current); current = "" }
            current += encoded[i..<end]
            i = end
        }
        if !current.isEmpty { segments.append(current) }
        if segments.count <= 1 {
            return "\(key)=\(quotedParam(fallback));\r\n \(key)*=utf-8''\(encoded)"
        }
        let parts = segments.enumerated().map { n, seg in
            n == 0 ? "\(key)*0*=utf-8''\(seg)" : "\(key)*\(n)*=\(seg)"
        }
        return "\(key)=\(quotedParam(fallback));\r\n " + parts.joined(separator: ";\r\n ")
    }

    /// RFC 2047 encoded-word for non-ASCII header values.
    static func encodeWord(_ s: String, force: Bool = false) -> String {
        if !force && s.unicodeScalars.allSatisfy({ $0.isASCII }) { return fold(s) }
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
