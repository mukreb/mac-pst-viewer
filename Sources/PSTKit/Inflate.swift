import Foundation

/// Minimal DEFLATE (RFC 1951) decoder, used for the compressed blocks of
/// Outlook 2013+ OST files. Kept dependency-free so it works on every platform.
enum Inflate {
    /// Decodes a zlib stream (2-byte header + raw deflate). Falls back to raw deflate
    /// when the header is absent.
    static func zlib(_ input: [UInt8], expectedSize: Int = 0) -> [UInt8]? {
        guard input.count >= 2 else { return nil }
        let cmf = input[0], flg = input[1]
        let hasHeader = (cmf & 0x0F) == 8 && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
        guard let (out, end) = decode(input, start: hasHeader ? 2 : 0, expectedSize: expectedSize) else { return nil }
        // zlib streams end with an Adler-32 of the output: reject data that decodes but is corrupt.
        if hasHeader {
            // A wrapper without its full checksum is truncated: never accept it unverified.
            guard end + 4 <= input.count else { return nil }
            let stored = UInt32(input[end]) << 24 | UInt32(input[end + 1]) << 16 | UInt32(input[end + 2]) << 8 | UInt32(input[end + 3])
            guard stored == adler32(out) else { return nil }
        }
        return out
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 5552, data.count)  // largest block before the sums can overflow
            while i < end { a += UInt32(data[i]); b += a; i += 1 }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }

    static func raw(_ input: [UInt8], start: Int = 0, expectedSize: Int = 0) -> [UInt8]? {
        decode(input, start: start, expectedSize: expectedSize)?.out
    }

    private struct BitReader {
        let data: [UInt8]
        var pos: Int
        var bitBuf: UInt32 = 0
        var bitCnt: Int = 0

        init(_ data: [UInt8], _ start: Int) { self.data = data; pos = start }

        mutating func bits(_ n: Int) -> Int? {
            while bitCnt < n {
                guard pos < data.count else { return nil }
                bitBuf |= UInt32(data[pos]) << UInt32(bitCnt)
                pos += 1
                bitCnt += 8
            }
            let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
            bitBuf >>= UInt32(n)
            bitCnt -= n
            return v
        }

        mutating func alignToByte() { bitBuf = 0; bitCnt = 0 }
    }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l != 0 {
                symbols[offs[l]] = s
                offs[l] += 1
            }
        }

        func decode(_ br: inout BitReader) -> Int? {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                guard let b = br.bits(1) else { return nil }
                code |= b
                let count = counts[len]
                if code - count < first { return symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            return nil
        }
    }

    private static let lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static let fixedLit: Huffman = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return Huffman(lengths: l)
    }()
    private static let fixedDist = Huffman(lengths: [Int](repeating: 5, count: 30))

    /// Decodes raw DEFLATE; also returns the byte offset just past the stream.
    private static func decode(_ input: [UInt8], start: Int, expectedSize: Int) -> (out: [UInt8], end: Int)? {
        // Never produce more than advertised (or 64 MB when unknown): guards against decompression bombs.
        let limit = expectedSize > 0 ? expectedSize : 64 << 20
        var br = BitReader(input, start)
        var out: [UInt8] = []
        out.reserveCapacity(expectedSize)
        var final = 0
        repeat {
            guard let f = br.bits(1), let type = br.bits(2) else { return nil }
            final = f
            switch type {
            case 0:
                br.alignToByte()
                guard br.pos + 4 <= input.count else { return nil }
                let len = Int(input[br.pos]) | Int(input[br.pos + 1]) << 8
                br.pos += 4
                guard br.pos + len <= input.count else { return nil }
                guard out.count + len <= limit else { return nil }
                out.append(contentsOf: input[br.pos..<(br.pos + len)])
                br.pos += len
            case 1:
                guard codes(&br, &out, fixedLit, fixedDist, limit: limit) else { return nil }
            case 2:
                guard let hlit = br.bits(5), let hdist = br.bits(5), let hclen = br.bits(4) else { return nil }
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<(hclen + 4) {
                    guard let v = br.bits(3) else { return nil }
                    cl[order[i]] = v
                }
                let clh = Huffman(lengths: cl)
                var lengths: [Int] = []
                let total = hlit + 257 + hdist + 1
                while lengths.count < total {
                    guard let sym = clh.decode(&br) else { return nil }
                    switch sym {
                    case 0..<16: lengths.append(sym)
                    case 16:
                        guard let prev = lengths.last, let r = br.bits(2) else { return nil }
                        lengths.append(contentsOf: repeatElement(prev, count: 3 + r))
                    case 17:
                        guard let r = br.bits(3) else { return nil }
                        lengths.append(contentsOf: repeatElement(0, count: 3 + r))
                    default:
                        guard let r = br.bits(7) else { return nil }
                        lengths.append(contentsOf: repeatElement(0, count: 11 + r))
                    }
                }
                guard lengths.count == total else { return nil }
                let lit = Huffman(lengths: Array(lengths[0..<(hlit + 257)]))
                let dist = Huffman(lengths: Array(lengths[(hlit + 257)...]))
                guard codes(&br, &out, lit, dist, limit: limit) else { return nil }
            default:
                return nil
            }
        } while final == 0
        return (out, br.pos)
    }

    private static func codes(_ br: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman, limit: Int) -> Bool {
        while true {
            guard let sym = lit.decode(&br) else { return false }
            if sym < 256 {
                guard out.count < limit else { return false }
                out.append(UInt8(sym))
            } else if sym == 256 {
                return true
            } else {
                let li = sym - 257
                guard li < lenBase.count, let le = br.bits(lenExtra[li]) else { return false }
                let len = lenBase[li] + le
                guard let ds = dist.decode(&br), ds < distBase.count, let de = br.bits(distExtra[ds]) else { return false }
                let d = distBase[ds] + de
                guard d <= out.count else { return false }
                let from = out.count - d
                guard out.count + len <= limit else { return false }
                for k in 0..<len { out.append(out[from + k]) }
            }
        }
    }
}
