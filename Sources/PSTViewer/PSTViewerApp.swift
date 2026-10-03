import AppKit
import PSTKit
import SwiftUI
import UniformTypeIdentifiers

enum PSTTypes {
    static let pst = UTType(filenameExtension: "pst") ?? .data
    static let ost = UTType(filenameExtension: "ost") ?? .data
    static var all: [UTType] { [pst, ost] }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened (Finder double-click, drag onto Dock icon) before the window existed.
    static var pendingURLs: [URL] = []
    static var openHandler: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let handler = AppDelegate.openHandler { handler(url) } else { AppDelegate.pendingURLs.append(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PSTViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewerModel()

    var body: some Scene {
        Window("PST Viewer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    AppDelegate.openHandler = { url in model.open(url) }
                    for url in AppDelegate.pendingURLs { model.open(url) }
                    AppDelegate.pendingURLs.removeAll()
                    // Allow `PSTViewer /path/to/file.pst` from the command line.
                    for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
                        let url = URL(fileURLWithPath: arg)
                        if ["pst", "ost"].contains(url.pathExtension.lowercased()) { model.open(url) }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PST-bestand…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .importExport) {
                Button("Exporteer geselecteerd bericht als .eml…") {
                    if let m = model.selectedMessage { model.exportMessages([m]) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedMessage == nil)
                Button("Exporteer map als mbox…") {
                    if let f = model.selectedFolder { model.exportFolderAsMbox(f) }
                }
                .disabled(model.selectedFolder == nil)
            }
        }

        WindowGroup("Bericht", for: MessageRef.self) { $ref in
            if let ref {
                MessageContainerView(ref: ref)
                    .environmentObject(model)
                    .frame(minWidth: 640, minHeight: 480)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
