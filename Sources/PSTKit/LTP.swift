import Foundation

/// A node (or subnode) with access to its data stream and its subnode tree.
struct NodeRef {
    let ndb: NDB
    let nid: UInt32
    let bidData: UInt64
    let bidSub: UInt64

    func subnodes() throws -> [UInt32: SubnodeEntry] { try ndb.subnodes(bidSub) }

    func subnode(_ nid: UInt32) throws -> NodeRef? {
        guard let e = try subnodes()[nid] else { return nil }
        return NodeRef(ndb: ndb, nid: e.nid, bidData: e.bidData, bidSub: e.bidSub)
    }
}

// MARK: - Heap-on-Node

/// Heap-on-Node ([MS-PST] 2.3.1).
struct Heap {
    let node: NodeRef
    let pages: [[UInt8]]
    let clientSig: UInt8
    let userRoot: UInt32

    init(_ node: NodeRef) throws {
        self.node = node
        pages = try node.ndb.dataBlocks(node.bidData)
        guard let first = pages.first, first.count >= 12, first.u8(2) == 0xEC else {
            throw PSTError.corrupt("ongeldige heap (nid 0x\(String(node.nid, radix: 16)))")
        }
        clientSig = first.u8(3)
        userRoot = first.u32(4)
    }

    /// Returns the bytes of a heap allocation.
    func item(_ hid: UInt32) -> [UInt8]? {
        guard hid != 0, hid & 0x1F == 0 else { return nil }
        let index = Int((hid >> 5) & 0x7FF)
        let blockIndex = Int(hid >> 16)
        guard index > 0, blockIndex < pages.count else { return nil }
        let page = pages[blockIndex]
        let mapOffset = Int(page.u16(0))
        let cAlloc = Int(page.u16(mapOffset))
        guard index <= cAlloc else { return nil }
        let start = Int(page.u16(mapOffset + 4 + (index - 1) * 2))
        let end = Int(page.u16(mapOffset + 4 + index * 2))
        guard end >= start, end <= page.count else { return nil }
        return Array(page[start..<end])
    }

    /// Resolves a HNID: either a heap item or a subnode's data stream.
    func value(_ hnid: UInt32) throws -> [UInt8] {
        if hnid == 0 { return [] }
        if hnid & 0x1F == 0 { return item(hnid) ?? [] }
        guard let sub = try node.subnode(hnid) else { return [] }
        return try node.ndb.dataStream(sub.bidData)
    }
}

// MARK: - BTree-on-Heap

struct BTH {
    let heap: Heap
    let keySize: Int
    let entrySize: Int
    let levels: Int
    let root: UInt32

    init(heap: Heap, header: UInt32) throws {
        self.heap = heap
        guard let h = heap.item(header), h.count >= 8, h.u8(0) == 0xB5 else {
            throw PSTError.corrupt("ongeldige BTH-header")
        }
        keySize = Int(h.u8(1))
        entrySize = Int(h.u8(2))
        levels = Int(h.u8(3))
        root = h.u32(4)
    }

    /// All (key, data) records in the tree.
    func records() -> [(key: [UInt8], data: [UInt8])] {
        var out: [(key: [UInt8], data: [UInt8])] = []
        collect(root, level: levels, into: &out)
        return out
    }

    private func collect(_ hid: UInt32, level: Int, into out: inout [(key: [UInt8], data: [UInt8])]) {
        guard let bytes = heap.item(hid) else { return }
        if level == 0 {
            let rec = keySize + entrySize
            guard rec > 0 else { return }
            var o = 0
            while o + rec <= bytes.count {
                out.append((Array(bytes[o..<(o + keySize)]), Array(bytes[(o + keySize)..<(o + rec)])))
                o += rec
            }
        } else {
            let rec = keySize + 4
            var o = 0
            while o + rec <= bytes.count {
                collect(bytes.u32(o + keySize), level: level - 1, into: &out)
                o += rec
            }
        }
    }
}

// MARK: - Property Context

/// Property Context ([MS-PST] 2.3.3): the property bag of a folder, message, attachment, ...
public struct PropertyContext {
    let heap: Heap
    let entries: [UInt16: (type: UInt16, raw: UInt32)]

    init(_ node: NodeRef) throws {
        heap = try Heap(node)
        guard heap.clientSig == 0xBC else { throw PSTError.corrupt("geen property context") }
        let bth = try BTH(heap: heap, header: heap.userRoot)
        var e: [UInt16: (type: UInt16, raw: UInt32)] = [:]
        for r in bth.records() where r.key.count == 2 && r.data.count >= 6 {
            e[r.key.u16(0)] = (r.data.u16(0), r.data.u32(2))
        }
        entries = e
    }

    var propertyIDs: [UInt16] { entries.keys.sorted() }

    func value(_ id: UInt16) -> PropertyValue? {
        guard let e = entries[id] else { return nil }
        return try? PropertyValue.decode(type: e.type, inline: e.raw, heap: heap)
    }

    func all() -> [Property] {
        propertyIDs.compactMap { id in
            guard let e = entries[id] else { return nil }
            let v = (try? PropertyValue.decode(type: e.type, inline: e.raw, heap: heap)) ?? .error(0)
            return Property(id: id, type: e.type, value: v)
        }
    }
}

// MARK: - Table Context

/// Table Context ([MS-PST] 2.3.4): rows such as folder hierarchy, contents, recipients and attachments.
struct TableContext {
    struct Column {
        let tag: UInt32
        let offset: Int
        let size: Int
        let bit: Int
        var id: UInt16 { UInt16(tag >> 16) }
        var type: UInt16 { UInt16(tag & 0xFFFF) }
    }

    let heap: Heap
    let columns: [Column]
    let rowSize: Int
    let cebOffset: Int
    private let rowBlocks: [[UInt8]]
    private let rowsPerBlock: Int
    let rowCount: Int

    init(_ node: NodeRef) throws {
        heap = try Heap(node)
        guard heap.clientSig == 0x7C, let info = heap.item(heap.userRoot), info.u8(0) == 0x7C else {
            throw PSTError.corrupt("geen table context")
        }
        let cCols = Int(info.u8(1))
        cebOffset = Int(info.u16(6))
        rowSize = Int(info.u16(8))
        let hnidRows = info.u32(14)
        var cols: [Column] = []
        for i in 0..<cCols {
            let o = 22 + i * 8
            cols.append(Column(tag: info.u32(o), offset: Int(info.u16(o + 4)), size: Int(info.u8(o + 6)), bit: Int(info.u8(o + 7))))
        }
        columns = cols

        if hnidRows == 0 || rowSize == 0 {
            rowBlocks = []
        } else if hnidRows & 0x1F == 0 {
            rowBlocks = [heap.item(hnidRows) ?? []]
        } else if let sub = try node.subnode(hnidRows) {
            rowBlocks = try node.ndb.dataBlocks(sub.bidData)
        } else {
            rowBlocks = []
        }
        if rowSize > 0, let first = rowBlocks.first {
            rowsPerBlock = Swift.max(1, rowBlocks.count > 1 ? first.count / rowSize : Swift.max(first.count / rowSize, 1))
            let size = rowSize
            rowCount = rowBlocks.reduce(0) { $0 + $1.count / size }
        } else {
            rowsPerBlock = 1
            rowCount = 0
        }
    }

    func rowBytes(_ i: Int) -> [UInt8]? {
        guard i >= 0, i < rowCount else { return nil }
        let b = i / rowsPerBlock
        let o = (i % rowsPerBlock) * rowSize
        guard b < rowBlocks.count, o + rowSize <= rowBlocks[b].count else { return nil }
        return Array(rowBlocks[b][o..<(o + rowSize)])
    }

    /// Returns the values of one row keyed by property id.
    func row(_ i: Int) -> TableRow? {
        guard let bytes = rowBytes(i) else { return nil }
        var values: [UInt16: PropertyValue] = [:]
        for c in columns {
            let byte = cebOffset + c.bit / 8
            guard byte < bytes.count, bytes[byte] & (0x80 >> UInt8(c.bit % 8)) != 0 else { continue }
            let cell = bytes.slice(c.offset, c.size)
            guard cell.count == c.size else { continue }
            let v: PropertyValue?
            switch c.size {
            case 8 where PropertyValue.isFixed8(c.type):
                v = PropertyValue.decodeFixed(type: c.type, bytes: cell)
            case 1, 2, 4:
                if PropertyValue.isVariable(c.type) {
                    v = try? PropertyValue.decode(type: c.type, inline: cell.u32(0), heap: heap)
                } else {
                    var padded = cell
                    padded.append(contentsOf: [UInt8](repeating: 0, count: 8 - cell.count))
                    v = PropertyValue.decodeFixed(type: c.type, bytes: padded)
                }
            default:
                v = PropertyValue.decodeFixed(type: c.type, bytes: cell)
            }
            if let v { values[c.id] = v }
        }
        let rowID = bytes.u32(0)
        return TableRow(rowID: rowID, values: values)
    }

    func rows() -> [TableRow] {
        (0..<rowCount).compactMap { row($0) }
    }
}

struct TableRow {
    let rowID: UInt32
    let values: [UInt16: PropertyValue]
    subscript(_ id: UInt16) -> PropertyValue? { values[id] }
}
