import PSTKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: ViewerModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if model.stores.isEmpty {
                WelcomeView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 400)
                } content: {
                    MessageListView()
                        .navigationSplitViewColumnWidth(min: 360, ideal: 560)
                } detail: {
                    if let ref = model.selectedMessage {
                        MessageContainerView(ref: ref)
                            .id(ref)
                    } else {
                        EmptyStateView(symbol: "envelope.open", title: tr("No Message Selected", "Geen bericht geselecteerd"),
                                       subtitle: tr("Choose a message in the list to view it.", "Kies een bericht in de lijst om het te bekijken."))
                    }
                }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressOverlay(text: model.loadingText, progress: nil)
            } else if let p = model.exportProgress {
                ProgressOverlay(text: p.text, progress: Double(p.done) / Double(p.total))
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Corner.panel, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.open(url) }
                }
            }
            return true
        }
        .alert(tr("Error", "Fout"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .localizedRoot()
    }
}

struct ProgressOverlay: View {
    let text: String
    let progress: Double?

    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 240)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(text)
                    .font(.callout)
            }
            .padding(24)
            .glassPanel(in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "tray.full")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(spacing: 6) {
                Text("PST Viewer")
                    .font(.largeTitle.weight(.semibold))
                Text(tr("View Outlook archives (.pst and .ost) and old mbox mail (Netscape, Thunderbird) on your Mac — read-only.",
                        "Bekijk Outlook-archieven (.pst en .ost) en oude mbox-mail (Netscape, Thunderbird) op je Mac — alleen-lezen."))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.showOpenPanel()
            } label: {
                Label(tr("Open PST File or Mail Folder…", "Open PST-bestand of mailmap…"), systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .glassButtonStyle(prominent: true)
            .keyboardShortcut(.defaultAction)

            Text(tr("or drag a file or folder onto this window", "of sleep een bestand of map naar dit venster"))
                .font(.callout)
                .foregroundStyle(.tertiary)

            let recents = model.recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Recently Opened", "Recent geopend"))
                        .font(.headline)
                    ForEach(recents, id: \.self) { url in
                        Button {
                            model.open(url)
                        } label: {
                            HStack {
                                Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding()
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: ViewerModel
    @AppStorage("showSystemFolders") private var showSystemFolders = false
    @AppStorage("defaultCodepage") private var defaultCodepage = 1252
    @AppStorage("loadRemoteContent") private var loadRemoteContent = false
    @AppStorage(AppSettings.languageKey) private var language = LanguageSetting.system.rawValue
    @AppStorage(AppSettings.appearanceKey) private var appearance: AppearanceSetting = .system
    @AppStorage(AppSettings.darkMessagesKey) private var darkMessages = true
    @AppStorage(Updater.automaticKey) private var checkForUpdates = true
    @ObservedObject private var updater = Updater.shared

    /// Updates `tr()` before the stored value changes, so every view that redraws sees the new language.
    private var languageBinding: Binding<LanguageSetting> {
        Binding(get: { LanguageSetting(rawValue: language) ?? .system },
                set: { AppSettings.applyLanguage($0); language = $0.rawValue })
    }

    var body: some View {
        // Grouped form: labels on the left, controls on the right, long explanations wrap
        // underneath instead of being clipped by the window.
        Form {
            Section {
                Picker(tr("Language", "Taal"), selection: languageBinding) {
                    ForEach(LanguageSetting.allCases) { Text($0.title).tag($0) }
                }
                Picker(tr("Appearance", "Weergave"), selection: $appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: appearance) { v in AppSettings.applyAppearance(v) }
                Toggle(isOn: $darkMessages) {
                    Text(tr("Dark message backgrounds", "Donkere achtergrond voor berichten"))
                    Text(tr("In dark mode, show HTML messages with dark colors instead of on a white page.",
                            "Toon HTML-berichten in donkere modus met donkere kleuren in plaats van op een wit vel."))
                }
            } header: {
                Text(tr("General", "Algemeen"))
            } footer: {
                Text(tr("System default uses your Mac's language, or English if it isn't available. Menu items provided by macOS switch after restarting the app.",
                        "Systeemstandaard volgt de taal van je Mac, of Engels als die niet beschikbaar is. Menu-onderdelen van macOS zelf wisselen na een herstart van de app."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(tr("Folders", "Mappen")) {
                Toggle(isOn: $showSystemFolders) {
                    Text(tr("Show system folders", "Toon systeemmappen"))
                    Text(tr("Internal Outlook folders such as Search Root and Freebusy Data.",
                            "Interne Outlook-mappen zoals Search Root en Freebusy Data."))
                }
                .onChange(of: showSystemFolders) { _ in model.rebuildStores() }
            }
            Section(tr("Messages", "Berichten")) {
                Toggle(isOn: $loadRemoteContent) {
                    Text(tr("Load remote images", "Externe afbeeldingen laden"))
                    Text(tr("Images from the internet in HTML messages. Off by default for privacy.",
                            "Afbeeldingen van internet in HTML-berichten. Standaard uit voor privacy."))
                }
            }
            Section {
                Picker(tr("Default character set", "Standaardtekenset"), selection: $defaultCodepage) {
                    Text(tr("Western European (Windows-1252)", "West-Europees (Windows-1252)")).tag(1252)
                    Text(tr("Central European (Windows-1250)", "Centraal-Europees (Windows-1250)")).tag(1250)
                    Text(tr("Cyrillic (Windows-1251)", "Cyrillisch (Windows-1251)")).tag(1251)
                    Text(tr("Greek (Windows-1253)", "Grieks (Windows-1253)")).tag(1253)
                    Text(tr("Turkish (Windows-1254)", "Turks (Windows-1254)")).tag(1254)
                    Text(tr("Japanese (Shift-JIS)", "Japans (Shift-JIS)")).tag(932)
                    Text("UTF-8").tag(65001)
                }
                .onChange(of: defaultCodepage) { v in model.defaultCodepage = v }
            } header: {
                Text(tr("Old (ANSI) Messages", "Oude (ANSI) berichten"))
            } footer: {
                Text(tr("Only used when a message doesn't specify its own character set. Reopen the file to apply the change everywhere.",
                        "Wordt alleen gebruikt als een bericht zelf geen tekenset aangeeft. Open het bestand opnieuw om de wijziging overal toe te passen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(isOn: $checkForUpdates) {
                    Text(tr("Check for updates automatically", "Automatisch zoeken naar updates"))
                    Text(tr("Once a day, looks on GitHub for a new release and asks before installing it.",
                            "Kijkt eens per dag op GitHub of er een nieuwe versie is en vraagt het voordat die wordt geïnstalleerd."))
                }
                LabeledContent(tr("Version \(updater.currentVersion)", "Versie \(updater.currentVersion)")) {
                    Button(tr("Check Now", "Nu controleren")) {
                        Task { await updater.check(userInitiated: true) }
                    }
                    .disabled(updater.isBusy)
                }
            } header: {
                Text(tr("Updates", "Updates"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
