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
                                    Button(tr("Open Message", "Open bericht")) { openEmbedded(att) }
                                } else {
                                    Button(tr("Quick Look", "Snel bekijken")) { preview(att) }
                                    Button(tr("Open", "Open")) { open(att) }
                                }
                                Button(tr("Save As…", "Bewaar als…")) { save(att) }
                            }
                            .help(att.isEmbeddedMessage ? tr("Click to open the attached message", "Klik om het bijgevoegde bericht te openen")
                                                        : tr("Click: Quick Look · double-click: open", "Klik: snel bekijken · dubbelklik: openen"))
                    }
                }
                .padding(.vertical, 6)
            }
            if attachments.count > 1 {
                Button(tr("Save All…", "Alles bewaren…")) { saveAll() }
                    .controlSize(.small)
                    .glassButtonStyle()
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .quickLookPreview($quickLookURL)
    }

    // MARK: Actions
    // Reading an attachment can mean reassembling a large data tree from the PST, so all
    // extraction and file I/O runs in the background; only UI updates return to the main actor.

    func preview(_ att: Attachment) {
        if att.isEmbeddedMessage { openEmbedded(att); return }
        let message = self.message
        Task.detached(priority: .userInitiated) {
            let result = Result { try AttachmentBar.temporaryFile(message: message, att: att) }
            await MainActor.run {
                switch result {
                case .success(let url): quickLookURL = url
                case .failure(let error): model.errorMessage = tr("Can't show attachment: \(error)", "Kan bijlage niet tonen: \(error)")
                }
            }
        }
    }

    func open(_ att: Attachment) {
        if att.isEmbeddedMessage { openEmbedded(att); return }
        let message = self.message
        Task.detached(priority: .userInitiated) {
            let result = Result { try AttachmentBar.temporaryFile(message: message, att: att) }
            await MainActor.run {
                switch result {
                case .success(let url): NSWorkspace.shared.open(url)
                case .failure(let error): model.errorMessage = tr("Can't open attachment: \(error)", "Kan bijlage niet openen: \(error)")
                }
            }
        }
    }

    func save(_ att: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentBar.fileName(for: att)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let message = self.message
        Task.detached(priority: .userInitiated) {
            do {
                try AttachmentBar.contents(message: message, att: att).write(to: url)
            } catch {
                await MainActor.run { model.errorMessage = "\(error)" }
            }
        }
    }

    func saveAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Save Here", "Bewaar hier")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let message = self.message
        let attachments = self.attachments
        Task.detached(priority: .userInitiated) {
            var used = Set<String>()
            var failures: [String] = []
            for att in attachments {
                let name = AttachmentBar.fileName(for: att)
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                let url = ViewerModel.uniqueURL(in: dir, base: base, ext: ext.isEmpty ? "bin" : ext, used: &used)
                do {
                    try AttachmentBar.contents(message: message, att: att).write(to: url)
                } catch {
                    failures.append("• \(att.filename): \(error.localizedDescription)")
                }
            }
            let failed = failures
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([dir])
                if !failed.isEmpty {
                    model.errorMessage = tr("\(failed.count) attachment(s) couldn't be saved:", "\(failed.count) bijlage(n) konden niet worden bewaard:")
                        + "\n\n" + failed.joined(separator: "\n")
                }
            }
        }
    }

    // MARK: Files
    // nonisolated: these run in detached tasks and touch no view or model state.

    nonisolated static func fileName(for att: Attachment) -> String {
        let name = EMLWriter.safeName(att.filename)
        return att.isEmbeddedMessage && !name.lowercased().hasSuffix(".eml") ? name + ".eml" : name
    }

    nonisolated static func contents(message: Message, att: Attachment) throws -> Data {
        if att.isEmbeddedMessage, let m = try message.embeddedMessage(att) {
            return try EMLWriter.eml(for: m)
        }
        return try message.data(for: att)
    }

    /// Preview/open copies live here; the folder is emptied at launch and at quit.
    nonisolated static let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PSTViewer", isDirectory: true)

    nonisolated static func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    nonisolated static func temporaryFile(message: Message, att: Attachment) throws -> URL {
        // A fresh directory per request: NIDs and file names are only unique within one PST,
        // and several PSTs can be open at the same time.
        let dir = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(for: att))
        try contents(message: message, att: att).write(to: url)
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
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .contentShape(Capsule())
    }
}
