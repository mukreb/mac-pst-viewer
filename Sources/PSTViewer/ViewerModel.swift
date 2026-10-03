import AppKit
import Foundation
import PSTKit
import SwiftUI

/// Identifies a folder within one of the open stores.
struct FolderRef: Hashable {
    let store: UUID
    let nid: UInt32
}

/// Identifies a message within one of the open stores.
struct MessageRef: Hashable, Codable {
    let store: UUID
    let nid: UInt32
}

/// A node of the sidebar outline.
struct FolderNode: Identifiable, Hashable {
    let ref: FolderRef
    let folder: Folder
    let children: [FolderNode]?

    var id: FolderRef { ref }
    var name: String { folder.name.isEmpty ? tr("(untitled)", "(naamloos)") : folder.name }
    /// Folders whose messages were written by the user: the list shows recipients instead of senders.
    var showsRecipients: Bool { [FolderKind.sent, .outbox, .drafts].contains(folder.kind) }
}

/// One opened PST/OST file or mbox mail folder.
final class OpenStore: Identifiable {
    let id = UUID()
    let file: any MailStore
    let root: Folder
    /// Folders shown in the sidebar (the IPM subtree when present).
    let nodes: [FolderNode]
    let allNodes: [FolderNode]

    /// The file name shown in the sidebar, e.g. "archive-2009.pst".
    var fileName: String { file.url.lastPathComponent }

    /// An mbox archive (Netscape, Thunderbird, …) rather than an Outlook file.
    var isMbox: Bool { !(file is PSTFile) }

    /// The store's internal name ("Personal Folders", …) when it adds something to the file name.
    var storeNameIfDifferent: String? {
        let name = file.displayName.trimmingCharacters(in: .whitespaces)
        let base = file.url.deletingPathExtension().lastPathComponent
        if name.isEmpty || name.caseInsensitiveCompare(base) == .orderedSame { return nil }
        return name
    }

    init(file: any MailStore, root: Folder, showSystemFolders: Bool) {
        self.file = file
        self.root = root
        let id = self.id

        func build(_ f: Folder) -> FolderNode? {
            if !showSystemFolders && OpenStore.isSystemFolder(f) { return nil }
            let kids = f.children.compactMap(build)
            return FolderNode(ref: FolderRef(store: id, nid: f.nid), folder: f, children: kids.isEmpty ? nil : kids)
        }

        // Most PSTs have the structure root → "Top of Personal Folders" (IPM subtree) → Inbox, ...
        // Show the IPM subtree's children at top level, like Outlook does.
        var top: [FolderNode] = []
        for child in root.children {
            guard let node = build(child) else { continue }
            if file is PSTFile, OpenStore.isIPMSubtree(child) {
                if child.contentCount > 0 {
                    top.append(FolderNode(ref: node.ref, folder: child, children: nil))
                }
                top.append(contentsOf: node.children ?? [])
            } else {
                top.append(node)
            }
        }
        if top.isEmpty, let node = build(root) { top = node.children ?? [node] }
        nodes = top

        func flatten(_ n: [FolderNode]) -> [FolderNode] { n.flatMap { [$0] + flatten($0.children ?? []) } }
        allNodes = flatten(top)
    }

    static func isIPMSubtree(_ f: Folder) -> Bool {
        let n = f.name.lowercased()
        if n.hasPrefix("top of") || n.hasPrefix("bovenkant van") || n.hasPrefix("début du") || n == "ipm_subtree"
            || n.hasPrefix("persoonlijke mappen") || n.hasPrefix("personal folders") || n.hasPrefix("oberste ebene") {
            return true
        }
        // Heuristic: the single folder that contains an Inbox-like child.
        return f.children.contains { [.inbox, .sent, .trash].contains($0.kind) }
    }

    static func isSystemFolder(_ f: Folder) -> Bool {
        let n = f.name.lowercased()
        // Exact names of folders Outlook/Exchange create for internal use.
        let exact: Set<String> = [
            "search root", "spam search folder 2", "ipm_views", "ipm_common_views", "reminders",
            "to-do search", "itemprocsearch", "freebusy data", "tracked mail processing",
            "racine (pour la recherche)", "zoekhoofdmap", "finder", "views", "common views",
            "shortcuts", "schedule", "deferred action", "spooler queue", "conversation action settings",
            "quick step settings", "yammer root", "recoverable items", "root - public",
            "non_ipm_subtree", "eforms registry", "organization forms", "conversation history",
        ]
        // Distinctive prefixes (these folders carry suffixes such as "(This computer only)").
        let prefixes = ["sync issues", "conversation action settings", "quick step settings", "recoverable items"]
        return exact.contains(n) || prefixes.contains(where: { n.hasPrefix($0) }) || n.hasPrefix("~")
    }
}

/// A row in the message list.
struct MessageRow: Identifiable, Hashable {
    let ref: MessageRef
    let summary: MessageSummary
    var folderName: String = ""
    /// Set for messages in Sent Items, Outbox and Drafts.
    var isOutgoing = false

    var id: MessageRef { ref }
    var subject: String { summary.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : summary.subject }
    var from: String { summary.from }
    /// To, or Cc when a message has no To recipients.
    var recipients: String { summary.to.isEmpty ? summary.cc : summary.to }
    /// The sender for received mail, the recipients for outgoing mail.
    var correspondent: String { isOutgoing ? recipients : from }
    var sortCorrespondent: String { correspondent.lowercased() }
    var sortDate: Date { summary.sortDate }
    var sortSubject: String { summary.sortSubject }
    var sortFrom: String { summary.sortFrom }
    var size: Int { summary.size }
    var attachmentSort: Int { summary.hasAttachments ? 1 : 0 }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case folder, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .folder: return tr("This Folder", "Deze map")
        case .all: return tr("All Folders", "Alle mappen")
        }
    }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var stores: [OpenStore] = []
    @Published var selectedFolder: FolderRef? {
        didSet {
            // Selection changes arrive inside AppKit's table delegate callbacks; changing the
            // message list synchronously there triggers "reentrant operation" warnings.
            if oldValue != selectedFolder { DispatchQueue.main.async { self.loadMessages() } }
        }
    }
    @Published var rows: [MessageRow] = []
    @Published var selectedMessage: MessageRef?
    @Published var isLoading = false
    @Published var loadingText = ""
    @Published var errorMessage: String?

    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var searchScope: SearchScope = .folder {
        didSet { scheduleSearch() }
    }
    @Published var searchBodies = false {
        didSet { scheduleSearch() }
    }
    @Published var searchResults: [MessageRow]?
    @Published var isSearching = false
    /// Set when an all-folder search had to skip folders it could not read.
    @Published var searchWarning: String?

    @AppStorage("showSystemFolders") var showSystemFolders = false
    @AppStorage("defaultCodepage") var defaultCodepage = 1252 {
        didSet { PSTText.defaultCodepage = defaultCodepage }
    }
    @AppStorage("recentFiles") private var recentFilesData = Data()

    /// Set by the `--demo` launch argument: selects the first message automatically (used for CI screenshots).
    var autoSelectFirstMessage = CommandLine.arguments.contains("--demo")

    private var folderRows: [MessageRow] = []
    private var searchTask: Task<Void, Never>?
    /// Incremented on every new search so results of superseded searches are ignored.
    private var searchGeneration = 0
    private var loadTask: Task<Void, Never>?

    init() {
        PSTText.defaultCodepage = defaultCodepage
    }

    // MARK: Opening files

    var recentFiles: [URL] {
        get { (try? JSONDecoder().decode([URL].self, from: recentFilesData)) ?? [] }
        set { recentFilesData = (try? JSONEncoder().encode(Array(newValue.prefix(10)))) ?? Data() }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = tr("Open PST File or Mail Folder", "Open PST-bestand of mailmap")
        panel.message = tr("Choose a .pst or .ost file, an mbox file, or a folder of mbox files (for example from Netscape or Thunderbird).",
                           "Kies een .pst- of .ost-bestand, een mbox-bestand, of een map met mbox-bestanden (bijvoorbeeld van Netscape of Thunderbird).")
        panel.allowsMultipleSelection = true
        // Mbox files have no fixed extension (Netscape's are called "Inbox", "Sent", …).
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            for url in panel.urls { open(url) }
        }
    }

    private var opening = Set<URL>()

    func open(_ url: URL) {
        let key = url.standardizedFileURL
        guard !opening.contains(key) else { return }
        // Compare paths: a folder URL may or may not end in "/".
        if let existing = stores.first(where: { $0.file.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
            selectFirstFolder(of: existing)
            return
        }
        opening.insert(key)
        isLoading = true
        loadingText = tr("Opening \(url.lastPathComponent)…", "\(url.lastPathComponent) openen…")
        let showSystem = showSystemFolders
        Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            do {
                let file = try MailStores.open(url)
                let root = try file.rootFolder()
                let store = OpenStore(file: file, root: root, showSystemFolders: showSystem)
                await MainActor.run {
                    self.opening.remove(key)
                    self.stores.append(store)
                    self.isLoading = false
                    var recents = self.recentFiles.filter { $0 != url }
                    recents.insert(url, at: 0)
                    self.recentFiles = recents
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    self.selectFirstFolder(of: store)
                }
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                await MainActor.run {
                    self.opening.remove(key)
                    self.isLoading = false
                    self.errorMessage = tr("Can't open \(url.lastPathComponent).", "Kan \(url.lastPathComponent) niet openen.") + "\n\n\(error)"
                }
            }
        }
    }

    /// Cancels a running search so it cannot publish rows of closed or rebuilt stores.
    private func invalidateSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        isSearching = false
        searchResults = nil
    }

    func close(_ store: OpenStore) {
        invalidateSearch()
        stores.removeAll { $0.id == store.id }
        if selectedFolder?.store == store.id {
            selectedFolder = nil
            selectedMessage = nil
            rows = []
        }
        searchResults = nil
    }

    /// Rebuilds the sidebar (after toggling system folders).
    func rebuildStores() {
        invalidateSearch()
        stores = stores.map { OpenStore(file: $0.file, root: $0.root, showSystemFolders: showSystemFolders) }
        selectedFolder = nil
        rows = []
        if let s = stores.first { selectFirstFolder(of: s) }
    }

    private func selectFirstFolder(of store: OpenStore) {
        let preferred = store.allNodes.first { $0.folder.kind == .inbox && $0.folder.contentCount > 0 }
            ?? store.allNodes.first { $0.folder.contentCount > 0 }
            ?? store.allNodes.first
        selectedFolder = preferred?.ref
    }

    // MARK: Lookup

    func store(_ id: UUID?) -> OpenStore? { stores.first { $0.id == id } }

    func folderNode(_ ref: FolderRef?) -> FolderNode? {
        guard let ref, let s = store(ref.store) else { return nil }
        return s.allNodes.first { $0.ref == ref }
    }

    func message(_ ref: MessageRef) throws -> Message {
        guard let s = store(ref.store) else { throw PSTError.notFound(tr("file", "bestand")) }
        return try s.file.message(nid: ref.nid)
    }

    // MARK: Message list

    var visibleRows: [MessageRow] { searchResults ?? rows }

    private func loadMessages() {
        loadTask?.cancel()
        selectedMessage = nil
        // Don't leave the previous folder's rows (or a folder-scoped search) visible while loading.
        rows = []
        folderRows = []
        if searchScope == .folder {
            searchTask?.cancel()
            searchGeneration += 1
            searchResults = nil
            isSearching = false
        }
        guard let ref = selectedFolder, let s = store(ref.store) else { rows = []; return }
        let file = s.file
        let outgoing = folderNode(ref)?.showsRecipients ?? false
        loadTask = Task.detached(priority: .userInitiated) {
            let summaries: [MessageSummary]
            do { summaries = try file.messages(in: ref.nid) } catch {
                await MainActor.run {
                    self.errorMessage = tr("This folder can't be read completely.", "Deze map kan niet volledig worden gelezen.") + "\n\n\(error)"
                }
                return
            }
            let rows = summaries.map { MessageRow(ref: MessageRef(store: ref.store, nid: $0.nid), summary: $0, isOutgoing: outgoing) }
                .sorted { $0.sortDate > $1.sortDate }
            await MainActor.run {
                guard self.selectedFolder == ref else { return }
                self.folderRows = rows
                self.rows = rows
                if self.autoSelectFirstMessage, let first = rows.first {
                    self.autoSelectFirstMessage = false
                    self.selectedMessage = first.ref
                }
                if !self.searchText.isEmpty { self.scheduleSearch() }
            }
        }
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchWarning = nil
        let generation = searchGeneration
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        let terms = query.lowercased().split(separator: " ").map(String.init)
        let scope = searchScope
        let bodies = searchBodies
        let folderRows = self.folderRows
        let stores = self.stores
        isSearching = true
        searchTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }

            var unreadable: [String] = []
            var unreadableMessages = 0

            func matches(_ row: MessageRow, file: any MailStore) -> Bool {
                let hay = (row.summary.subject + " " + row.summary.from + " " + row.summary.to + " " + row.summary.cc).lowercased()
                if terms.allSatisfy({ hay.contains($0) }) { return true }
                guard bodies else { return false }
                // A message whose text cannot be read might have matched: count it so the
                // result is flagged as incomplete instead of silently treated as a miss.
                guard let m = try? file.message(nid: row.ref.nid) else {
                    unreadableMessages += 1
                    return false
                }
                if m.bodyError != nil { unreadableMessages += 1 }
                // The list shows names only for PST mail; the full message also has the addresses.
                let addresses = m.from + " " + m.to + " " + m.cc + " " + m.bcc
                let full = (hay + " " + addresses + " " + m.plainBody + " " + m.attachments.map(\.filename).joined(separator: " ")).lowercased()
                return terms.allSatisfy { full.contains($0) }
            }

            var results: [MessageRow] = []
            switch scope {
            case .folder:
                guard let first = folderRows.first, let s = stores.first(where: { $0.id == first.ref.store }) else { break }
                for row in folderRows {
                    if Task.isCancelled { return }
                    if matches(row, file: s.file) { results.append(row) }
                }
            case .all:
                var seen = Set<MessageRef>()
                for s in stores {
                    for node in s.allNodes {
                        if Task.isCancelled { return }
                        let summaries: [MessageSummary]
                        do { summaries = try s.file.messages(in: node.ref.nid) } catch {
                            unreadable.append(node.name)
                            continue
                        }
                        for sum in summaries {
                            if Task.isCancelled { return }
                            let ref = MessageRef(store: s.id, nid: sum.nid)
                            // Search folders list messages that also live in their real folder.
                            guard seen.insert(ref).inserted else { continue }
                            let row = MessageRow(ref: ref, summary: sum, folderName: node.name, isOutgoing: node.showsRecipients)
                            if matches(row, file: s.file) { results.append(row) }
                        }
                        let partial = results
                        await MainActor.run {
                            guard self.searchGeneration == generation else { return }
                            self.searchResults = partial.sorted { $0.sortDate > $1.sortDate }
                        }
                    }
                }
            }
            let final = results.sorted { $0.sortDate > $1.sortDate }
            var problems: [String] = []
            if !unreadable.isEmpty {
                let names = unreadable.prefix(3).joined(separator: ", ")
                problems.append(tr("\(unreadable.count) folder(s) couldn't be read (\(names))",
                                   "\(unreadable.count) map(pen) konden niet worden gelezen (\(names))"))
            }
            if unreadableMessages > 0 {
                problems.append(tr("the text of \(unreadableMessages) message(s) couldn't be searched",
                                   "van \(unreadableMessages) bericht(en) kon de tekst niet worden doorzocht"))
            }
            let warning = problems.isEmpty ? nil : tr("Incomplete: ", "Onvolledig: ") + problems.joined(separator: "; ") + "."
            await MainActor.run {
                guard self.searchGeneration == generation else { return }
                self.searchResults = final
                self.isSearching = false
                self.searchWarning = warning
            }
        }
    }

    // MARK: Export

    func exportMessages(_ refs: [MessageRef]) {
        guard !refs.isEmpty else { return }
        if refs.count == 1, let m = try? message(refs[0]) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = EMLWriter.safeName(m.subject) + ".eml"
            panel.allowedContentTypes = [.emailMessage]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportMessage(m, to: url)
            return
        }
        let panel = NSOpenPanel()
        panel.title = tr("Choose a Folder for the .eml Files", "Kies een map voor de .eml-bestanden")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Export", "Exporteer")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        runExport(count: refs.count, text: tr("Exporting messages…", "Berichten exporteren…")) { progress in
            var used = Set<String>()
            var failures: [String] = []
            for (i, ref) in refs.enumerated() {
                do {
                    let m = try await self.message(ref)
                    let url = Self.uniqueURL(in: dir, base: EMLWriter.safeName(m.subject), ext: "eml", used: &used)
                    try EMLWriter.eml(for: m).write(to: url)
                } catch {
                    failures.append(tr("message \(i + 1)", "bericht \(i + 1)") + ": \(error.localizedDescription)")
                }
                await progress(i + 1)
            }
            return failures
        }
    }

    /// Writes the given messages (for example all search results) to one mbox file, oldest first.
    /// Each message gets an X-Folder header naming its file and folder, since search results mix them.
    func exportMessagesAsMbox(_ refs: [MessageRef]) {
        guard !refs.isEmpty else { return }
        let panel = NSSavePanel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let base = searchResults != nil && !query.isEmpty ? query : (folderNode(selectedFolder)?.name ?? tr("Messages", "Berichten"))
        panel.nameFieldStringValue = EMLWriter.safeName(base) + ".mbox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let selected = Set(refs)
        let folderName = folderNode(selectedFolder)?.name ?? ""
        let items: [(ref: MessageRef, location: String)] = visibleRows
            .filter { selected.contains($0.ref) }
            .sorted { $0.sortDate < $1.sortDate }
            .map { row in
                let file = store(row.ref.store)?.fileName ?? ""
                return (row.ref, file + "/" + (row.folderName.isEmpty ? folderName : row.folderName))
            }
        runExport(count: items.count, text: tr("Exporting messages to mbox…", "Berichten exporteren naar mbox…")) { progress in
            var failures: [String] = []
            do {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    return [tr("Can't create \(url.lastPathComponent).", "Kan \(url.lastPathComponent) niet aanmaken.")]
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                for (i, item) in items.enumerated() {
                    do {
                        let m = try await self.message(item.ref)
                        try handle.write(contentsOf: EMLWriter.mboxEntry(for: m, headers: [("X-Folder", item.location)]))
                    } catch {
                        failures.append(tr("message \(i + 1)", "bericht \(i + 1)") + ": \(error.localizedDescription)")
                    }
                    await progress(i + 1)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            return failures
        }
    }

    /// Writes one message as .eml in the background (large attachments can take a while).
    func exportMessage(_ m: Message, to url: URL) {
        runExport(count: 1, text: tr("Exporting message…", "Bericht exporteren…")) { progress in
            var failures: [String] = []
            do {
                try EMLWriter.eml(for: m).write(to: url)
            } catch {
                failures.append("\(m.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : m.subject): \(error.localizedDescription)")
            }
            await progress(1)
            return failures
        }
    }

    func exportFolderAsMbox(_ ref: FolderRef) {
        guard let s = store(ref.store), let node = folderNode(ref) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = EMLWriter.safeName(node.name) + ".mbox"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let file = s.file
        runExport(count: node.folder.contentCount, text: tr("Exporting \(node.name) to mbox…", "\(node.name) exporteren naar mbox…")) { progress in
            var failures: [String] = []
            do {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    return [tr("Can't create \(url.lastPathComponent).", "Kan \(url.lastPathComponent) niet aanmaken.")]
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let summaries = try file.messages(in: ref.nid)
                for (i, sum) in summaries.enumerated() {
                    do {
                        let m = try file.message(nid: sum.nid)
                        try handle.write(contentsOf: EMLWriter.mboxEntry(for: m))
                    } catch {
                        failures.append("\(sum.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : sum.subject): \(error.localizedDescription)")
                    }
                    await progress(i + 1)
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            return failures
        }
    }

    func exportFolderAsEML(_ ref: FolderRef, recursive: Bool) {
        guard let s = store(ref.store), let node = folderNode(ref) else { return }
        let panel = NSOpenPanel()
        panel.title = tr("Choose a Destination Folder", "Kies een doelmap")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("Export", "Exporteer")
        guard panel.runModal() == .OK, let base = panel.url else { return }
        let file = s.file
        let total = recursive ? node.folder.totalCount : node.folder.contentCount
        runExport(count: total, text: tr("Exporting \(node.name)…", "\(node.name) exporteren…")) { progress in
            var done = 0
            var failures: [String] = []
            var usedDirs: [URL: Set<String>] = [:]
            func export(_ f: Folder, into dir: URL) async {
                // Siblings like "A/B" and "A:B" sanitize to the same name: keep them apart.
                let base = EMLWriter.safeName(f.name.isEmpty ? tr("folder", "map") : f.name)
                var name = base
                var n = 2
                while usedDirs[dir, default: []].contains(name.lowercased())
                        || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
                    name = "\(base) (\(n))"
                    n += 1
                }
                usedDirs[dir, default: []].insert(name.lowercased())
                let target = dir.appendingPathComponent(name, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                } catch {
                    failures.append(tr("folder", "map") + " \(f.name): \(error.localizedDescription)")
                    return
                }
                var used = Set<String>()
                let summaries: [MessageSummary]
                do { summaries = try file.messages(in: f.nid) } catch {
                    failures.append(tr("folder", "map") + " \(f.name): \(error.localizedDescription)")
                    summaries = []
                }
                for sum in summaries {
                    do {
                        let m = try file.message(nid: sum.nid)
                        let url = Self.uniqueURL(in: target, base: EMLWriter.safeName(m.subject), ext: "eml", used: &used)
                        try EMLWriter.eml(for: m).write(to: url)
                    } catch {
                        failures.append("\(f.name) / \(sum.subject.isEmpty ? tr("(no subject)", "(geen onderwerp)") : sum.subject): \(error.localizedDescription)")
                    }
                    done += 1
                    await progress(done)
                }
                if recursive {
                    for c in f.children { await export(c, into: target) }
                }
            }
            await export(node.folder, into: base)
            return failures
        }
    }

    @Published var exportProgress: (done: Int, total: Int, text: String)?

    /// Runs an export in the background; `work` returns descriptions of items that failed.
    /// `work` is `@Sendable`, so it runs off the main thread and the window stays responsive.
    private func runExport(count: Int, text: String,
                           _ work: @escaping @Sendable (@escaping @Sendable (Int) async -> Void) async -> [String]) {
        exportProgress = (0, max(count, 1), text)
        Task.detached(priority: .userInitiated) {
            let failures = await work { n in
                await MainActor.run { self.exportProgress = (n, max(count, 1), text) }
            }
            await MainActor.run {
                self.exportProgress = nil
                if !failures.isEmpty {
                    var msg = tr("\(failures.count) item(s) couldn't be exported:", "\(failures.count) item(s) konden niet worden geëxporteerd:") + "\n\n"
                    msg += failures.prefix(15).map { "• " + $0 }.joined(separator: "\n")
                    if failures.count > 15 { msg += "\n" + tr("… and \(failures.count - 15) more", "… en nog \(failures.count - 15)") }
                    self.errorMessage = msg
                }
            }
        }
    }

    nonisolated static func uniqueURL(in dir: URL, base: String, ext: String, used: inout Set<String>) -> URL {
        var name = base
        var i = 2
        while used.contains(name.lowercased()) || FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).\(ext)").path) {
            name = "\(base) (\(i))"
            i += 1
        }
        used.insert(name.lowercased())
        return dir.appendingPathComponent("\(name).\(ext)")
    }
}
