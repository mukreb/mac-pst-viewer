import AppKit
import PSTKit
import Security
import UpdateKit

/// Checks GitHub releases for a newer version and installs it in place.
///
/// The repository comes from `PSTUpdateRepository` in Info.plist; the release must have the
/// zipped app (`PST-Viewer.zip`) attached, as the Build workflow does for `v*` tags. An update is
/// only installed when it is signed by the same Developer ID team as the running app; otherwise
/// (self-built or ad-hoc signed apps) the app offers to open the release page instead.
final class Updater: ObservableObject {
    static let shared = Updater()

    static let automaticKey = "checkForUpdatesAutomatically"
    static let lastCheckKey = "lastUpdateCheck"
    static let skippedVersionKey = "skippedUpdateVersion"

    @Published private(set) var isBusy = false

    private let checkInterval: TimeInterval = 24 * 60 * 60

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!
    }

    private var repository: String? {
        Bundle.main.object(forInfoDictionaryKey: "PSTUpdateRepository") as? String
    }

    /// Checks quietly at launch, at most once a day, when automatic checks are on (the default).
    @MainActor
    func checkInBackgroundIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < checkInterval { return }
        Task { await check(userInitiated: false) }
    }

    /// Looks for a newer release. A background check stays silent unless it finds one the user
    /// hasn't skipped; a check from the menu also reports "up to date" and errors.
    @MainActor
    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let url = repository.flatMap(latestReleaseURL(repository:)) else {
                throw UpdateError.message(tr("This build has no update source.", "Deze versie heeft geen updatebron."))
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                // No published release yet.
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if userInitiated { showUpToDate() }
                return
            }
            guard status == 200 else {
                throw UpdateError.message(tr("GitHub answered with status \(status).", "GitHub antwoordde met status \(status)."))
            }
            let release = try GitHubRelease.decode(data)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard let update = AvailableUpdate(current: currentVersion, release: release) else {
                if userInitiated { showUpToDate() }
                return
            }
            if !userInitiated && UserDefaults.standard.string(forKey: Self.skippedVersionKey) == update.version.description {
                return
            }
            await offer(update)
        } catch {
            if userInitiated { showError(error, title: tr("Couldn't check for updates", "Kan niet zoeken naar updates")) }
        }
    }

    // MARK: - Dialogs

    @MainActor
    private func offer(_ update: AvailableUpdate) async {
        let canInstall = installBlocker(for: update) == nil
        let alert = NSAlert()
        alert.messageText = tr("PST Viewer \(update.version) is available", "PST Viewer \(update.version) is beschikbaar")
        alert.informativeText = tr("You have version \(currentVersion). Would you like to update now?",
                                   "Je hebt versie \(currentVersion). Wil je nu bijwerken?")
        let notes = update.plainNotes
        if !notes.isEmpty { alert.accessoryView = Self.notesView(notes) }
        alert.addButton(withTitle: canInstall ? tr("Install and Relaunch", "Installeer en herstart")
                                              : tr("Download…", "Download…"))
        alert.addButton(withTitle: tr("Later", "Later"))
        alert.addButton(withTitle: tr("Skip This Version", "Sla deze versie over"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if canInstall {
                await install(update)
            } else {
                NSWorkspace.shared.open(update.release.htmlURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(update.version.description, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    @MainActor
    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.string = notes
        scroll.documentView = text
        return scroll
    }

    @MainActor
    private func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = tr("You're up to date", "Je bent bijgewerkt")
        alert.informativeText = tr("PST Viewer \(currentVersion) is the latest version.",
                                   "PST Viewer \(currentVersion) is de nieuwste versie.")
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    @MainActor
    private func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = (error as? UpdateError)?.text ?? error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    // MARK: - Installing

    /// Why this copy of the app can't replace itself, or nil when it can.
    private func installBlocker(for update: AvailableUpdate) -> String? {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { return "not running from an app bundle" }
        guard update.release.appArchive() != nil else { return "the release has no app archive" }
        guard Self.teamIdentifier(of: app) != nil else { return "the running app has no Developer ID signature" }
        // A quarantined app run from its download location is moved to a random read-only path.
        guard !app.path.contains("/AppTranslocation/") else { return "the app is translocated" }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: app.path) else { return "the app's folder isn't writable" }
        return nil
    }

    @MainActor
    private func install(_ update: AvailableUpdate) async {
        isBusy = true
        defer { isBusy = false }
        let app = Bundle.main.bundleURL
        let fm = FileManager.default
        var work: URL?
        do {
            guard let asset = update.release.appArchive(),
                  let team = Self.teamIdentifier(of: app),
                  let bundleID = Bundle.main.bundleIdentifier else {
                throw UpdateError.message(tr("This copy of the app can't update itself.", "Deze kopie van de app kan zichzelf niet bijwerken."))
            }
            // A folder on the same volume as the app, so the swap below is a rename.
            let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
            work = dir

            let (download, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.message(tr("The download failed.", "De download is mislukt."))
            }
            let zip = dir.appendingPathComponent("update.zip")
            try fm.moveItem(at: download, to: zip)
            let extracted = dir.appendingPathComponent("extracted", isDirectory: true)
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])

            guard let newApp = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.message(tr("The download doesn't contain the app.", "De download bevat de app niet."))
            }
            try Self.verify(newApp, team: team, bundleID: bundleID, version: update.version)

            _ = try fm.replaceItemAt(app, withItemAt: newApp)
            try? fm.removeItem(at: dir)
            relaunch(app)
        } catch {
            if let work { try? fm.removeItem(at: work) }
            showError(error, title: tr("Couldn't install the update", "Kan de update niet installeren"))
        }
    }

    /// Checks that the downloaded app is intact, signed with a Developer ID of the same team as
    /// this app, is the same app, and is the version that was offered.
    private static func verify(_ app: URL, team: String, bundleID: String, version: AppVersion) throws {
        let invalid = UpdateError.message(tr("The downloaded app isn't signed by the same developer. The update was not installed.",
                                             "De gedownloade app is niet door dezelfde ontwikkelaar ondertekend. De update is niet geïnstalleerd."))
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw invalid }
        // Apple's Developer ID requirement, pinned to this app's team and bundle identifier.
        let requirementText = """
            anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(team)" and identifier "\(bundleID)"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw invalid }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw invalid }

        let newVersion = (Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
        guard let newVersion, newVersion == version else {
            throw UpdateError.message(tr("The downloaded app has an unexpected version. The update was not installed.",
                                         "De gedownloade app heeft een onverwachte versie. De update is niet geïnstalleerd."))
        }
    }

    /// The Team ID of a Developer ID (or other Apple-issued) signature; nil for ad-hoc signed apps.
    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError.message(tr("Unpacking the update failed.", "Het uitpakken van de update is mislukt."))
            }
        }.value
    }

    /// Quits, and opens the (replaced) app again once this process has exited.
    @MainActor
    private func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

private enum UpdateError: Error {
    case message(String)

    var text: String {
        switch self {
        case .message(let s): return s
        }
    }
}
