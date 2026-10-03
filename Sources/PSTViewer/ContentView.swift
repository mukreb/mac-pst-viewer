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
                        .navigationSplitViewColumnWidth(min: 320, ideal: 460)
                } detail: {
                    if let ref = model.selectedMessage {
                        MessageContainerView(ref: ref)
                            .id(ref)
                    } else {
                        EmptyStateView(symbol: "envelope.open", title: "Geen bericht geselecteerd",
                                       subtitle: "Kies een bericht in de lijst om het te bekijken.")
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
                RoundedRectangle(cornerRadius: 12)
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
        .alert("Fout", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                Text("Bekijk Outlook-archieven (.pst en .ost) op je Mac — alleen-lezen, zonder Outlook.")
                    .foregroundStyle(.secondary)
            }
            Button {
                model.showOpenPanel()
            } label: {
                Label("Open PST-bestand…", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Text("of sleep een bestand naar dit venster")
                .font(.callout)
                .foregroundStyle(.tertiary)

            let recents = model.recentFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent geopend")
                        .font(.headline)
                    ForEach(recents, id: \.self) { url in
                        Button {
                            model.open(url)
                        } label: {
                            HStack {
                                Image(systemName: "doc")
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
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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

    var body: some View {
        Form {
            Toggle("Toon systeemmappen (Search Root, Freebusy, …)", isOn: $showSystemFolders)
                .onChange(of: showSystemFolders) { _ in model.rebuildStores() }
            Toggle("Externe afbeeldingen in HTML-berichten laden", isOn: $loadRemoteContent)
            Picker("Standaard tekenset voor oude (ANSI) berichten", selection: $defaultCodepage) {
                Text("West-Europees (Windows-1252)").tag(1252)
                Text("Centraal-Europees (Windows-1250)").tag(1250)
                Text("Cyrillisch (Windows-1251)").tag(1251)
                Text("Grieks (Windows-1253)").tag(1253)
                Text("Turks (Windows-1254)").tag(1254)
                Text("Japans (Shift-JIS)").tag(932)
                Text("UTF-8").tag(65001)
            }
            .onChange(of: defaultCodepage) { v in model.defaultCodepage = v }
            Text("De tekenset wordt alleen gebruikt als een bericht zelf geen tekenset aangeeft. Open het bestand opnieuw om de wijziging overal toe te passen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 520)
    }
}
