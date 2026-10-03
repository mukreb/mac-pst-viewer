import Foundation

/// Errors raised while parsing a PST/OST file.
public enum PSTError: Error, CustomStringConvertible {
    case notAPSTFile
    case unsupportedVersion(UInt16)
    case unsupportedEncryption(UInt8)
    case corrupt(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .notAPSTFile: return tr("This is not a PST/OST file (invalid signature).", "Dit is geen PST/OST-bestand (ongeldige signatuur).")
        case .unsupportedVersion(let v): return tr("Unsupported PST version: \(v).", "Niet-ondersteunde PST-versie: \(v).")
        case .unsupportedEncryption(let e): return tr("Unsupported encryption: \(e).", "Niet-ondersteunde versleuteling: \(e).")
        case .corrupt(let s): return tr("Damaged data: \(s)", "Beschadigde gegevens: \(s)")
        case .notFound(let s): return tr("Not found: \(s)", "Niet gevonden: \(s)")
        }
    }
}

/// Little-endian helpers on byte arrays. All reads are bounds-checked and
/// return 0 when out of range so a damaged file never crashes the app.
extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> UInt8 {
        (o >= 0 && o < count) ? self[o] : 0
    }

    @inline(__always) func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= count else { return 0 }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }

    @inline(__always) func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= count else { return 0 }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }

    func slice(_ o: Int, _ n: Int) -> [UInt8] {
        guard o >= 0, n > 0, o < count else { return [] }
        return Array(self[o..<Swift.min(count, o + n)])
    }
}

extension Data {
    @inline(__always) func bytes(at offset: Int, count n: Int) -> [UInt8] {
        guard offset >= 0, n > 0, offset < count else { return [] }
        let end = Swift.min(count, offset + n)
        return [UInt8](self[(startIndex + offset)..<(startIndex + end)])
    }
}

enum FileTime {
    /// Converts a Windows FILETIME (100ns intervals since 1601-01-01) to a Date.
    static func date(_ ft: UInt64) -> Date? {
        guard ft != 0, ft != UInt64.max else { return nil }
        let seconds = Double(ft) / 10_000_000.0 - 11_644_473_600.0
        guard seconds > -2_000_000_000, seconds < 32_503_680_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// OLE automation date (days since 1899-12-30).
    static func oleDate(_ d: Double) -> Date? {
        guard d.isFinite else { return nil }
        return Date(timeIntervalSince1970: (d - 25569.0) * 86400.0)
    }
}
