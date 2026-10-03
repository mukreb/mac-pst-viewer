import PSTKit
import SwiftUI

struct MessageListView: View {
    @EnvironmentObject var model: ViewerModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MessageRef>()
    @State private var sortOrder = [KeyPathComparator(\MessageRow.sortDate, order: .reverse)]

    var sortedRows: [MessageRow] { model.visibleRows.sorted(using: sortOrder) }

    var title: String {
        if model.searchResults != nil { return "Zoekresultaten" }
        return model.folderNode(model.selectedFolder)?.name ?? "Berichten"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.visibleRows.isEmpty {
                if model.isSearching {
                    EmptyStateView(symbol: "magnifyingglass", title: "Zoeken…", subtitle: "")
                } else if model.searchResults != nil {
                    EmptyStateView(symbol: "magnifyingglass", title: "Geen resultaten",
                                   subtitle: "Probeer andere zoektermen of zoek in alle mappen.")
                } else {
                    EmptyStateView(symbol: "tray", title: "Deze map is leeg", subtitle: "")
                }
            } else {
                table
            }
        }
        .navigationTitle(title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Zoek op onderwerp, afzender…")
        .onChange(of: selection) { newValue in
            model.selectedMessage = newValue.count == 1 ? newValue.first : nil
        }
        .onChange(of: model.selectedFolder) { _ in selection.removeAll() }
    }

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
            if !model.searchText.isEmpty {
                Picker("Bereik", selection: $model.searchScope) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle("Ook in tekst", isOn: $model.searchBodies)
                    .toggleStyle(.checkbox)
                    .help("Zoek ook in de berichttekst en bijlagenamen (langzamer)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    var countText: String {
        let n = model.visibleRows.count
        let unread = model.visibleRows.filter { !$0.summary.isRead }.count
        var s = n == 1 ? "1 item" : "\(n) items"
        if unread > 0 && model.searchResults == nil { s += ", \(unread) ongelezen" }
        if selection.count > 1 { s += " — \(selection.count) geselecteerd" }
        return s
    }

    var table: some View {
        Table(sortedRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("", value: \.attachmentSort) { row in
                RowIcon(row: row)
            }
            .width(min: 28, ideal: 34, max: 40)

            TableColumn("Van", value: \.sortFrom) { row in
                Text(row.from.isEmpty ? "—" : row.from)
                    .fontWeight(row.summary.isRead ? .regular : .semibold)
                    .lineLimit(1)
                    .help(row.from)
            }
            .width(min: 100, ideal: 160)

            TableColumn("Onderwerp", value: \.sortSubject) { row in
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
            .width(min: 150, ideal: 300)

            TableColumn("Datum", value: \.sortDate) { row in
                Text(Format.listDate(row.summary.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)

            TableColumn("Grootte", value: \.size) { row in
                Text(row.size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(row.size), countStyle: .file) : "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
        }
        .contextMenu(forSelectionType: MessageRef.self) { refs in
            if refs.count == 1, let ref = refs.first {
                Button("Open in nieuw venster") { openWindow(value: ref) }
            }
            Button(refs.count == 1 ? "Exporteer als .eml…" : "Exporteer \(refs.count) berichten als .eml…") {
                model.exportMessages(Array(refs))
            }
        } primaryAction: { refs in
            for ref in refs.prefix(10) { openWindow(value: ref) }
        }
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
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    static func listDate(_ d: Date?) -> String {
        guard let d else { return "" }
        if Calendar.current.isDateInToday(d) { return time.string(from: d) }
        return shortDate.string(from: d)
    }
}
