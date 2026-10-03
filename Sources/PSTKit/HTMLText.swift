import Foundation

enum HTMLText {
    /// Decodes HTML bytes, honouring a <meta charset> declaration when present.
    static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        let head = String(decoding: bytes.prefix(4096), as: UTF8.self).lowercased()
        if let r = head.range(of: "charset=") {
            let rest = head[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            if let cp = HTMLText.codepage(forCharset: name), let enc = PSTText.encoding(forCodepage: cp),
               let s = String(bytes: bytes, encoding: enc) {
                return s
            }
        }
        return PSTText.decode(bytes, codepage: codepage)
    }

    static func codepage(forCharset name: String) -> Int? {
        switch name {
        case "utf-8", "utf8": return 65001
        case "us-ascii", "ascii": return 20127
        case "iso-8859-1", "latin1": return 28591
        case "iso-8859-2": return 28592
        case "iso-8859-15": return 28605
        case "shift_jis", "shift-jis", "sjis": return 932
        case "iso-2022-jp": return 50220
        case "euc-jp": return 51932
        case "utf-16", "utf-16le": return 1200
        default:
            if name.hasPrefix("windows-"), let n = Int(name.dropFirst(8)) { return n }
            if name.hasPrefix("cp"), let n = Int(name.dropFirst(2)) { return n }
            return nil
        }
    }

    /// Very small HTML → text conversion used for search and plain-text fallbacks.
    static func toPlain(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head"] {
            while let start = s.range(of: "<\(tag)", options: .caseInsensitive),
                  let end = s.range(of: "</\(tag)>", options: .caseInsensitive, range: start.upperBound..<s.endIndex) {
                s.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|tr|li|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
