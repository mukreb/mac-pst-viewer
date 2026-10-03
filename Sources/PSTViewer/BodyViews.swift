import AppKit
import PSTKit
import SwiftUI
import WebKit

// MARK: - HTML

struct HTMLView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(allowRemote)|\(html.hashValue)"
        guard context.coordinator.loadedKey != key else { return }
        context.coordinator.loadedKey = key
        let html = self.html
        Coordinator.applyRules(to: view, allowRemote: allowRemote) {
            view.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey = ""
        private static var blockRules: WKContentRuleList?

        /// Blocks remote content (tracking pixels, dead links to old servers) unless allowed.
        static func applyRules(to view: WKWebView, allowRemote: Bool, then load: @escaping () -> Void) {
            let controller = view.configuration.userContentController
            controller.removeAllContentRuleLists()
            if allowRemote { load(); return }
            if let rules = blockRules {
                controller.add(rules)
                load()
                return
            }
            let json = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: json) { list, _ in
                DispatchQueue.main.async {
                    if let list {
                        blockRules = list
                        controller.add(list)
                    }
                    load()
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Rich / plain text

enum RichText {
    case plain(String)
    case rtf(Data)
}

struct RichTextView: NSViewRepresentable {
    let text: RichText
    var monospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = true
            tv.textContainerInset = NSSize(width: 12, height: 12)
            tv.drawsBackground = true
            tv.backgroundColor = .textBackgroundColor
            tv.isAutomaticLinkDetectionEnabled = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let attributed: NSAttributedString
        switch text {
        case .plain(let s):
            let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)
            let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
            let m = NSMutableAttributedString(string: normalized, attributes: [.font: font, .foregroundColor: NSColor.textColor])
            Self.linkify(m)
            attributed = m
        case .rtf(let data):
            if let a = NSAttributedString(rtf: data, documentAttributes: nil) {
                attributed = Self.adaptForDarkMode(a)
            } else {
                attributed = NSAttributedString(string: RTF.plainText([UInt8](data)))
            }
        }
        if tv.textStorage?.isEqual(to: attributed) != true {
            tv.textStorage?.setAttributedString(attributed)
            tv.scrollToBeginningOfDocument(nil)
        }
    }

    /// Black text in old RTF mail is unreadable in dark mode; map it to the dynamic text colour.
    static func adaptForDarkMode(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        let range = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.foregroundColor, in: range) { value, r, _ in
            let color = (value as? NSColor)?.usingColorSpace(.sRGB)
            if color == nil || (color!.redComponent < 0.15 && color!.greenComponent < 0.15 && color!.blueComponent < 0.15) {
                m.addAttribute(.foregroundColor, value: NSColor.textColor, range: r)
            }
        }
        // Outlook's default 10pt RTF text is tiny on a Mac screen.
        m.enumerateAttribute(.font, in: range) { value, r, _ in
            if let f = value as? NSFont, f.pointSize < 13 {
                m.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: f.pointSize * 1.3), range: r)
            }
        }
        m.enumerateAttribute(.backgroundColor, in: range) { value, r, _ in
            if let c = (value as? NSColor)?.usingColorSpace(.sRGB), c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 {
                m.removeAttribute(.backgroundColor, range: r)
            }
        }
        return m
    }

    static func linkify(_ m: NSMutableAttributedString) {
        guard m.length < 2_000_000,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        for match in detector.matches(in: m.string, range: NSRange(location: 0, length: m.length)) {
            if let url = match.url { m.addAttribute(.link, value: url, range: match.range) }
        }
    }
}

// MARK: - Properties inspector

struct PropertyItem: Identifiable {
    let id: UInt16
    let tag: String
    let name: String
    let type: String
    let value: String
}

struct PropertiesView: View {
    let message: Message
    @State private var filter = ""

    var items: [PropertyItem] {
        message.allProperties.map { p in
            PropertyItem(id: p.id, tag: String(format: "0x%08X", p.tag), name: message.propertyName(p.id),
                         type: Self.typeName(p.type), value: Self.valueString(p.value, codepage: message.codepage))
        }
    }

    var body: some View {
        let shown = filter.isEmpty ? items : items.filter {
            $0.name.localizedCaseInsensitiveContains(filter) || $0.value.localizedCaseInsensitiveContains(filter)
                || $0.tag.localizedCaseInsensitiveContains(filter)
        }
        VStack(spacing: 0) {
            TextField("Filter eigenschappen", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Table(shown) {
                TableColumn("Tag") { Text($0.tag).font(.system(.caption, design: .monospaced)) }
                    .width(min: 80, ideal: 90, max: 100)
                TableColumn("Naam") { Text($0.name).lineLimit(1).help($0.name) }
                    .width(min: 120, ideal: 200)
                TableColumn("Type") { Text($0.type).foregroundStyle(.secondary) }
                    .width(min: 50, ideal: 70, max: 90)
                TableColumn("Waarde") { item in
                    Text(item.value).lineLimit(2).textSelection(.enabled).help(String(item.value.prefix(1000)))
                }
            }
        }
    }

    static func typeName(_ t: UInt16) -> String {
        let base: String
        switch t & 0x0FFF {
        case 0x0002: base = "Int16"
        case 0x0003: base = "Int32"
        case 0x0004: base = "Float"
        case 0x0005: base = "Double"
        case 0x0006: base = "Currency"
        case 0x0007: base = "AppTime"
        case 0x000A: base = "Error"
        case 0x000B: base = "Bool"
        case 0x000D: base = "Object"
        case 0x0014: base = "Int64"
        case 0x001E: base = "String8"
        case 0x001F: base = "Unicode"
        case 0x0040: base = "Time"
        case 0x0048: base = "GUID"
        case 0x0102: base = "Binary"
        default: base = String(format: "0x%04X", t)
        }
        return t & 0x1000 != 0 ? "Multi" + base : base
    }

    static func valueString(_ v: PropertyValue, codepage: Int) -> String {
        switch v {
        case .string8: return v.stringValue(codepage: codepage) ?? ""
        case .date(let d): return Format.longDate.string(from: d)
        default: return v.description
        }
    }
}
