import PSTKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: ViewerModel
    @State private var infoStore: OpenStore?

    var body: some View {
        List(selection: $model.selectedFolder) {
            ForEach(model.stores) { store in
                Section {
                    OutlineGroup(store.nodes, children: \.children) { node in
                        FolderRow(node: node)
                            .tag(node.ref)
                            .contextMenu { folderMenu(node) }
                    }
                } header: {
                    HStack {
                        Image(systemName: "archivebox")
                        Text(store.file.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(store.file.url.path)
                        Spacer()
                        Menu {
                            Button("Bestandsinformatie…") { infoStore = store }
                            Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.file.url]) }
                            Divider()
                            Button("Sluit bestand") { model.close(store) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    model.showOpenPanel()
                } label: {
                    Label("Open", systemImage: "plus")
                }
                .help("Nog een PST-bestand openen")
            }
        }
        .sheet(item: $infoStore) { store in
            FileInfoView(store: store)
        }
    }

    @ViewBuilder
    func folderMenu(_ node: FolderNode) -> some View {
        Button("Exporteer map als mbox…") { model.exportFolderAsMbox(node.ref) }
        Button("Exporteer map als .eml-bestanden…") { model.exportFolderAsEML(node.ref, recursive: false) }
        if node.children != nil {
            Button("Exporteer map met submappen als .eml-bestanden…") { model.exportFolderAsEML(node.ref, recursive: true) }
        }
    }
}

struct FolderRow: View {
    let node: FolderNode

    var body: some View {
        HStack {
            Label {
                Text(node.name)
                    .lineLimit(1)
            } icon: {
                Image(systemName: Self.icon(for: node.folder.kind))
            }
            Spacer()
            if node.folder.unreadCount > 0 {
                Text("\(node.folder.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
                    .help("\(node.folder.unreadCount) ongelezen")
            } else if node.folder.contentCount > 0 {
                Text("\(node.folder.contentCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func icon(for kind: FolderKind) -> String {
        switch kind {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .trash: return "trash"
        case .drafts: return "doc"
        case .outbox: return "tray.and.arrow.up"
        case .junk: return "xmark.bin"
        case .contacts: return "person.crop.circle"
        case .calendar: return "calendar"
        case .tasks: return "checklist"
        case .notes: return "note.text"
        case .journal: return "book"
        case .mail: return "folder"
        }
    }
}

struct FileInfoView: View {
    let store: OpenStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.file.displayName)
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(store.file.info, id: \.0) { item in
                    GridRow {
                        Text(item.0).foregroundStyle(.secondary)
                        Text(item.1).textSelection(.enabled)
                    }
                }
                GridRow {
                    Text("Mappen").foregroundStyle(.secondary)
                    Text("\(store.root.allFolders.count)")
                }
                GridRow {
                    Text("Items").foregroundStyle(.secondary)
                    Text("\(store.root.totalCount)")
                }
                GridRow {
                    Text("Pad").foregroundStyle(.secondary)
                    Text(store.file.url.path).textSelection(.enabled).lineLimit(3)
                }
            }
            HStack {
                Spacer()
                Button("Sluiten") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
