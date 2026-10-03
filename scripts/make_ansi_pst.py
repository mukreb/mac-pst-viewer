#!/usr/bin/env python3
"""Rewrites a Unicode (64-bit) PST into an ANSI (32-bit, Outlook 97-2002) PST.

Used to produce test fixtures for the ANSI code path, since public ANSI sample
files are scarce. The NDB layer (header, B-trees, block trailers, XBLOCK/SLBLOCK
structures) is rebuilt in the 32-bit layout; the LTP payload is copied as-is.

    python3 scripts/make_ansi_pst.py input.pst output.pst [--crypt 0|1]
"""
import struct
import sys

def load_table(name="compressible"):
    """Decode tables, taken from Crypto.swift."""
    import re, os
    src = open(os.path.join(os.path.dirname(__file__), "..", "Sources", "PSTKit", "Crypto.swift")).read()
    body = src.split("static let %s: [UInt8] = [" % name)[1].split("]")[0]
    vals = [int(x, 16) for x in re.findall(r"0x([0-9a-f]{2})", body)]
    assert len(vals) == 256
    return bytes(vals)


def load_decode_table():
    return load_table()


def inverse(t):
    return bytes(t.index(i) for i in range(256))


def encode_cyclic(data, key):
    """Inverse of the NDB_CRYPT_CYCLIC decoding in Crypto.swift."""
    comp_i, h1_i, h2_i = inverse(load_table()), inverse(load_table("high1")), inverse(load_table("high2"))
    salt = ((key >> 16) ^ key) & 0xFFFF
    out = bytearray(len(data))
    for i, x in enumerate(data):
        lo, hi = salt & 0xFF, salt >> 8
        b = (x + lo) & 0xFF
        b = (comp_i[b] + hi) & 0xFF
        b = (h2_i[b] - hi) & 0xFF
        b = (h1_i[b] - lo) & 0xFF
        out[i] = b
        salt = (salt + 1) & 0xFFFF
    return bytes(out)


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]


class UnicodePST:
    def __init__(self, path):
        self.d = open(path, "rb").read()
        d = self.d
        assert d[:4] == b"!BDN" and u16(d, 10) == 23, "input must be a Unicode PST"
        self.crypt = d[513]
        self.nodes = []   # (nid, bidData, bidSub, nidParent)
        self.blocks = {}  # bid -> (ib, cb)
        self.walk(u64(d, 240), 0x80, self.leaf_bbt)
        self.walk(u64(d, 224), 0x81, self.leaf_nbt)

    def walk(self, ib, ptype, leaf):
        p = self.d[ib:ib + 512]
        cent, cbent, level, pt = p[488], p[490], p[491], p[496]
        assert pt == ptype
        for i in range(cent):
            o = i * cbent
            if level > 0:
                self.walk(u64(p, o + 16), ptype, leaf)
            else:
                leaf(p, o)

    def leaf_bbt(self, p, o):
        self.blocks[u64(p, o) & ~1] = (u64(p, o + 8), u16(p, o + 16))

    def leaf_nbt(self, p, o):
        self.nodes.append((u32(p, o), u64(p, o + 8), u64(p, o + 16), u32(p, o + 24)))

    def block(self, bid, decode):
        ib, cb = self.blocks[bid & ~1]
        b = self.d[ib:ib + cb]
        if not bid & 2 and self.crypt == 1:
            b = bytes(decode[x] for x in b)
        return b


def crc32(data):
    # [MS-PST] 5.3: CRC-32 with initial value 0 and no final XOR.
    import zlib
    return ~zlib.crc32(data, 0xFFFFFFFF) & 0xFFFFFFFF


def convert(src, dst, crypt):
    decode = load_decode_table()
    encode = bytes(decode.index(i) for i in range(256))
    pst = UnicodePST(src)

    bidmap = {}
    counter = [1]

    def newbid(old):
        if old == 0:
            return 0
        key = old & ~1
        if key not in bidmap:
            bidmap[key] = (counter[0] << 2) | (old & 2)
            counter[0] += 1
        return bidmap[key]

    # Convert every block.
    out_blocks = {}  # newbid -> bytes (plain, before encryption)
    for bid in sorted(pst.blocks):
        nb = newbid(bid)
        data = pst.block(bid, decode)
        if bid & 2:
            btype, level, cent = data[0], data[1], u16(data, 2)
            if btype == 1:  # XBLOCK / XXBLOCK
                total = u32(data, 4)
                kids = [newbid(u64(data, 8 + i * 8)) for i in range(cent)]
                data = struct.pack("<BBHI", btype, level, cent, total) + b"".join(struct.pack("<I", k) for k in kids)
            elif btype == 2 and level == 0:  # SLBLOCK
                ents = b""
                for i in range(cent):
                    o = 8 + i * 24
                    ents += struct.pack("<III", u32(data, o), newbid(u64(data, o + 8)), newbid(u64(data, o + 16)))
                data = struct.pack("<BBH", btype, level, cent) + ents
            elif btype == 2:  # SIBLOCK
                ents = b""
                for i in range(cent):
                    o = 8 + i * 16
                    ents += struct.pack("<II", u32(data, o), newbid(u64(data, o + 8)))
                data = struct.pack("<BBH", btype, level, cent) + ents
            else:
                raise ValueError("unknown internal block type %d" % btype)
        out_blocks[nb] = data

    f = bytearray(512 * 2)  # header + padding; blocks start at 1024
    bbt_entries = []
    for nb in sorted(out_blocks):
        data = out_blocks[nb]
        stored = data
        if crypt == 1 and not nb & 2:
            stored = bytes(encode[x] for x in data)
        elif crypt == 2 and not nb & 2:
            stored = encode_cyclic(data, nb)
        ib = len(f)
        total = (len(stored) + 12 + 63) // 64 * 64
        blk = bytearray(total)
        blk[:len(stored)] = stored
        struct.pack_into("<HHII", blk, total - 12, len(stored), 0, nb, crc32(stored))
        f += blk
        bbt_entries.append((nb, ib, len(stored)))

    nbt_entries = [(nid, newbid(bd), newbid(bs), par) for nid, bd, bs, par in sorted(pst.nodes)]

    page_bid = [counter[0] + 1000]

    def write_tree(entries, ptype, leaf_pack, leaf_size):
        """Builds a B-tree bottom-up and returns (root bid, root ib)."""
        level = 0
        per_page = 496 // leaf_size
        items = entries
        packer, size = leaf_pack, leaf_size
        while True:
            pages = []
            for i in range(0, max(1, len(items)), per_page):
                chunk = items[i:i + per_page]
                while len(f) % 512:
                    f.append(0)
                ib = len(f)
                p = bytearray(512)
                for j, e in enumerate(chunk):
                    p[j * size:(j + 1) * size] = packer(e)
                pbid = (page_bid[0] << 2)
                page_bid[0] += 1
                p[496], p[497], p[498], p[499] = len(chunk), per_page, size, level
                struct.pack_into("<BBHI", p, 500, ptype, ptype, 0, pbid)
                struct.pack_into("<I", p, 508, crc32(bytes(p[:500])))
                f.extend(p)
                pages.append((chunk[0][0] if chunk else 0, pbid, ib))
            if len(pages) == 1:
                return pages[0][1], pages[0][2]
            items = pages
            packer, size = (lambda e: struct.pack("<III", e[0], e[1], e[2])), 12
            per_page = 496 // 12
            level += 1

    bbt_bid, bbt_ib = write_tree(bbt_entries, 0x80, lambda e: struct.pack("<IIHH", e[0], e[1], e[2], 2), 12)
    nbt_bid, nbt_ib = write_tree(nbt_entries, 0x81, lambda e: struct.pack("<IIII", *e), 16)

    h = bytearray(512)
    h[0:4] = b"!BDN"
    struct.pack_into("<HHHBB", h, 8, 0x4D53, 14, 19, 1, 1)
    struct.pack_into("<II", h, 24, counter[0] << 2, page_bid[0] << 2)
    struct.pack_into("<I", h, 32, 1)
    # rgnid: copy the 32 nid counters from the Unicode header (offset 44)
    h[36:164] = pst.d[44:172]
    struct.pack_into("<IIIII", h, 164, 0, len(f), 0, 0, 0)
    struct.pack_into("<II", h, 184, nbt_bid, nbt_ib)
    struct.pack_into("<II", h, 192, bbt_bid, bbt_ib)
    h[200] = 0  # fAMapValid: no allocation map
    h[204:332] = b"\xff" * 128
    h[332:460] = b"\xff" * 128
    h[460] = 0x80
    h[461] = crypt
    struct.pack_into("<I", h, 4, crc32(bytes(h[8:479])))
    f[0:512] = h
    open(dst, "wb").write(f)
    print("wrote %s: %d blocks, %d nodes, %d bytes" % (dst, len(bbt_entries), len(nbt_entries), len(f)))


if __name__ == "__main__":
    crypt = 1
    if "--crypt" in sys.argv:
        crypt = int(sys.argv[sys.argv.index("--crypt") + 1])
    convert(sys.argv[1], sys.argv[2], crypt)
