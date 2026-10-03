import AppKit
import PSTKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Note: opening files (Finder double-click, Dock, `PSTViewer file.pst`) is deliberately
    // left to SwiftUI (`onOpenURL` below). Implementing `application(_:open:)` here would
    // stop SwiftUI from creating the main window when the app is launched with a file.

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppSettings.applyAppearance(AppSettings.appearance)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started as a bare executable (`swift run`) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AttachmentBar.purgeTemporaryFiles()

        // Safety net: make sure there is always a main window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            AppDelegate.ensureMainWindow()
        }

        // `--snapshot <file.png>`: render the main window to a PNG and quit (used by CI).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            let settings = args.contains("--settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if settings {
                    // Host the settings view in its own window so it can be snapshotted reliably.
                    let host = NSHostingView(rootView: SettingsView().environmentObject(ViewerModel()))
                    let size = host.fittingSize
                    let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: size.width, height: size.height),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.title = tr("Settings", "Instellingen")
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    AppDelegate.settingsSnapshotWindow = window
                } else {
                    NSApp.windows.first { $0.isVisible && $0.contentView != nil }?
                        .setFrame(NSRect(x: 40, y: 40, width: 1380, height: 820), display: true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                AppDelegate.snapshot(to: out, preferKeyWindow: settings)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { NSApp.terminate(nil) }
        }
    }

    static var settingsSnapshotWindow: NSWindow?

    static func snapshot(to url: URL, preferKeyWindow: Bool = false) {
        for w in NSApp.windows {
            print("window: \(w.title) visible=\(w.isVisible) frame=\(w.frame)")
        }
        let candidate = preferKeyWindow ? (settingsSnapshotWindow ?? NSApp.keyWindow)
                                        : NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 })
        guard let window = candidate,
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("snapshot: no window")
            NSApp.terminate(nil)
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Web views render out of process; paint their own snapshots on top.
        var webViews: [WKWebView] = []
        func collect(_ v: NSView) {
            if let w = v as? WKWebView { webViews.append(w) }
            v.subviews.forEach(collect)
        }
        collect(view)
        let group = DispatchGroup()
        var shots: [(NSRect, NSImage)] = []
        for w in webViews where !w.isHiddenOrHasHiddenAncestor {
            group.enter()
            w.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((w.convert(w.bounds, to: view), image)) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                for (rect, image) in shots {
                    let r = view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
                    image.draw(in: r)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("snapshot written to \(url.path) (\(shots.count) web views)")
            NSApp.terminate(nil)
        }
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

    func applicationWillTerminate(_ notification: Notification) {
        AttachmentBar.purgeTemporaryFiles()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PSTViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ViewerModel()
    /// Observed so the menu commands below are rebuilt when the language changes.
    @AppStorage(AppSettings.languageKey) private var language = LanguageSetting.system.rawValue

    init() {
        AppSettings.applyLanguage(AppSettings.language)
    }

    /// `tr()` that also reads `language`, so SwiftUI knows the scene depends on it.
    private func t(_ english: String, _ dutch: String) -> String {
        _ = language
        return tr(english, dutch)
    }

    var body: some Scene {
        Window("PST Viewer", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { url in
                    if url.isFileURL { model.open(url) }
                }
                .onAppear {
                    // `PSTViewer /path/to/file.pst` (or an mbox file or mail folder) from the command line.
                    let args = CommandLine.arguments.dropFirst()
                    var skipNext = false
                    for arg in args {
                        if skipNext { skipNext = false; continue }
                        if arg.hasPrefix("-") { skipNext = arg == "--snapshot"; continue }
                        let url = URL(fileURLWithPath: arg)
                        if FileManager.default.fileExists(atPath: url.path) { model.open(url) }
                    }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(t("Open PST File or Mail Folder…", "Open PST-bestand of mailmap…")) { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .importExport) {
                Button(t("Export Selected Message as .eml…", "Exporteer geselecteerd bericht als .eml…")) {
                    if let m = model.selectedMessage { model.exportMessages([m]) }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedMessage == nil)
                Button(t("Export Folder as mbox…", "Exporteer map als mbox…")) {
                    if let f = model.selectedFolder { model.exportFolderAsMbox(f) }
                }
                .disabled(model.selectedFolder == nil)
            }
        }

        WindowGroup(t("Message", "Bericht"), for: MessageRef.self) { $ref in
            if let ref {
                MessageContainerView(ref: ref)
                    .localizedRoot()
                    .environmentObject(model)
                    .frame(minWidth: 640, minHeight: 480)
            }
        }

        Settings {
            SettingsView()
                .localizedRoot()
                .environmentObject(model)
        }
    }
}
