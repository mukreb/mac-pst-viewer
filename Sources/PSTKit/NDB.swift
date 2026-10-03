import Foundation

/// The three on-disk flavours of the PST/OST format.
public enum PSTFormat: String, Sendable {
    /// Outlook 97–2002, 32-bit offsets, 2 GB limit (wVer 14/15).
    case ansi = "ANSI (Outlook 97–2002)"
    /// Outlook 2003+, 64-bit offsets (wVer 23).
    case unicode = "Unicode (Outlook 2003+)"
    /// Outlook 2013+ OST with 4 KB pages and compressed blocks (wVer 36).
    case unicode4K = "Unicode 4K (Outlook 2013+ OST)"

    var is64: Bool { self != .ansi }
}

/// An entry of the node B-tree (NBT).
struct NodeEntry {
    let nid: UInt32
    let bidData: UInt64
    let bidSub: UInt64
    let nidParent: UInt32
}

/// An entry of a subnode tree (SLENTRY).
struct SubnodeEntry {
    let nid: UInt32
    let bidData: UInt64
    let bidSub: UInt64
}

/// An entry of the block B-tree (BBT).
struct BlockEntry {
    let ib: UInt64
    let cb: UInt16
}

/// Node Database layer ([MS-PST] 2.2): file header, B-trees, blocks, data trees and subnode trees.
final class NDB: @unchecked Sendable {
    let data: Data
    let format: PSTFormat
    let cryptMethod: UInt8
    private(set) var nodes: [UInt32: NodeEntry] = [:]
    private var blocks: [UInt64: BlockEntry] = [:]

    private let lock = NSLock()
    private var blockCache: [UInt64: [UInt8]] = [:]
    private var blockCacheBytes = 0
    private var subnodeCache: [UInt64: [UInt32: SubnodeEntry]] = [:]

    private var pageSize: Int { format == .unicode4K ? 4096 : 512 }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 564 else { throw PSTError.notAPSTFile }
        let header = data.bytes(at: 0, count: 580)
        // "!BDN"
        guard header.u32(0) == 0x4E44_4221 else { throw PSTError.notAPSTFile }
        let ver = header.u16(10)
        let nbtRoot: UInt64
        let bbtRoot: UInt64
        switch ver {
        case 14, 15:
            format = .ansi
            cryptMethod = header.u8(461)
            nbtRoot = UInt64(header.u32(188))
            bbtRoot = UInt64(header.u32(196))
        case 23:
            format = .unicode
            cryptMethod = header.u8(513)
            nbtRoot = header.u64(224)
            bbtRoot = header.u64(240)
        case 36:
            format = .unicode4K
            cryptMethod = header.u8(513)
            nbtRoot = header.u64(224)
            bbtRoot = header.u64(240)
        default:
            // Versions 19..22 are Unicode in practice; treat >= 23 as Unicode as well.
            if ver > 23 && ver < 36 || ver == 21 || ver == 22 {
                format = .unicode
                cryptMethod = header.u8(513)
                nbtRoot = header.u64(224)
                bbtRoot = header.u64(240)
            } else {
                throw PSTError.unsupportedVersion(ver)
            }
        }
        guard cryptMethod <= 2 else { throw PSTError.unsupportedEncryption(cryptMethod) }

        var visited = Set<UInt64>()
        walkBTree(offset: bbtRoot, expectedType: 0x80, depth: 0, visited: &visited) { page, o, cbEnt in
            let bid: UInt64, ib: UInt64, cb: UInt16
            if self.format.is64 {
                bid = page.u64(o); ib = page.u64(o + 8); cb = page.u16(o + 16)
            } else {
                bid = UInt64(page.u32(o)); ib = UInt64(page.u32(o + 4)); cb = page.u16(o + 8)
            }
            self.blocks[bid & ~1] = BlockEntry(ib: ib, cb: cb)
        }
        visited.removeAll()
        walkBTree(offset: nbtRoot, expectedType: 0x81, depth: 0, visited: &visited) { page, o, cbEnt in
            let e: NodeEntry
            if self.format.is64 {
                e = NodeEntry(nid: page.u32(o), bidData: page.u64(o + 8), bidSub: page.u64(o + 16), nidParent: page.u32(o + 24))
            } else {
                e = NodeEntry(nid: page.u32(o), bidData: UInt64(page.u32(o + 4)), bidSub: UInt64(page.u32(o + 8)), nidParent: page.u32(o + 12))
            }
            self.nodes[e.nid] = e
        }
        if nodes.isEmpty { throw PSTError.corrupt("de node-index is leeg") }
    }

    var nodeCount: Int { nodes.count }

    /// Nodes grouped by their parent NID (built on first use).
    private lazy var childrenByParent: [UInt32: [NodeEntry]] = Dictionary(grouping: nodes.values, by: \.nidParent)

    func children(of nid: UInt32) -> [NodeEntry] {
        lock.lock()
        defer { lock.unlock() }
        return childrenByParent[nid] ?? []
    }
    var blockCount: Int { blocks.count }

    // MARK: - B-tree pages

    private func walkBTree(offset: UInt64, expectedType: UInt8, depth: Int, visited: inout Set<UInt64>,
                           leaf: ([UInt8], Int, Int) -> Void) {
        guard depth < 16, offset > 0, offset < UInt64(data.count), !visited.contains(offset) else { return }
        visited.insert(offset)
        let page = data.bytes(at: Int(offset), count: pageSize)
        guard page.count == pageSize else { return }

        let cEnt: Int, cbEnt: Int, cLevel: Int, ptype: UInt8, entriesSize: Int
        switch format {
        case .ansi:
            cEnt = Int(page.u8(496)); cbEnt = Int(page.u8(498)); cLevel = Int(page.u8(499)); ptype = page.u8(500)
            entriesSize = 496
        case .unicode:
            cEnt = Int(page.u8(488)); cbEnt = Int(page.u8(490)); cLevel = Int(page.u8(491)); ptype = page.u8(496)
            entriesSize = 488
        case .unicode4K:
            cEnt = Int(page.u16(4056)); cbEnt = Int(page.u8(4060)); cLevel = Int(page.u8(4061)); ptype = page.u8(4072)
            entriesSize = 4056
        }
        guard ptype == expectedType, cbEnt > 0, cEnt * cbEnt <= entriesSize else { return }

        for i in 0..<cEnt {
            let o = i * cbEnt
            if cLevel > 0 {
                // BTENTRY: key, BREF(bid, ib)
                let child: UInt64 = format.is64 ? page.u64(o + 16) : UInt64(page.u32(o + 8))
                walkBTree(offset: child, expectedType: expectedType, depth: depth + 1, visited: &visited, leaf: leaf)
            } else {
                leaf(page, o, cbEnt)
            }
        }
    }

    // MARK: - Blocks

    /// Reads, decompresses and decrypts a single block.
    func block(_ bid: UInt64) throws -> [UInt8] {
        let key = bid & ~1
        lock.lock()
        if let cached = blockCache[key] { lock.unlock(); return cached }
        lock.unlock()

        guard let entry = blocks[key] else { throw PSTError.notFound(String(format: "blok 0x%llx", bid)) }
        let size = Int(entry.cb)
        guard entry.ib + UInt64(size) <= UInt64(data.count) else { throw PSTError.corrupt("blok buiten bestand") }
        var bytes = data.bytes(at: Int(entry.ib), count: size)

        let isInternal = (bid & 0x2) != 0
        if format == .unicode4K {
            // The block footer stores the uncompressed size; if it differs, the data is zlib-compressed.
            var total = (size + 511) / 512 * 512
            if total - size < 24 { total += 512 }
            let footer = data.bytes(at: Int(entry.ib) + total - 24, count: 24)
            let rawSize = Int(footer.u16(18))
            if rawSize > size, footer.count == 24 {
                if let inflated = Inflate.zlib(bytes, expectedSize: rawSize) {
                    bytes = inflated
                }
            }
        }
        if !isInternal {
            switch cryptMethod {
            case 1: PSTCrypto.decodePermute(&bytes)
            case 2: PSTCrypto.decodeCyclic(&bytes, key: UInt32(truncatingIfNeeded: bid))
            default: break
            }
        }

        lock.lock()
        if blockCacheBytes > 64 * 1024 * 1024 {
            blockCache.removeAll(keepingCapacity: true)
            blockCacheBytes = 0
        }
        blockCache[key] = bytes
        blockCacheBytes += bytes.count
        lock.unlock()
        return bytes
    }

    /// Returns the list of data blocks of a data tree (resolving XBLOCK/XXBLOCK).
    func dataBlocks(_ bid: UInt64, depth: Int = 0) throws -> [[UInt8]] {
        guard bid != 0 else { return [] }
        let b = try block(bid)
        guard (bid & 0x2) != 0 else { return [b] }
        // XBLOCK / XXBLOCK
        guard b.u8(0) == 0x01, depth < 3 else { throw PSTError.corrupt("onverwacht interne blok") }
        let level = b.u8(1)
        let count = Int(b.u16(2))
        let width = format.is64 ? 8 : 4
        var result: [[UInt8]] = []
        for i in 0..<count {
            let o = 8 + i * width
            let child = format.is64 ? b.u64(o) : UInt64(b.u32(o))
            if level == 1 {
                result.append(try block(child))
            } else {
                result.append(contentsOf: try dataBlocks(child, depth: depth + 1))
            }
        }
        return result
    }

    /// Returns the data of a data tree as one contiguous buffer.
    func dataStream(_ bid: UInt64) throws -> [UInt8] {
        let parts = try dataBlocks(bid)
        if parts.count == 1 { return parts[0] }
        return Array(parts.joined())
    }

    /// Parses a subnode tree (SLBLOCK/SIBLOCK) into a flat map.
    func subnodes(_ bid: UInt64) throws -> [UInt32: SubnodeEntry] {
        guard bid != 0 else { return [:] }
        lock.lock()
        if let cached = subnodeCache[bid] { lock.unlock(); return cached }
        lock.unlock()
        var result: [UInt32: SubnodeEntry] = [:]
        try collectSubnodes(bid, depth: 0, into: &result)
        lock.lock()
        subnodeCache[bid] = result
        lock.unlock()
        return result
    }

    private func collectSubnodes(_ bid: UInt64, depth: Int, into result: inout [UInt32: SubnodeEntry]) throws {
        guard depth < 4 else { return }
        let b = try block(bid)
        guard b.u8(0) == 0x02 else { throw PSTError.corrupt("ongeldig subnode-blok") }
        let level = b.u8(1)
        let count = Int(b.u16(2))
        let start = format.is64 ? 8 : 4
        if level == 0 {
            let width = format.is64 ? 24 : 12
            for i in 0..<count {
                let o = start + i * width
                let e: SubnodeEntry
                if format.is64 {
                    e = SubnodeEntry(nid: b.u32(o), bidData: b.u64(o + 8), bidSub: b.u64(o + 16))
                } else {
                    e = SubnodeEntry(nid: b.u32(o), bidData: UInt64(b.u32(o + 4)), bidSub: UInt64(b.u32(o + 8)))
                }
                result[e.nid] = e
            }
        } else {
            let width = format.is64 ? 16 : 8
            for i in 0..<count {
                let o = start + i * width
                let child = format.is64 ? b.u64(o + 8) : UInt64(b.u32(o + 4))
                try collectSubnodes(child, depth: depth + 1, into: &result)
            }
        }
    }
}
