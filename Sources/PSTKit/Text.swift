import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public enum PSTText {
    /// Code page used for 8-bit strings when the message does not specify one.
    /// Old Western-European Outlook installations use Windows-1252.
    public static var defaultCodepage = 1252

    static func utf16(_ bytes: [UInt8]) -> String {
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func encoding(forCodepage cp: Int) -> String.Encoding? {
        switch cp {
        case 1200: return .utf16LittleEndian
        case 1201: return .utf16BigEndian
        case 65001: return .utf8
        case 20127, 367: return .ascii
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1252: return .windowsCP1252
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 28591: return .isoLatin1
        case 28592: return .isoLatin2
        case 932: return .shiftJIS
        case 50220, 50221, 50222: return .iso2022JP
        case 51932, 20932: return .japaneseEUC
        case 10000: return .macOSRoman
        default: break
        }
        #if os(macOS)
        let cfEnc = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
        if cfEnc != kCFStringEncodingInvalidId {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        }
        #endif
        return nil
    }

    /// Windows-1252 mapping for 0x80...0x9F (the rest equals ISO-8859-1).
    private static let cp1252High: [UInt16] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    /// Built-in decoder for the most common Western code pages (not every
    /// Foundation implementation ships Windows-1252).
    static func decodeWestern(_ b: [UInt8], codepage: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in b {
            var v = UInt32(byte)
            if codepage == 1252, byte >= 0x80, byte < 0xA0 { v = UInt32(cp1252High[Int(byte) - 0x80]) }
            scalars.append(Unicode.Scalar(v) ?? "?")
        }
        return String(scalars)
    }

    /// Decodes 8-bit text in the given Windows code page, stripping trailing NULs.
    public static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        var b = bytes
        while b.last == 0 { b.removeLast() }
        if b.isEmpty { return "" }
        if b.allSatisfy({ $0 < 0x80 }) { return String(decoding: b, as: UTF8.self) }
        if codepage == 1252 || codepage == 28591 { return decodeWestern(b, codepage: codepage) }
        if let enc = encoding(forCodepage: codepage), let s = String(bytes: b, encoding: enc) {
            return s
        }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        return decodeWestern(b, codepage: 1252)
    }

    static func guidString(_ b: [UInt8]) -> String {
        guard b.count >= 16 else { return b.map { String(format: "%02X", $0) }.joined() }
        let d1 = b.u32(0), d2 = b.u16(4), d3 = b.u16(6)
        let rest = b[8..<16].map { String(format: "%02X", $0) }
        return String(format: "{%08X-%04X-%04X-", d1, d2, d3) + rest[0..<2].joined() + "-" + rest[2...].joined() + "}"
    }

    /// Removes the MAPI subject prefix marker (0x01 followed by a length char).
    static func cleanSubject(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        if scalars.count >= 2, scalars[0].value == 0x01 {
            scalars.removeFirst(2)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
