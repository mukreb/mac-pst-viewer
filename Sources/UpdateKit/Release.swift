import Foundation

/// A dotted version number such as `1.2` or `v1.10.3-beta.1`, compared numerically
/// (`1.10` is newer than `1.9`, `1.2` equals `1.2.0`). A version with a pre-release suffix
/// is older than the same version without one; suffixes are compared as text.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let components: [Int]
    public let preRelease: String?

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = parts.first, !core.isEmpty else { return nil }
        var numbers: [Int] = []
        for piece in core.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(piece), n >= 0 else { return nil }
            numbers.append(n)
        }
        components = numbers
        preRelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (preRelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        switch (lhs.preRelease, rhs.preRelease) {
        case let (a?, b?): return a.compare(b, options: .numeric) == .orderedAscending
        case (_?, nil): return true
        default: return false
        }
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// The parts of a GitHub release (`GET /repos/{owner}/{repo}/releases/latest`) the updater uses.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// The version in the tag (`v1.2.0` → 1.2.0), if it is one.
    public var version: AppVersion? { AppVersion(tagName) }

    /// The zipped app to install: the `.zip` asset whose name starts with `prefix`, or else the only `.zip`.
    public func appArchive(prefix: String = "PST-Viewer") -> Asset? {
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        return zips.first { $0.name.hasPrefix(prefix) } ?? (zips.count == 1 ? zips[0] : nil)
    }
}

/// A release that is newer than the running app.
public struct AvailableUpdate: Sendable {
    public let version: AppVersion
    public let release: GitHubRelease

    /// Returns the update `release` offers over `current`, or nil when it isn't a newer, published release.
    public init?(current: AppVersion, release: GitHubRelease) {
        guard !release.draft, !release.prerelease,
              let version = release.version, current < version else { return nil }
        self.version = version
        self.release = release
    }

    /// The release notes without Markdown markup that reads badly as plain text.
    public var plainNotes: String {
        let lines = (release.body ?? "").replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line -> String in
            var s = String(line)
            while s.hasPrefix("#") { s.removeFirst() }
            if s.hasPrefix("* ") { s = "• " + s.dropFirst(2) }
            if s.hasPrefix("- ") { s = "• " + s.dropFirst(2) }
            return s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `https://api.github.com/repos/{owner}/{repo}/releases/latest` for a repository written as `owner/repo`.
public func latestReleaseURL(repository: String) -> URL? {
    let parts = repository.split(separator: "/")
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
    else { return nil }
    return URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/releases/latest")
}
