import Foundation
import PSTKit

// Small command-line tool to inspect PST files and mbox archives; also used for testing the parser.
//
//   pstdump <file.pst | mbox | folder> folder tree with message counts
//   pstdump <file.pst> --messages      folder tree + message list
//   pstdump <file.pst> --show <nid>    full message (hex or decimal nid)
//   pstdump <file.pst> --eml <nid>     message as .eml on stdout
//   pstdump <source>... --mbox <out.mbox> [--search "words"] [--body] [--folder <text>] [--append]
//                                      matching messages of one or more archives in one mbox file

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("""
    Usage: pstdump <file.pst | mbox file | mail folder> [--messages | --show <nid> | --eml <nid> | --props <nid>]
           pstdump <source>... --mbox <out.mbox> [--search "words"] [--body] [--folder <text>] [--append]
    """)
    exit(1)
}

/// `--mbox`: writes the messages of all sources that match the filter to one mbox file.
func exportMbox() -> Never {
    var sources: [String] = []
    var output: String?
    var query = ""
    var folder: String?
    var body = false
    var append = false
    var rest = args.dropFirst()
    func value(_ flag: String) -> String {
        guard let v = rest.popFirst() else {
            FileHandle.standardError.write(Data("\(flag) needs a value\n".utf8))
            exit(1)
        }
        return v
    }
    while let a = rest.popFirst() {
        switch a {
        case "--mbox": output = value(a)
        case "--search": query = value(a)
        case "--folder": folder = value(a)
        case "--body": body = true
        case "--append": append = true
        default:
            if a.hasPrefix("--") {
                FileHandle.standardError.write(Data("Unknown option \(a) for --mbox\n".utf8))
                exit(1)
            }
            sources.append(a)
        }
    }
    guard let output, !sources.isEmpty else {
        FileHandle.standardError.write(Data("--mbox needs an output file and at least one source\n".utf8))
        exit(1)
    }
    let out = URL(fileURLWithPath: output).standardizedFileURL
    // Never write over (or into) an archive that is being read.
    for src in sources {
        let s = URL(fileURLWithPath: src).standardizedFileURL.path
        if out.path == s || out.path.hasPrefix(s.hasSuffix("/") ? s : s + "/") {
            FileHandle.standardError.write(Data("The output file can't be inside a source: \(src)\n".utf8))
            exit(1)
        }
    }
    do {
        let stores = try sources.map { try MailStores.open(URL(fileURLWithPath: $0)) }
        let filter = MailFilter(query: query, searchBodies: body, folder: folder)
        var lastReported = 0
        let report = try MboxExport.export(stores: stores, filter: filter, to: out, append: append) { r in
            if r.scanned - lastReported >= 1000 {
                lastReported = r.scanned
                FileHandle.standardError.write(Data("  \(r.scanned) checked, \(r.written) exported…\n".utf8))
            }
        }
        print("\(report.written) message(s) written to \(out.path) (\(report.scanned) checked, \(report.duplicates) duplicate(s) skipped)")
        if !report.failures.isEmpty {
            print("\(report.failures.count) message(s) or folder(s) couldn't be read:")
            for f in report.failures.prefix(20) { print("  \(f)") }
            if report.failures.count > 20 { print("  … and \(report.failures.count - 20) more") }
        }
        exit(report.failures.isEmpty ? 0 : 3)
    } catch {
        print("Error: \(error)")
        exit(2)
    }
}

if args.contains("--mbox") { exportMbox() }

func parseNID(_ s: String) -> UInt32? {
    s.hasPrefix("0x") ? UInt32(s.dropFirst(2), radix: 16) : UInt32(s)
}

do {
    let pst = try MailStores.open(URL(fileURLWithPath: args[1]))
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
        guard args.count > 3, let nid = parseNID(args[3]) else { print("missing nid"); exit(1) }
        guard let file = pst as? PSTFile else { print("--table needs a PST file"); exit(1) }
        print(file.debugTable(nid: nid))
    case "--show", "--eml", "--props":
        guard args.count > 3, let nid = parseNID(args[3]) else { print("missing nid"); exit(1) }
        let m = try pst.message(nid: nid)
        if mode == "--eml" {
            print(String(decoding: try EMLWriter.eml(for: m), as: UTF8.self))
        } else if mode == "--props" {
            for p in m.allProperties {
                print(String(format: "0x%08X %@ = %@", p.tag, m.propertyName(p.id), String(p.value.description.prefix(200))))
            }
        } else {
            print("Class:   \(m.messageClass)")
            print("Subject: \(m.subject)")
            print("From:    \(m.from)")
            print("To:      \(m.to)")
            if !m.cc.isEmpty { print("Cc:      \(m.cc)") }
            print("Date:    \(m.date.map { df.string(from: $0) } ?? "-")")
            for (k, v) in m.details { print("\(k): \(v)") }
            for a in m.attachments {
                print("Attachment: \(a.filename) (\(a.size) bytes, method \(a.method)\(a.isEmbeddedMessage ? ", message" : ""))")
            }
            switch m.body {
            case .html(let h): print("--- HTML (\(h.count) characters) ---\n\(h.prefix(2000))")
            case .rtf(let r): print("--- RTF (\(r.count) bytes) ---\n\(RTF.plainText([UInt8](r)).prefix(2000))")
            case .text(let t): print("--- Text ---\n\(t.prefix(2000))")
            }
        }
    default:
        if let file = pst as? PSTFile {
            print("\(file.displayName) — \(file.format.rawValue), encryption: \(file.encryption), \(file.nodeCount) nodes")
        } else {
            print("\(pst.displayName) — mbox")
        }
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
    print("Error: \(error)")
    exit(2)
}
