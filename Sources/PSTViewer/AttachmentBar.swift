import AppKit
import PSTKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct AttachmentBar: View {
    let message: Message
    let attachments: [Attachment]
    let openEmbedded: (Attachment) -> Void
    @EnvironmentObject var model: ViewerModel
    @State private var quickLookURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(attachments) { att in
                        AttachmentChip(attachment: att)
                            .onTapGesture(count: 2) { open(att) }
                            .onTapGesture { preview(att) }
                            .contextMenu {
                                if att.isEmbeddedMessage {
                                    Button("Open bericht") { openEmbedded(att) }
                                } else {
                                    Button("Snel bekijken") { preview(att) }
                                    Button("Open") { open(att) }
                                }
                                Button("Bewaar als…") { save(att) }
                            }
                            .help(att.isEmbeddedMessage ? "Klik om het bijgevoegde bericht te openen"
                                                        : "Klik: snel bekijken · dubbelklik: openen")
                    }
                }
                .padding(.vertical, 6)
            }
            if attachments.count > 1 {
                Button("Alles bewaren…") { saveAll() }
                    .controlSize(.small)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .quickLookPreview($quickLookURL)
    }

    // MARK: Actions

    func preview(_ att: Attachment) {
        if att.isEmbeddedMessage { openEmbedded(att); return }
        quickLookURL = try? temporaryFile(for: att)
    }

    func open(_ att: Attachment) {
        if att.isEmbeddedMessage { openEmbedded(att); return }
        do {
            NSWorkspace.shared.open(try temporaryFile(for: att))
        } catch {
            model.errorMessage = "Kan bijlage niet openen: \(error)"
        }
    }

    func save(_ att: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(for: att)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try contents(of: att).write(to: url) } catch { model.errorMessage = "\(error)" }
    }

    func saveAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Bewaar hier"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var used = Set<String>()
        var failures: [String] = []
        for att in attachments {
            let name = fileName(for: att)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let url = ViewerModel.uniqueURL(in: dir, base: base, ext: ext.isEmpty ? "bin" : ext, used: &used)
            do {
                try contents(of: att).write(to: url)
            } catch {
                failures.append("• \(att.filename): \(error.localizedDescription)")
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        if !failures.isEmpty {
            model.errorMessage = "\(failures.count) bijlage(n) konden niet worden bewaard:\n\n" + failures.joined(separator: "\n")
        }
    }

    // MARK: Files

    func fileName(for att: Attachment) -> String {
        let name = EMLWriter.safeName(att.filename)
        return att.isEmbeddedMessage && !name.lowercased().hasSuffix(".eml") ? name + ".eml" : name
    }

    func contents(of att: Attachment) throws -> Data {
        if att.isEmbeddedMessage, let m = try message.embeddedMessage(att) {
            return try EMLWriter.eml(for: m)
        }
        return try message.data(for: att)
    }

    /// Preview/open copies live here; the folder is emptied at launch and at quit.
    static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PSTViewer", isDirectory: true)

    static func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func temporaryFile(for att: Attachment) throws -> URL {
        // A fresh directory per request: NIDs and file names are only unique within one PST,
        // and several PSTs can be open at the same time.
        let dir = AttachmentBar.temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: att))
        try contents(of: att).write(to: url)
        return url
    }
}

struct AttachmentChip: View {
    let attachment: Attachment

    var icon: NSImage {
        if attachment.isEmbeddedMessage {
            return NSImage(systemSymbolName: "envelope", accessibilityDescription: nil) ?? NSImage()
        }
        let ext = (attachment.filename as NSString).pathExtension
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                if attachment.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
