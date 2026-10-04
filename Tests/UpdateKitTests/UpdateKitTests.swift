import XCTest
@testable import UpdateKit

final class UpdateKitTests: XCTestCase {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    func testVersionParsing() {
        XCTAssertEqual(v("v1.2.3").components, [1, 2, 3])
        XCTAssertEqual(v("1.0").description, "1.0")
        XCTAssertEqual(v("v2.0-beta.1").preRelease, "beta.1")
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("1.x"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("latest"))
    }

    func testVersionOrdering() {
        XCTAssertLessThan(v("1.9"), v("1.10"))
        XCTAssertLessThan(v("1.0"), v("1.0.1"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertLessThan(v("1.2-beta"), v("1.2"))
        XCTAssertLessThan(v("1.2-beta.2"), v("1.2-beta.10"))
        XCTAssertLessThan(v("1.2"), v("1.3-beta"))
        XCTAssertFalse(v("2.0") < v("1.9.9"))
    }

    let json = """
    {
      "tag_name": "v1.2.0",
      "name": "PST Viewer 1.2.0",
      "body": "## What's Changed\\r\\n* **Faster** search\\r\\n- Fix by @someone",
      "html_url": "https://github.com/mukreb/mac-pst-viewer/releases/tag/v1.2.0",
      "draft": false,
      "prerelease": false,
      "assets": [
        {"name": "checksums.txt", "size": 10, "browser_download_url": "https://example.com/checksums.txt"},
        {"name": "PST-Viewer.zip", "size": 4000000, "browser_download_url": "https://example.com/PST-Viewer.zip"}
      ]
    }
    """

    func testDecodeRelease() throws {
        let release = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertEqual(release.version, v("1.2"))
        XCTAssertEqual(release.appArchive()?.name, "PST-Viewer.zip")
        XCTAssertEqual(release.appArchive()?.browserDownloadURL.absoluteString, "https://example.com/PST-Viewer.zip")
    }

    func testAvailableUpdate() throws {
        let release = try GitHubRelease.decode(Data(json.utf8))
        XCTAssertNotNil(AvailableUpdate(current: v("1.1.9"), release: release))
        XCTAssertNil(AvailableUpdate(current: v("1.2"), release: release))
        XCTAssertNil(AvailableUpdate(current: v("1.3"), release: release))
        let update = try XCTUnwrap(AvailableUpdate(current: v("1.0"), release: release))
        XCTAssertEqual(update.plainNotes, "What's Changed\n• Faster search\n• Fix by @someone")

        let pre = try GitHubRelease.decode(Data(json.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true").utf8))
        XCTAssertNil(AvailableUpdate(current: v("1.0"), release: pre))
    }

    func testBuildsChannel() throws {
        let tagged = try GitHubRelease.decode(Data(json.utf8))
        let build = try GitHubRelease.decode(Data(json
            .replacingOccurrences(of: "\"v1.2.0\"", with: "\"build-1.2.0.57\"")
            .replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true").utf8))
        XCTAssertEqual(build.version, v("1.2.0.57"))
        let releases = [build, tagged]
        XCTAssertEqual(AvailableUpdate.newest(current: v("1.1.0.40"), in: releases, channel: .builds)?.version, v("1.2.0.57"))
        XCTAssertEqual(AvailableUpdate.newest(current: v("1.1.0.40"), in: releases, channel: .releases)?.version, v("1.2.0"))
        // A build of main after a release is newer than that release, so no downgrade is offered.
        XCTAssertNil(AvailableUpdate.newest(current: v("1.2.0.57"), in: releases, channel: .releases))
        XCTAssertNil(AvailableUpdate.newest(current: v("1.2.0.57"), in: releases, channel: .builds))
    }

    func testReleasesURL() {
        XCTAssertEqual(releasesURL(repository: "mukreb/mac-pst-viewer", channel: .releases)?.absoluteString,
                       "https://api.github.com/repos/mukreb/mac-pst-viewer/releases/latest")
        XCTAssertEqual(releasesURL(repository: "mukreb/mac-pst-viewer", channel: .builds)?.absoluteString,
                       "https://api.github.com/repos/mukreb/mac-pst-viewer/releases?per_page=30")
        XCTAssertNil(releasesURL(repository: "mukreb", channel: .releases))
        XCTAssertNil(releasesURL(repository: "a/b/c", channel: .releases))
        XCTAssertNil(releasesURL(repository: "a/b?x=1", channel: .releases))
    }
}
