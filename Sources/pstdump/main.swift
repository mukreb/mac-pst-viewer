import Foundation
import PSTKit

// Small command-line tool to inspect PST files; also used for testing the parser.
//
//   pstdump <file.pst>                 folder tree with message counts
//   pstdump <file.pst> --messages      folder tree + message list
//   pstdump <file.pst> --show <nid>    full message (hex or decimal nid)
//   pstdump <file.pst> --eml <nid>     message as .eml on stdout

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Gebruik: pstdump <bestand.pst> [--messages | --show <nid> | --eml <nid> | --props <nid>]")
    exit(1)
}

func parseNID(_ s: String) -> UInt32? {
    s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : UInt32(s)
}

do {
    let pst = try PSTFile(url: URL(fileURLWithPath: args[1]))
    let mode = args.count > 2 ? args[2] : ""
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"

    switch mode {
    case "--ref":
        // Output format matching the libpff comparison script used during development.
        func walk(_ f: Folder, _ path: String) {
            let p = path + "/" + f.name
            let msgs = ((try? pst.messages(in: f.nid)) ?? []).map { s -> (String, Int) in
                guard let m = try? pst.message(nid: s.nid) else { return ("<err>", 0) }
                return (m.subject.trimmingCharacters(in: .whitespacesAndNewlines), m.attachments.count)
            }
            print("\(p)\t\(msgs.count)")
            for (s, a) in msgs.sorted(by: { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }) { print("  \(s) | att=\(a)") }
            for c in f.children { walk(c, p) }
        }
        walk(try pst.rootFolder(), "")
    case "--table":
        guard args.count > 3, let nid = parseNID(args[3]) else { print("nid ontbreekt"); exit(1) }
        print(pst.debugTable(nid: nid))
    case "--show", "--eml", "--props":
        guard args.count > 3, let nid = parseNID(args[3]) else { print("nid ontbreekt"); exit(1) }
        let m = try pst.message(nid: nid)
        if mode == "--eml" {
            print(String(decoding: EMLWriter.eml(for: m), as: UTF8.self))
        } else if mode == "--props" {
            for p in m.allProperties {
                print(String(format: "0x%08X %@ = %@", p.tag, m.propertyName(p.id), String(p.value.description.prefix(200))))
            }
        } else {
            print("Klasse:  \(m.messageClass)")
            print("Onderwerp: \(m.subject)")
            print("Van:     \(m.from)")
            print("Aan:     \(m.to)")
            if !m.cc.isEmpty { print("Cc:      \(m.cc)") }
            print("Datum:   \(m.date.map { df.string(from: $0) } ?? "-")")
            for (k, v) in m.details { print("\(k): \(v)") }
            for a in m.attachments {
                print("Bijlage: \(a.filename) (\(a.size) bytes, methode \(a.method)\(a.isEmbeddedMessage ? ", bericht" : ""))")
            }
            switch m.body {
            case .html(let h): print("--- HTML (\(h.count) tekens) ---\n\(h.prefix(2000))")
            case .rtf(let r): print("--- RTF (\(r.count) bytes) ---\n\(RTF.plainText([UInt8](r)).prefix(2000))")
            case .text(let t): print("--- Tekst ---\n\(t.prefix(2000))")
            }
        }
    default:
        print("\(pst.displayName) — \(pst.format.rawValue), versleuteling: \(pst.encryption), \(pst.nodeCount) nodes")
        let root = try pst.rootFolder()
        func walk(_ f: Folder, _ depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let msgs = (try? pst.messages(in: f.nid)) ?? []
            print("\(indent)📁 \(f.name.isEmpty ? "(root)" : f.name)  [\(msgs.count) items, nid 0x\(String(f.nid, radix: 16))]")
            if mode == "--messages" {
                for m in msgs {
                    let d = m.date.map { df.string(from: $0) } ?? "                "
                    print("\(indent)   · 0x\(String(m.nid, radix: 16)) \(d) \(m.from.prefix(25)) — \(m.subject.prefix(60))\(m.hasAttachments ? " 📎" : "")")
                }
            }
            for c in f.children { walk(c, depth + 1) }
        }
        walk(root, 0)
    }
} catch {
    print("Fout: \(error)")
    exit(2)
}
