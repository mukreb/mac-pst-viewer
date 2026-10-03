import Foundation

/// One header field of an RFC 822 message or MIME part.
public struct MIMEHeader: Sendable {
    public let name: String
    /// The unfolded value, still with RFC 2047 encoded words.
    public let raw: String
    /// The value with encoded words decoded.
    public var value: String { MIME.decodeWords(raw) }
}

/// A parsed RFC 822 message or MIME entity (one node of the MIME tree).
final class MIMEPart: @unchecked Sendable {
    /// The whole entity: headers and body.
    let source: ArraySlice<UInt8>
    let headers: [MIMEHeader]
    /// The header block as text, for the "Headers" view.
    let headerText: String
    /// The body, still transfer-encoded (base64, quoted-printable, …).
    let rawBody: ArraySlice<UInt8>
    /// `type/subtype`, lowercased.
    let contentType: String
    let params: [String: String]
    private(set) var children: [MIMEPart] = []
    /// The message inside a `message/rfc822` part.
    private(set) var encapsulated: MIMEPart?

    /// `bytes` must use `\n` line endings (see `MIME.normalizeLineEndings`).
    init(_ bytes: ArraySlice<UInt8>, defaultType: String = "text/plain", depth: Int = 0) {
        source = bytes
        // The header block ends at the first empty line; a part may also start with it (no headers).
        var bodyStart = bytes.endIndex
        var headerEnd = bytes.endIndex
        if bytes.first == 0x0A {
            headerEnd = bytes.startIndex
            bodyStart = bytes.startIndex + 1
        } else {
            var i = bytes.startIndex
            while i < bytes.endIndex {
                guard let nl = bytes[i...].firstIndex(of: 0x0A) else { break }
                if nl + 1 < bytes.endIndex, bytes[nl + 1] == 0x0A {
                    headerEnd = nl + 1
                    bodyStart = nl + 2
                    break
                }
                i = nl + 1
            }
        }
        let headerBytes = bytes[bytes.startIndex..<headerEnd]
        headers = MIME.parseHeaders(headerBytes)
        headerText = MIME.decodeHeaderBytes(headerBytes)
        rawBody = bodyStart < bytes.endIndex ? bytes[bodyStart...] : []

        let (type, params) = MIME.parseContentType(headers.last { $0.name.lowercased() == "content-type" }?.raw)
        // A Content-Type without a usable type/subtype falls back to the default (RFC 2045 §5.2).
        contentType = type.contains("/") ? type : defaultType
        self.params = params

        guard depth < 24 else { return }
        if contentType.hasPrefix("multipart/"), let boundary = params["boundary"], !boundary.isEmpty {
            let childDefault = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
            children = MIME.splitMultipart(rawBody, boundary: boundary).map {
                MIMEPart($0, defaultType: childDefault, depth: depth + 1)
            }
        } else if contentType == "message/rfc822" {
            let enc = transferEncoding
            if enc == "base64" || enc == "quoted-printable" {
                encapsulated = MIMEPart(ArraySlice(MIME.normalizeLineEndings(decodedBody)), depth: depth + 1)
            } else {
                encapsulated = MIMEPart(rawBody, depth: depth + 1)
            }
        }
    }

    func header(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.name.lowercased() == n }?.value
    }

    func rawHeader(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.name.lowercased() == n }?.raw
    }

    var isMultipart: Bool { !children.isEmpty }

    var transferEncoding: String {
        (rawHeader("Content-Transfer-Encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var disposition: (type: String, params: [String: String]) {
        MIME.parseContentType(rawHeader("Content-Disposition"))
    }

    /// The file name from Content-Disposition or the Content-Type `name` parameter.
    var filename: String {
        let name = disposition.params["filename"] ?? params["name"] ?? ""
        return MIME.decodeWords(name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var contentID: String {
        (rawHeader("Content-ID") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \t<>"))
    }

    var charset: String? { params["charset"]?.lowercased() }

    /// The body with its transfer encoding removed.
    var decodedBody: [UInt8] {
        switch transferEncoding {
        case "base64": return MIME.decodeBase64(rawBody)
        case "quoted-printable": return MIME.decodeQuotedPrintable(rawBody)
        case "x-uuencode", "uuencode", "x-uue": return MIME.decodeUUEncoded(rawBody) ?? Array(rawBody)
        default: return Array(rawBody)
        }
    }

    /// The body decoded as text in the part's character set.
    var text: String { MIME.decodeText(decodedBody, charset: charset) }
}

/// Helpers for RFC 822 / MIME messages as found in mbox files.
public enum MIME {
    /// Converts CRLF and bare CR line endings to LF.
    static func normalizeLineEndings<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        guard bytes.contains(0x0D) else { return Array(bytes) }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var previousCR = false
        for b in bytes {
            if b == 0x0D {
                out.append(0x0A)
                previousCR = true
                continue
            }
            if b == 0x0A && previousCR { previousCR = false; continue }
            previousCR = false
            out.append(b)
        }
        return out
    }

    // MARK: Headers

    /// Header bytes as text: UTF-8 when valid, else the default (Windows) code page,
    /// since old mailers often put unencoded 8-bit text in headers.
    static func decodeHeaderBytes<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        let b = Array(bytes)
        if b.allSatisfy({ $0 < 0x80 }) { return String(decoding: b, as: UTF8.self) }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        return PSTText.decode(b, codepage: PSTText.defaultCodepage)
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> [MIMEHeader] {
        var result: [MIMEHeader] = []
        var name: String?
        var value = ""
        func flush() {
            if let n = name { result.append(MIMEHeader(name: n, raw: value.trimmingCharacters(in: .whitespaces))) }
            name = nil
            value = ""
        }
        for lineBytes in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = decodeHeaderBytes(lineBytes)
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if name != nil { value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            flush()
            // Lines without a colon (an mbox "From " line, ">From", garbage) are not fields.
            guard let colon = line.firstIndex(of: ":") else { continue }
            let n = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !n.contains(" ") else { continue }
            name = n
            value = String(line[line.index(after: colon)...])
        }
        flush()
        return result
    }

    /// Parses `type/subtype; key=value; key="value"` (also used for Content-Disposition).
    /// Handles RFC 2231 extended and continued parameters (`name*0*=utf-8''…`).
    static func parseContentType(_ raw: String?) -> (String, [String: String]) {
        guard let raw else { return ("", [:]) }
        let fields = splitParams(stripComments(raw))
        let type = (fields.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var simple: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for f in fields.dropFirst() {
            guard let eq = f.firstIndex(of: "=") else { continue }
            var key = f[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = f[f.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            var extended = false
            if key.hasSuffix("*") { extended = true; key.removeLast() }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((n, value, extended))
            } else if extended {
                simple[key] = decode2231(value, first: true, charset: nil).0
            } else if simple[key] == nil {
                simple[key] = value
            }
        }
        for (key, parts) in continued {
            var charset: String?
            var out = ""
            for (n, value, extended) in parts.sorted(by: { $0.0 < $1.0 }) {
                if extended {
                    let (s, cs) = decode2231(value, first: n == 0, charset: charset)
                    charset = cs
                    out += s
                } else {
                    out += value
                }
            }
            simple[key] = out
        }
        return (type, simple)
    }

    private static func stripComments(_ s: String) -> String {
        guard s.contains("(") else { return s }
        var out = ""
        var depth = 0
        var quoted = false
        for c in s {
            if c == "\"" && depth == 0 { quoted.toggle() }
            if !quoted && c == "(" { depth += 1; continue }
            if !quoted && c == ")" && depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(c) }
        }
        return out
    }

    private static func splitParams(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var escaped = false
        for c in s {
            if escaped { cur.append(c); escaped = false; continue }
            if c == "\\" && quoted { cur.append(c); escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == ";" && !quoted { out.append(cur); cur = ""; continue }
            cur.append(c)
        }
        out.append(cur)
        return out
    }

    /// `charset'lang'%XX…` (first segment) or `%XX…` (later segments).
    private static func decode2231(_ value: String, first: Bool, charset: String?) -> (String, String?) {
        var cs = charset
        var v = Substring(value)
        if first {
            let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3 {
                cs = parts[0].lowercased()
                v = parts[2]
            }
        }
        var bytes: [UInt8] = []
        var i = v.startIndex
        while i < v.endIndex {
            if v[i] == "%", let end = v.index(i, offsetBy: 3, limitedBy: v.endIndex),
               let b = UInt8(v[v.index(after: i)..<end], radix: 16) {
                bytes.append(b)
                i = end
            } else {
                bytes.append(contentsOf: Array(String(v[i]).utf8))
                i = v.index(after: i)
            }
        }
        return (decodeText(bytes, charset: cs), cs)
    }

    /// Decodes RFC 2047 encoded words (`=?iso-8859-1?Q?Caf=E9?=`); whitespace between
    /// adjacent encoded words is dropped.
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        var out = ""
        var rest = Substring(s)
        var lastWasEncoded = false
        while !rest.isEmpty {
            guard let start = rest.range(of: "=?") else {
                out += rest
                break
            }
            let before = rest[..<start.lowerBound]
            if let decoded = decodeWord(rest[start.lowerBound...]) {
                if !(lastWasEncoded && before.allSatisfy({ $0 == " " || $0 == "\t" })) { out += before }
                out += decoded.text
                rest = rest[decoded.end...]
                lastWasEncoded = true
            } else {
                out += before + "=?"
                rest = rest[start.upperBound...]
                lastWasEncoded = false
            }
        }
        return out
    }

    private static func decodeWord(_ s: Substring) -> (text: String, end: Substring.Index)? {
        // =?charset?enc?text?=
        let parts = s.dropFirst(2).split(separator: "?", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[3].hasPrefix("="), parts[0].count < 40, !parts[2].contains(" ") else { return nil }
        let charset = parts[0].split(separator: "*").first.map { $0.lowercased() } ?? ""  // RFC 2231 language suffix
        let payload = Array(parts[2].utf8)
        let bytes: [UInt8]
        switch parts[1].uppercased() {
        case "B": bytes = decodeBase64(payload[...])
        case "Q": bytes = decodeQuotedPrintable(payload.map { $0 == 0x5F ? 0x20 : $0 }[...])
        default: return nil
        }
        return (decodeText(bytes, charset: charset), s.index(after: parts[3].startIndex))
    }

    // MARK: Bodies

    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex {
            let lineEnd = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            if line.count >= delimiter.count, line.starts(with: delimiter) {
                let tail = line.dropFirst(delimiter.count)
                let isClose = tail.starts(with: [0x2D, 0x2D])
                let afterMarker = isClose ? tail.dropFirst(2) : tail
                if afterMarker.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let s = partStart {
                        // The line break before the delimiter belongs to the delimiter.
                        let end = max(s, lineStart - 1)
                        parts.append(body[s..<end])
                    }
                    if isClose { return parts }
                    partStart = min(lineEnd + 1, body.endIndex)
                }
            }
            lineStart = lineEnd + 1
        }
        // No closing delimiter (truncated message): keep what is there.
        if let s = partStart, s < body.endIndex { parts.append(body[s...]) }
        return parts
    }

    private static let base64Table: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 256)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() { t[Int(c)] = UInt8(i) }
        return t
    }()

    /// Lenient base64: skips line breaks and other characters outside the alphabet.
    static func decodeBase64(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 3 / 4)
        var acc: UInt32 = 0
        var n = 0
        for c in bytes {
            if c == 0x3D { break }  // '=' padding ends the data
            let v = base64Table[Int(c)]
            if v == 0xFF { continue }
            acc = acc << 6 | UInt32(v)
            n += 1
            if n == 4 {
                out.append(UInt8(acc >> 16 & 0xFF))
                out.append(UInt8(acc >> 8 & 0xFF))
                out.append(UInt8(acc & 0xFF))
                acc = 0
                n = 0
            }
        }
        if n == 2 { out.append(UInt8(acc >> 4 & 0xFF)) }
        if n == 3 {
            out.append(UInt8(acc >> 10 & 0xFF))
            out.append(UInt8(acc >> 2 & 0xFF))
        }
        return out
    }

    static func decodeQuotedPrintable(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let c = bytes[i]
            guard c == 0x3D else { out.append(c); i += 1; continue }
            // Soft line break: "=" followed by optional whitespace and a newline.
            var j = i + 1
            while j < bytes.endIndex, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
            if j < bytes.endIndex, bytes[j] == 0x0A { i = j + 1; continue }
            if j >= bytes.endIndex { break }
            if i + 2 < bytes.endIndex, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(c)  // a stray "=" stays literal
                i += 1
            }
        }
        return out
    }

    /// Decodes the first uuencoded block (`begin 644 name` … `end`) in `bytes`.
    static func decodeUUEncoded(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
        let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard let begin = lines.firstIndex(where: { $0.starts(with: Array("begin ".utf8)) }) else { return nil }
        return decodeUULines(lines[(begin + 1)...]).data
    }

    /// Decodes uuencoded lines up to `end`; returns the data and the number of lines used.
    static func decodeUULines(_ lines: ArraySlice<ArraySlice<UInt8>>) -> (data: [UInt8], used: Int, complete: Bool) {
        var out: [UInt8] = []
        var used = 0
        for line in lines {
            used += 1
            var l = line
            while let last = l.last, last == 0x20 || last == 0x09 { l = l.dropLast() }
            if l.elementsEqual("end".utf8) { return (out, used, true) }
            guard let first = l.first else { continue }
            let count = Int((first &- 0x20) & 0x3F)
            if count == 0 { continue }
            var chars = Array(l.dropFirst())
            // Some encoders strip trailing spaces; pad so every group has 4 characters.
            let needed = (count + 2) / 3 * 4
            if chars.count < needed { chars += [UInt8](repeating: 0x20, count: needed - chars.count) }
            var decoded: [UInt8] = []
            var k = 0
            while k + 3 < chars.count, decoded.count < count {
                let a = (chars[k] &- 0x20) & 0x3F, b = (chars[k + 1] &- 0x20) & 0x3F
                let c = (chars[k + 2] &- 0x20) & 0x3F, d = (chars[k + 3] &- 0x20) & 0x3F
                decoded.append(a << 2 | b >> 4)
                decoded.append(b << 4 | c >> 2)
                decoded.append(c << 6 | d)
                k += 4
            }
            out += decoded.prefix(count)
        }
        return (out, used, false)
    }

    // MARK: Character sets

    static func codepage(forCharset raw: String) -> Int? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        if let cp = HTMLText.codepage(forCharset: name) { return cp }
        switch name {
        case "iso-8859-3": return 28593
        case "iso-8859-4": return 28594
        case "iso-8859-5": return 28595
        case "iso-8859-7": return 28597
        case "iso-8859-9": return 28599
        case "koi8-r": return 20866
        case "koi8-u": return 21866
        case "macintosh", "x-mac-roman", "mac": return 10000
        case "big5": return 950
        case "gb2312", "gbk": return 936
        case "euc-kr", "ks_c_5601-1987": return 949
        case "x-sjis": return 932
        case "x-user-defined", "unknown-8bit", "x-unknown", "default": return nil
        default:
            if name.hasPrefix("iso8859-"), let n = Int(name.dropFirst(8)) { return 28590 + n }
            if name.hasPrefix("iso_8859-"), let n = Int(name.dropFirst(9).prefix { $0.isNumber }) { return 28590 + n }
            if name.hasPrefix("windows"), let n = Int(name.filter(\.isNumber)) { return n }
            return nil
        }
    }

    /// Decodes text in a MIME character set. A missing, unknown or plainly wrong charset
    /// (`us-ascii` with 8-bit bytes, common in old mail) falls back to UTF-8 when the bytes
    /// are valid UTF-8, and otherwise to the default code page.
    static func decodeText(_ bytes: [UInt8], charset: String?) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let charset, let cp = codepage(forCharset: charset), cp != 20127 {
            if cp == 65001, let s = String(bytes: bytes, encoding: .utf8) { return s }
            if cp != 65001 {
                if cp == 28591 || cp == 1252 { return PSTText.decodeWestern(bytes, codepage: cp) }
                if let enc = PSTText.encoding(forCodepage: cp), let s = String(bytes: bytes, encoding: enc) { return s }
            }
        }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return PSTText.decode(bytes, codepage: PSTText.defaultCodepage)
    }

    // MARK: Addresses and dates

    /// One mailbox of an address list.
    struct Address {
        var name: String
        var email: String
    }

    /// Splits an address-list header (`"Doe, J." <j@x>, k@y (Karel)`) into mailboxes.
    static func parseAddresses(_ value: String) -> [Address] {
        var items: [String] = []
        var cur = ""
        var quoted = false, angle = false
        var paren = 0
        for c in value {
            if c == "\"" && paren == 0 { quoted.toggle() }
            else if !quoted && c == "(" { paren += 1 }
            else if !quoted && c == ")" && paren > 0 { paren -= 1 }
            else if !quoted && paren == 0 && c == "<" { angle = true }
            else if !quoted && paren == 0 && c == ">" { angle = false }
            if (c == "," || c == ";") && !quoted && !angle && paren == 0 {
                items.append(cur)
                cur = ""
                continue
            }
            cur.append(c)
        }
        items.append(cur)
        return items.compactMap { item in
            var s = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            // Group syntax "Friends: a@b, c@d;" — drop the label.
            if let colon = s.firstIndex(of: ":"), !s.contains("<"), !s[..<colon].contains("@"), !s[..<colon].contains("\"") {
                s = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if s.isEmpty { return nil }
            }
            var name = "", email = ""
            if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
                email = s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
                name = String(s[..<lt]) + String(s[s.index(after: gt)...])
            } else if let lp = s.firstIndex(of: "("), let rp = s.lastIndex(of: ")"), lp < rp {
                // Old style: user@host (Full Name)
                email = s[..<lp].trimmingCharacters(in: .whitespaces)
                name = String(s[s.index(after: lp)..<rp])
            } else {
                email = s
            }
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = decodeWords(name.replacingOccurrences(of: "\\\"", with: "\"")).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            email = email.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            if !email.contains("@") && name.isEmpty { name = decodeWords(email); email = "" }
            return Address(name: name, email: email)
        }
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zones: [String: Int] = [
        "UT": 0, "GMT": 0, "UTC": 0, "Z": 0, "WET": 0, "BST": 60, "CET": 60, "MET": 60, "MEZ": 60, "CEST": 120,
        "MEST": 120, "MESZ": 120, "EET": 120, "EST": -300, "EDT": -240, "CST": -360, "CDT": -300,
        "MST": -420, "MDT": -360, "PST": -480, "PDT": -420, "JST": 540,
    ]

    /// Tolerant RFC 822 / asctime date parser: `Thu, 4 Nov 1999 12:00:00 +0100`,
    /// `4 Nov 99 12:00 MET`, `Thu Nov  4 12:00:00 1999`, …
    /// Dates without a zone are taken as local time.
    public static func parseDate(_ s: String) -> Date? {
        let tokens = s.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        var day: Int?, month: Int?, year: Int?
        var h = 0, m = 0, sec = 0
        var offset: Int?
        var offsetFromName = false
        for t in tokens {
            let lower = t.lowercased()
            let digits = t.dropFirst().filter { $0 != ":" }
            if month == nil, let i = months.firstIndex(where: { lower.hasPrefix($0) }), lower.count >= 3, lower.allSatisfy(\.isLetter) {
                month = i + 1
            } else if t.hasPrefix("+") || t.hasPrefix("-"), (3...4).contains(digits.count),
                      let v = Int(digits) {
                // +0100, -0500, +01:00, and the odd +100 from broken clients. A numeric
                // offset wins over a zone name.
                if offset == nil || offsetFromName {
                    offset = (t.hasPrefix("-") ? -1 : 1) * (v / 100 * 60 + v % 100)
                    offsetFromName = false
                }
            } else if t.contains(":") {
                let p = t.split(separator: ":").map { Int($0) }
                guard p.count >= 2, let hh = p[0], let mm = p[1] else { continue }
                h = hh; m = mm
                if p.count > 2, let ss = p[2] { sec = ss }
            } else if t.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "()")) == "DST" {
                // `MET DST`: summer time, an hour ahead of the named zone.
                if offsetFromName, let o = offset { offset = o + 60; offsetFromName = false }
            } else if let z = zones[t.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "()"))] {
                if offset == nil { offset = z; offsetFromName = true }
            } else if let n = Int(t) {
                if day == nil && n >= 1 && n <= 31 && t.count <= 2 { day = n }
                else if year == nil { year = n }
            }
        }
        guard let d = day, let mo = month, var y = year else { return nil }
        if y < 50 { y += 2000 } else if y < 100 { y += 1900 }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = m; comps.second = sec
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0 * 60) } ?? .current
        return cal.date(from: comps)
    }
}
