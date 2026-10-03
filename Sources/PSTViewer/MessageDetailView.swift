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
                EmptyStateView(symbol: "exclamationmark.triangle", title: tr("Can't Read Message", "Kan bericht niet lezen"), subtitle: error)
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
    case message, text, headers, properties
    var id: String { rawValue }

    var title: String {
        switch self {
        case .message: return tr("Message", "Bericht")
        case .text: return tr("Plain Text", "Platte tekst")
        case .headers: return tr("Headers", "Kopteksten")
        case .properties: return tr("Properties", "Eigenschappen")
        }
    }

    var symbol: String {
        switch self {
        case .message: return "envelope"
        case .text: return "doc.plaintext"
        case .headers: return "list.bullet.rectangle"
        case .properties: return "tablecells"
        }
    }
}

struct MessageDetailView: View {
    let message: Message
    /// nil for embedded messages.
    let ref: MessageRef?
    @EnvironmentObject var model: ViewerModel
    @AppStorage("detailView") private var tab: DetailTab = .message
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
                        ? tr("This message has no internet headers.\n(Messages created in Outlook or received through Exchange often don't.)",
                             "Dit bericht bevat geen internet-kopteksten.\n(Berichten die in Outlook zijn aangemaakt of via Exchange zijn ontvangen hebben die vaak niet.)")
                        : message.transportHeaders), monospaced: true)
                case .properties: PropertiesView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(DetailToolbar(tab: $tab, print: { MessagePrinter.print(message) }, export: saveEML))
        .sheet(item: $embedded) { item in
            VStack(spacing: 0) {
                MessageDetailView(message: item.message, ref: nil)
                Divider()
                HStack {
                    Spacer()
                    Button(tr("Close", "Sluiten")) { embedded = nil }
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
        model.exportMessage(message, to: url)
    }
}

// MARK: - Toolbar

/// Icon buttons grouped like Mail's toolbar: the view switcher, then the actions.
/// On macOS 26 each group gets its own Liquid Glass capsule.
struct DetailToolbar: ViewModifier {
    @Binding var tab: DetailTab
    let print: @MainActor () -> Void
    let export: @MainActor () -> Void

    #if compiler(>=6.2)
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.toolbar {
                viewPicker
                ToolbarSpacer(.fixed, placement: .primaryAction)
                actions
            }
        } else {
            content.toolbar {
                viewPicker
                actions
            }
        }
    }
    #else
    func body(content: Content) -> some View {
        content.toolbar {
            viewPicker
            actions
        }
    }
    #endif

    @ToolbarContentBuilder
    var viewPicker: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker(tr("View", "Weergave"), selection: $tab) {
                ForEach(DetailTab.allCases) { t in
                    Image(systemName: t.symbol)
                        .accessibilityLabel(t.title)
                        .help(t.title)
                        .tag(t)
                }
            }
            .pickerStyle(.segmented)
            .help(tr("View: \(tab.title)", "Weergave: \(tab.title)"))
        }
    }

    @ToolbarContentBuilder
    var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: print) {
                Label(tr("Print", "Afdrukken"), systemImage: "printer")
            }
            .keyboardShortcut("p")
            .help(tr("Print this message or save it as PDF", "Druk dit bericht af of bewaar het als PDF"))

            Button(action: export) {
                Label(tr("Export .eml", "Exporteer .eml"), systemImage: "square.and.arrow.up")
            }
            .help(tr("Save this message as .eml (opens in Apple Mail)", "Bewaar dit bericht als .eml (te openen in Apple Mail)"))
        }
    }
}

// MARK: - Header

struct MessageHeaderView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : message.subject)
                .font(.title2.weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(3)

            HStack(alignment: .top, spacing: 10) {
                Avatar(name: message.fromName.isEmpty ? message.fromEmail : message.fromName)
                VStack(alignment: .leading, spacing: 3) {
                    // Sender and date side by side when they fit, otherwise the date goes underneath
                    // instead of both being squeezed into narrow, word-wrapped columns.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            senderText
                            Spacer()
                            dateText
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            senderText
                            dateText
                        }
                    }
                    addressLine(tr("To", "Aan"), message.to)
                    addressLine("Cc", message.cc)
                    addressLine("Bcc", message.bcc)
                    if message.importance == 2 {
                        Label(tr("High priority", "Hoge prioriteit"), systemImage: "exclamationmark.circle")
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

    var senderText: some View {
        Text(message.from.isEmpty ? tr("Unknown sender", "Onbekende afzender") : message.from)
            .font(.headline)
            .textSelection(.enabled)
    }

    @ViewBuilder
    var dateText: some View {
        if let d = message.date {
            Text(Format.longDate.string(from: d))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
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
    @AppStorage(AppSettings.darkMessagesKey) private var darkMessages = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch message.body {
        case .html(let html):
            HTMLView(html: HTMLPreparer.prepare(html, message: message, dark: darkMessages && colorScheme == .dark),
                     allowRemote: loadRemoteContent)
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
    /// With `dark`, the page is shown with inverted lightness (hues and images keep their colours),
    /// so mail with hard-coded black-on-white colours still reads well in dark mode.
    static func prepare(_ html: String, message: Message, dark: Bool = false) -> String {
        var out = html
        if out.range(of: "cid:", options: .caseInsensitive) != nil {
            for att in message.attachments where !att.contentID.isEmpty {
                let cid = att.contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                // Match the complete reference only, so `cid:image1` never touches `cid:image10`.
                let pattern = "cid:" + NSRegularExpression.escapedPattern(for: cid) + "(?=[\"'\\s)>]|$)"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                let range = NSRange(out.startIndex..., in: out)
                guard regex.firstMatch(in: out, range: range) != nil, let data = try? message.data(for: att) else { continue }
                let mime = att.mimeType.isEmpty ? mimeType(for: att.filename) : att.mimeType
                let replacement = NSRegularExpression.escapedTemplate(for: "data:\(mime);base64,\(data.base64EncodedString())")
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
            }
        }
        var style = """
        <meta name="color-scheme" content="light">
        <style>html{background:#fff;} body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;word-wrap:break-word;margin:14px;} img{max-width:100%;height:auto;}</style>
        """
        if dark {
            // #e3e3e3 inverts to #1c1c1c, close to the window background in dark mode.
            style += """
            <style>html{background:#1c1c1c;} body{background:#e3e3e3;filter:invert(1) hue-rotate(180deg);}
            img,video,picture,svg,canvas,iframe,object,embed{filter:invert(1) hue-rotate(180deg);}</style>
            """
        }
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

// MARK: - Printing

enum MessagePrinter {
    @MainActor
    static func print(_ message: Message) {
        let doc = NSMutableAttributedString()
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let regular = NSFont.systemFont(ofSize: 11)
        doc.append(NSAttributedString(string: (message.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : message.subject) + "\n",
                                      attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]))
        func line(_ label: String, _ value: String) {
            guard !value.isEmpty else { return }
            doc.append(NSAttributedString(string: label + ": ", attributes: [.font: bold]))
            doc.append(NSAttributedString(string: value + "\n", attributes: [.font: regular]))
        }
        line(tr("From", "Van"), message.from)
        line(tr("To", "Aan"), message.to)
        line("Cc", message.cc)
        if let d = message.date { line(tr("Date", "Datum"), Format.longDate.string(from: d)) }
        for (k, v) in message.details { line(k, v) }
        let names = message.attachments.filter { !$0.isHidden }.map(\.filename)
        line(tr("Attachments", "Bijlagen"), names.joined(separator: ", "))
        doc.append(NSAttributedString(string: "\n"))

        switch message.body {
        case .html(let html):
            if let data = html.data(using: .utf8),
               let a = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                          documentAttributes: nil) {
                doc.append(a)
            } else {
                doc.append(NSAttributedString(string: message.plainBody, attributes: [.font: regular]))
            }
        case .rtf(let data):
            doc.append(NSAttributedString(rtf: data, documentAttributes: nil)
                ?? NSAttributedString(string: message.plainBody, attributes: [.font: regular]))
        case .text(let text):
            doc.append(NSAttributedString(string: text, attributes: [.font: regular]))
        }

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.textStorage?.setAttributedString(doc)
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = message.subject
        op.run()
    }
}
