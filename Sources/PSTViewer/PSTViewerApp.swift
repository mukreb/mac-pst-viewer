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
    // Note: opening files (Finder double-click, Dock, `PSTViewer file.pst`) is deliberately
    // left to SwiftUI (`onOpenURL` below). Implementing `application(_:open:)` here would
    // stop SwiftUI from creating the main window when the app is launched with a file.

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Safety net: make sure there is always a main window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppDelegate.ensureMainWindow()
        }

        // `--snapshot <file.png>`: render the main window to a PNG and quit (used by CI).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.windows.first { $0.isVisible && $0.contentView != nil }?
                    .setFrame(NSRect(x: 40, y: 40, width: 1380, height: 820), display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                AppDelegate.snapshot(to: out)
                NSApp.terminate(nil)
            }
        }
    }

    static func snapshot(to url: URL) {
        for w in NSApp.windows {
            print("window: \(w.title) visible=\(w.isVisible) frame=\(w.frame)")
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot: no window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot written to \(url.path)")
    }

    /// Opens the main window through its Window-menu item if no window is visible.
    static func ensureMainWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 400 }) else { return }
        for top in NSApp.mainMenu?.items ?? [] {
            for item in top.submenu?.items ?? [] where item.title == "PST Viewer" {
                if let action = item.action {
                    NSApp.sendAction(action, to: item.target, from: item)
                    return
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppDelegate.ensureMainWindow() }
        return true
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
                .onOpenURL { url in
                    if url.isFileURL { model.open(url) }
                }
                .onAppear {
                    // `PSTViewer /path/to/file.pst` from the command line.
                    let args = CommandLine.arguments.dropFirst()
                    var skipNext = false
                    for arg in args {
                        if skipNext { skipNext = false; continue }
                        if arg.hasPrefix("-") { skipNext = arg == "--snapshot"; continue }
                        let url = URL(fileURLWithPath: arg)
                        if ["pst", "ost"].contains(url.pathExtension.lowercased()) { model.open(url) }
                    }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
