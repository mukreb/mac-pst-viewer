import PSTKit
import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MessageRef>()
    @State private var sortOrder = [KeyPathComparator(\MessageRow.sortDate, order: .reverse)]

    var sortedRows: [MessageRow] { model.visibleRows.sorted(using: sortOrder) }

    var title: String {
        if model.searchResults != nil { return tr("Search Results", "Zoekresultaten") }
        return model.folderNode(model.selectedFolder)?.name ?? tr("Messages", "Berichten")
    }

    /// Sent Items, Outbox and Drafts: show who a message went to instead of the sender (yourself).
    var showsRecipients: Bool {
        model.searchResults == nil && (model.folderNode(model.selectedFolder)?.showsRecipients ?? false)
    }

    /// Search bar options, shown only while searching.
    var showsSearchBar: Bool { !model.searchText.isEmpty || model.searchWarning != nil }

    var body: some View {
        VStack(spacing: 0) {
            if showsSearchBar {
                searchBar
                Divider()
            }
            if model.visibleRows.isEmpty {
                if model.isSearching {
                    EmptyStateView(symbol: "magnifyingglass", title: tr("Searching…", "Zoeken…"), subtitle: "")
                } else if model.searchResults != nil {
                    EmptyStateView(symbol: "magnifyingglass", title: tr("No Results", "Geen resultaten"),
                                   subtitle: tr("Try other search terms or search all folders.",
                                                "Probeer andere zoektermen of zoek in alle mappen."))
                } else {
                    EmptyStateView(symbol: "tray", title: tr("This Folder Is Empty", "Deze map is leeg"), subtitle: "")
                }
            } else {
                table
            }
        }
        // Like Mail: the folder name as window title, the counts underneath.
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar,
                    prompt: tr("Search subject, sender, recipient…", "Zoek op onderwerp, afzender, ontvanger…"))
        // The list is rebuilt when the language changes; keep the message that is shown selected.
        .onAppear {
            if let ref = model.selectedMessage, selection.isEmpty { selection = [ref] }
        }
        // Deferred to the next run-loop turn: these fire inside NSTableView delegate callbacks,
        // and mutating table state synchronously there is a reentrant operation.
        .onChange(of: selection) { newValue in
            let ref = newValue.count == 1 ? newValue.first : nil
            DispatchQueue.main.async { model.selectedMessage = ref }
        }
        .onChange(of: model.selectedFolder) { _ in clearSelection() }
        // A new search can hide the selected message; don't keep showing or exporting it.
        .onChange(of: model.searchText) { _ in clearSelection() }
        .onChange(of: model.searchScope) { _ in clearSelection() }
        .onChange(of: model.searchBodies) { _ in clearSelection() }
    }

    private func clearSelection() {
        DispatchQueue.main.async { selection.removeAll() }
    }

    var searchBar: some View {
        HStack(spacing: 10) {
            if !model.searchText.isEmpty {
                Picker(tr("Scope", "Bereik"), selection: $model.searchScope) {
                    ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle(tr("Include message text", "Ook in tekst"), isOn: $model.searchBodies)
                    .toggleStyle(.checkbox)
                    .help(tr("Also search message text, attachment names and email addresses (slower)",
                             "Zoek ook in de berichttekst, bijlagenamen en e-mailadressen (langzamer)"))
            }
            Spacer()
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if let warning = model.searchWarning {
                Label(tr("Incomplete", "Onvolledig"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    var countText: String {
        let n = model.visibleRows.count
        let unread = model.visibleRows.filter { !$0.summary.isRead }.count
        var s = n == 1 ? tr("1 message", "1 bericht") : tr("\(n) messages", "\(n) berichten")
        // Searching this folder: make clear the list is filtered, not the whole folder.
        if model.searchResults != nil && model.searchResultsScope == .folder {
            let total = model.rows.count
            s = total == 1 ? tr("\(n) of 1 message", "\(n) van 1 bericht")
                           : tr("\(n) of \(total) messages", "\(n) van \(total) berichten")
        }
        if unread > 0 && model.searchResults == nil { s += tr(", \(unread) unread", ", \(unread) ongelezen") }
        if selection.count > 1 { s += tr(" — \(selection.count) selected", " — \(selection.count) geselecteerd") }
        return s
    }

    /// With several files open, also says which file the folder belongs to.
    var subtitle: String {
        guard model.stores.count > 1, model.searchResults == nil,
              let store = model.store(model.selectedFolder?.store) else { return countText }
        return store.fileName + " · " + countText
    }

    var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.attachmentSort) { row in
                RowIcon(row: row)
            }
            .width(min: 28, ideal: 30, max: 40)

            TableColumn(showsRecipients ? tr("To", "Aan") : tr("From", "Van"), value: \.sortCorrespondent) { row in
                CorrespondentCell(row: row, mixed: model.searchResults != nil)
            }
            .width(min: 80, ideal: 120)

            TableColumn(tr("Subject", "Onderwerp"), value: \.sortSubject) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.subject)
                        .fontWeight(row.summary.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    if !row.folderName.isEmpty {
                        Text(row.folderName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.subject)
            }
            .width(min: 120, ideal: 185)

            TableColumn(tr("Date", "Datum"), value: \.sortDate) { row in
                Text(Format.listDate(row.summary.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 118)

            TableColumn(tr("Size", "Grootte"), value: \.size) { row in
                Text(row.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 45, ideal: 58)
        }
        .contextMenu(forSelectionType: MessageRef.self) { refs in
            if refs.count == 1, let ref = refs.first {
                Button(tr("Open in New Window", "Open in nieuw venster")) { openWindow(value: ref) }
            }
            Button(refs.count == 1 ? tr("Export as .eml…", "Exporteer als .eml…")
                                   : tr("Export \(refs.count) Messages as .eml…", "Exporteer \(refs.count) berichten als .eml…")) {
                model.exportMessages(Array(refs))
            }
            Button(refs.count == 1 ? tr("Export as mbox…", "Exporteer als mbox…")
                                   : tr("Export \(refs.count) Messages as mbox…", "Exporteer \(refs.count) berichten als mbox…")) {
                model.exportMessagesAsMbox(Array(refs))
            }
        } primaryAction: { refs in
            for ref in refs.prefix(10) { openWindow(value: ref) }
        }
        // NSTableView keeps its column titles; rebuild it when the From/To header must change.
        .id(showsRecipients)
    }
}

/// The sender, or for outgoing mail the recipients (To, falling back to Cc).
struct CorrespondentCell: View {
    let row: MessageRow
    /// Search results mix folders; outgoing rows then get a "To:" prefix.
    let mixed: Bool

    var text: String {
        let value = row.correspondent.isEmpty ? "—" : row.correspondent
        return mixed && row.isOutgoing ? tr("To: ", "Aan: ") + value : value
    }

    var tooltip: String {
        guard row.isOutgoing else { return row.from }
        var lines: [String] = []
        if !row.summary.to.isEmpty { lines.append(tr("To: ", "Aan: ") + row.summary.to) }
        if !row.summary.cc.isEmpty { lines.append("Cc: " + row.summary.cc) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Text(text)
            .fontWeight(row.summary.isRead ? .regular : .semibold)
            .lineLimit(1)
            .help(tooltip)
    }
}

struct RowIcon: View {
    let row: MessageRow

    var body: some View {
        HStack(spacing: 2) {
            switch row.summary.kind {
            case .contact: Image(systemName: "person.crop.circle").foregroundStyle(.blue)
            case .appointment, .meetingRequest: Image(systemName: "calendar").foregroundStyle(.red)
            case .task: Image(systemName: "checkmark.circle").foregroundStyle(.green)
            case .note: Image(systemName: "note.text").foregroundStyle(.yellow)
            case .distributionList: Image(systemName: "person.2").foregroundStyle(.blue)
            default:
                if !row.summary.isRead {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                } else if row.summary.importance == 2 {
                    Image(systemName: "exclamationmark").foregroundStyle(.red)
                }
            }
            if row.summary.hasAttachments {
                Image(systemName: "paperclip").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

enum Format {
    /// Formatters per language; they are rebuilt when the language changes.
    private static var cache: [String: DateFormatter] = [:]

    private static func formatter(_ name: String, _ configure: (DateFormatter) -> Void) -> DateFormatter {
        let lang = Localization.current
        let key = name + "-" + lang.rawValue
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = lang.locale
        configure(f)
        cache[key] = f
        return f
    }

    static var time: DateFormatter {
        formatter("time") { $0.dateStyle = .none; $0.timeStyle = .short }
    }

    static var shortDate: DateFormatter {
        formatter("short") { $0.setLocalizedDateFormatFromTemplate("ddMMyyyyHHmm") }
    }

    static var longDate: DateFormatter {
        formatter("long") { $0.dateStyle = .full; $0.timeStyle = .short }
    }

    static func listDate(_ d: Date?) -> String {
        guard let d else { return "" }
        if Calendar.current.isDateInToday(d) { return time.string(from: d) }
        return shortDate.string(from: d)
    }
}
