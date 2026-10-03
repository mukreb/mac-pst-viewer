import AppKit
import PSTKit
import SwiftUI

/// Loads a message in the background and shows it.
struct MessageContainerView: View {
    let ref: MessageRef
    @EnvironmentObject var model: ViewerModel
    @State private var message: Message?
    @State private var error: String?

    var body: some View {
        Group {
            if let message {
                MessageDetailView(message: message, ref: ref)
            } else if let error {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Kan bericht niet lezen", subtitle: error)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ref) {
            let model = self.model
            let ref = self.ref
            do {
                let m = try await Task.detached(priority: .userInitiated) { () throws -> Message in
                    let m = try await model.message(ref)
                    // Warm up lazily computed parts off the main thread.
                    _ = m.attachments
                    _ = m.recipients
                    _ = m.body
                    return m
                }.value
                message = m
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case message = "Bericht"
    case text = "Platte tekst"
    case headers = "Kopteksten"
    case properties = "Eigenschappen"
    var id: String { rawValue }
}

struct MessageDetailView: View {
    let message: Message
    /// nil for embedded messages.
    let ref: MessageRef?
    @EnvironmentObject var model: ViewerModel
    @AppStorage("detailTab") private var tab: DetailTab = .message
    @State private var embedded: EmbeddedItem?

    struct EmbeddedItem: Identifiable {
        let id = UUID()
        let message: Message
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageHeaderView(message: message)
            let visible = message.attachments.filter { !$0.isHidden || $0.contentID.isEmpty }
            if !visible.isEmpty {
                Divider()
                AttachmentBar(message: message, attachments: visible) { att in
                    if let m = try? message.embeddedMessage(att) { embedded = EmbeddedItem(message: m) }
                }
            }
            Divider()
            Group {
                switch tab {
                case .message: BodyView(message: message)
                case .text: RichTextView(text: .plain(message.plainBody))
                case .headers:
                    RichTextView(text: .plain(message.transportHeaders.isEmpty
                        ? "Dit bericht bevat geen internet-kopteksten.\n(Berichten die in Outlook zijn aangemaakt of via Exchange zijn ontvangen hebben die vaak niet.)"
                        : message.transportHeaders), monospaced: true)
                case .properties: PropertiesView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Weergave", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Weergave")

                Button {
                    saveEML()
                } label: {
                    Label("Exporteer .eml", systemImage: "square.and.arrow.up")
                }
                .help("Bewaar dit bericht als .eml (te openen in Apple Mail)")
            }
        }
        .sheet(item: $embedded) { item in
            VStack(spacing: 0) {
                MessageDetailView(message: item.message, ref: nil)
                Divider()
                HStack {
                    Spacer()
                    Button("Sluiten") { embedded = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(10)
            }
            .frame(minWidth: 700, minHeight: 520)
            .environmentObject(model)
        }
    }

    func saveEML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = EMLWriter.safeName(message.subject) + ".eml"
        panel.allowedContentTypes = [.emailMessage]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try EMLWriter.eml(for: message).write(to: url) } catch { model.errorMessage = "\(error)" }
    }
}

// MARK: - Header

struct MessageHeaderView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject.isEmpty ? "(geen onderwerp)" : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(3)

            HStack(alignment: .top, spacing: 10) {
                Avatar(name: message.fromName.isEmpty ? message.fromEmail : message.fromName)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.from.isEmpty ? "Onbekende afzender" : message.from)
                            .font(.headline)
                            .textSelection(.enabled)
                        Spacer()
                        if let d = message.date {
                            Text(Format.longDate.string(from: d))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    addressLine("Aan", message.to)
                    addressLine("Cc", message.cc)
                    addressLine("Bcc", message.bcc)
                    if message.importance == 2 {
                        Label("Hoge prioriteit", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            let details = message.details
            if !details.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(details.enumerated()), id: \.offset) { pair in
                        GridRow {
                            Text(pair.element.0).foregroundStyle(.secondary)
                            Text(pair.element.1).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func addressLine(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label + ":")
                    .foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            .font(.callout)
        }
    }
}

struct Avatar: View {
    let name: String

    var initials: String {
        let parts = name.replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "," })
            .filter { $0.first?.isLetter == true }
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .green, .indigo, .brown]
        let h = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(color.gradient, in: Circle())
    }
}

// MARK: - Body

struct BodyView: View {
    let message: Message
    @AppStorage("loadRemoteContent") private var loadRemoteContent = false

    var body: some View {
        switch message.body {
        case .html(let html):
            HTMLView(html: HTMLPreparer.prepare(html, message: message), allowRemote: loadRemoteContent)
        case .rtf(let data):
            RichTextView(text: .rtf(data))
        case .text(let text):
            if text.isEmpty && message.kind != .mail {
                Color.clear
            } else {
                RichTextView(text: .plain(text))
            }
        }
    }
}

enum HTMLPreparer {
    /// Inlines `cid:` images from the attachments and adds a base style.
    static func prepare(_ html: String, message: Message) -> String {
        var out = html
        if out.range(of: "cid:", options: .caseInsensitive) != nil {
            for att in message.attachments where !att.contentID.isEmpty {
                let cid = att.contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                guard out.contains("cid:\(cid)"), let data = try? message.data(for: att) else { continue }
                let mime = att.mimeType.isEmpty ? mimeType(for: att.filename) : att.mimeType
                out = out.replacingOccurrences(of: "cid:\(cid)", with: "data:\(mime);base64,\(data.base64EncodedString())")
            }
        }
        let style = """
        <meta name="color-scheme" content="light">
        <style>html{background:#fff;} body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;word-wrap:break-word;margin:14px;} img{max-width:100%;height:auto;}</style>
        """
        if let r = out.range(of: "<head>", options: .caseInsensitive) {
            out.insert(contentsOf: style, at: r.upperBound)
        } else {
            out = style + out
        }
        return out
    }

    static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        default: return "image/jpeg"
        }
    }
}
