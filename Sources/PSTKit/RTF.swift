import Foundation

public enum RTF {
    private static let prebuf: [UInt8] = Array(
        ("{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx").utf8)

    /// Decompresses PR_RTF_COMPRESSED ([MS-OXRTFCP]).
    public static func decompress(_ input: [UInt8]) -> [UInt8]? {
        guard input.count >= 16 else { return nil }
        let compSize = Int(input.u32(0))
        let rawSize = Int(input.u32(4))
        let magic = input.u32(8)
        guard rawSize >= 0, compSize >= 0 else { return nil }
        if magic == 0x414C_454D { // "MELA": stored uncompressed
            guard input.count - 16 >= rawSize else { return nil }  // truncated
            return input.slice(16, rawSize)
        }
        guard magic == 0x7546_5A4C else { return nil } // "LZFu"
        // The CRC covers everything after the 16-byte header; a mismatch means altered data.
        guard compSize >= 12, input.count >= compSize + 4,
              crc32(input[16..<(compSize + 4)]) == input.u32(12) else { return nil }
        var dict = [UInt8](repeating: 0, count: 4096)
        for (i, b) in prebuf.enumerated() { dict[i] = b }
        var writePos = prebuf.count
        var out: [UInt8] = []
        // Hard output limit: the advertised size, never more than 64 MB, enforced while decoding.
        let limit = rawSize > 0 ? Swift.min(rawSize, 64 << 20) : 64 << 20
        // LZFu expands at most ~8x; never trust the advertised size beyond that.
        out.reserveCapacity(Swift.max(0, Swift.min(limit, input.count * 8)))
        var pos = 16
        let end = Swift.min(input.count, compSize + 4)
        outer: while pos < end {
            let control = input[pos]
            pos += 1
            for bit in 0..<8 {
                guard pos < end, out.count < limit else { break outer }
                if control & (1 << bit) == 0 {
                    let b = input[pos]
                    pos += 1
                    out.append(b)
                    dict[writePos] = b
                    writePos = (writePos + 1) & 0xFFF
                } else {
                    guard pos + 1 < end else { break outer }
                    let ref = Int(input[pos]) << 8 | Int(input[pos + 1])
                    pos += 2
                    let offset = ref >> 4
                    let length = (ref & 0xF) + 2
                    if offset == writePos { break outer }
                    for k in 0..<Swift.min(length, limit - out.count) {
                        let b = dict[(offset + k) & 0xFFF]
                        out.append(b)
                        dict[writePos] = b
                        writePos = (writePos + 1) & 0xFFF
                    }
                }
            }
        }
        // A truncated or damaged stream must not pass for a complete body.
        if rawSize > 0 && out.count != rawSize { return nil }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 as defined by [MS-OXRTFCP] 2.1.3.2: the standard table, initial value 0, no final XOR.
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc
    }

    /// True when the RTF was generated from HTML ([MS-OXRTFEX]).
    public static func isEncapsulatedHTML(_ rtf: [UInt8]) -> Bool {
        let head = rtf.prefix(2048)
        return String(decoding: head, as: UTF8.self).contains("\\fromhtml")
    }

    public static func isEncapsulatedText(_ rtf: [UInt8]) -> Bool {
        let head = rtf.prefix(2048)
        return String(decoding: head, as: UTF8.self).contains("\\fromtext")
    }

    /// Extracts the original HTML from HTML-encapsulated RTF.
    public static func extractHTML(_ rtf: [UInt8]) -> String {
        Converter(rtf, mode: .html).run()
    }

    /// Converts RTF to plain text (best effort).
    public static func plainText(_ rtf: [UInt8]) -> String {
        Converter(rtf, mode: .text).run()
    }

    private final class Converter {
        enum Mode { case html, text }

        struct State {
            var skip = false          // inside an ignored destination
            var htmlrtf = false       // \htmlrtf suppression
            var inHtmlTag = false     // inside {\*\htmltag ...}
            var uc = 1
        }

        let src: [UInt8]
        let mode: Mode
        var pos = 0
        var codepage = 1252
        var out = ""
        var pending: [UInt8] = []
        var stack: [State] = []
        var state = State()
        var skipChars = 0
        var groupJustOpened = false
        var highSurrogate: UInt32?

        init(_ src: [UInt8], mode: Mode) {
            self.src = src
            self.mode = mode
        }

        func flush() {
            if !pending.isEmpty {
                out += PSTText.decode(pending, codepage: codepage)
                pending.removeAll(keepingCapacity: true)
            }
        }

        var emitting: Bool {
            if state.skip { return false }
            if mode == .html { return state.inHtmlTag || !state.htmlrtf }
            return true
        }

        func emitByte(_ b: UInt8) {
            guard emitting else { return }
            if skipChars > 0 { skipChars -= 1; return }
            pending.append(b)
        }

        func emitString(_ s: String) {
            guard emitting else { return }
            flush()
            out += s
        }

        static let skipDestinations: Set<String> = [
            "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header", "footer",
            "headerl", "headerr", "footerl", "footerr", "listtable", "listoverridetable", "revtbl",
            "rsidtbl", "xmlnstbl", "themedata", "colorschememapping", "datastore", "latentstyles",
            "generator", "filetbl", "mmathPr", "pgdsctbl", "fldinst", "bkmkstart", "bkmkend",
        ]

        func run() -> String {
            while pos < src.count {
                let c = src[pos]
                switch c {
                case UInt8(ascii: "{"):
                    stack.append(state)
                    groupJustOpened = true
                    pos += 1
                    continue
                case UInt8(ascii: "}"):
                    flush()
                    if let s = stack.popLast() { state = s }
                    pos += 1
                case UInt8(ascii: "\\"):
                    parseControl()
                case 0x0D, 0x0A:
                    pos += 1
                default:
                    emitByte(c)
                    pos += 1
                }
                groupJustOpened = false
            }
            flush()
            return out
        }

        func parseControl() {
            let wasGroupStart = groupJustOpened
            pos += 1
            guard pos < src.count else { return }
            let c = src[pos]
            if !isAlpha(c) {
                pos += 1
                switch c {
                case UInt8(ascii: "'"):
                    guard pos + 1 < src.count, let v = UInt8(String(decoding: src[pos..<(pos + 2)], as: UTF8.self), radix: 16) else { return }
                    pos += 2
                    emitByte(v)
                case UInt8(ascii: "*"):
                    // Optional destination: skip unless it is an htmltag (html mode) handled by the next word.
                    peekStarDestination()
                case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                    emitByte(c)
                case UInt8(ascii: "~"):
                    emitString("\u{00A0}")
                case UInt8(ascii: "-"), UInt8(ascii: "_"):
                    break
                case 0x0D, 0x0A:
                    emitString(mode == .html ? "\r\n" : "\n")
                default:
                    break
                }
                return
            }
            let wordStart = pos
            while pos < src.count, isAlpha(src[pos]) { pos += 1 }
            let word = String(decoding: src[wordStart..<pos], as: UTF8.self)
            var param: Int? = nil
            if pos < src.count, src[pos] == UInt8(ascii: "-") || isDigit(src[pos]) {
                let ps = pos
                pos += 1
                while pos < src.count, isDigit(src[pos]) { pos += 1 }
                param = Int(String(decoding: src[ps..<pos], as: UTF8.self))
            }
            if pos < src.count, src[pos] == UInt8(ascii: " ") { pos += 1 }
            handle(word: word, param: param, atGroupStart: wasGroupStart)
        }

        func peekStarDestination() {
            // Read the following control word to decide.
            var p = pos
            while p < src.count, src[p] == 0x0D || src[p] == 0x0A || src[p] == 0x20 { p += 1 }
            guard p < src.count, src[p] == UInt8(ascii: "\\") else { state.skip = true; return }
            var q = p + 1
            while q < src.count, isAlpha(src[q]) { q += 1 }
            let word = String(decoding: src[(p + 1)..<q], as: UTF8.self)
            if mode == .html, word == "htmltag" || word == "mhtmltag" {
                return // handled by the word itself
            }
            state.skip = true
        }

        func handle(word: String, param: Int?, atGroupStart: Bool) {
            switch word {
            case "ansicpg":
                if let p = param { flush(); codepage = p }
            case "uc":
                state.uc = param ?? 1
            case "u":
                if var v = param {
                    if v < 0 { v += 65536 }
                    if (0xD800...0xDBFF).contains(v) {
                        highSurrogate = UInt32(v) // wait for the low half of a non-BMP character
                    } else if (0xDC00...0xDFFF).contains(v), let high = highSurrogate {
                        let combined = 0x10000 + ((high - 0xD800) << 10) + (UInt32(v) - 0xDC00)
                        if let scalar = Unicode.Scalar(combined) { emitString(String(Character(scalar))) }
                        highSurrogate = nil
                    } else if let scalar = Unicode.Scalar(UInt32(v)) {
                        highSurrogate = nil
                        emitString(String(Character(scalar)))
                    }
                    skipChars = state.uc
                }
            case "htmltag", "mhtmltag":
                if mode == .html {
                    state.inHtmlTag = true
                    state.skip = false
                }
            case "htmlrtf":
                state.htmlrtf = (param ?? 1) != 0
            case "par", "line":
                if mode == .text || state.inHtmlTag { emitString(mode == .html ? "\r\n" : "\n") }
                else if !state.htmlrtf { emitString("\r\n") }
            case "tab":
                emitString("\t")
            case "emdash": emitString("—")
            case "endash": emitString("–")
            case "bullet": emitString("•")
            case "lquote": emitString("‘")
            case "rquote": emitString("’")
            case "ldblquote": emitString("“")
            case "rdblquote": emitString("”")
            case "cell":
                if mode == .text { emitString("\t") }
            case "row":
                if mode == .text { emitString("\n") }
            case "sect", "page":
                if mode == .text { emitString("\n\n") }
            default:
                if atGroupStart, Converter.skipDestinations.contains(word) {
                    state.skip = true
                }
            }
        }

        @inline(__always) func isAlpha(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }

        @inline(__always) func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    }
}
