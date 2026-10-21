import XCTest
@testable import KabukCore

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("0.1.0")!, AppVersion("v0.2.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("v1.2.3")?.description, "1.2.3")
        XCTAssertNil(AppVersion("Unreleased"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertEqual(Set([AppVersion("1.0")!, AppVersion("1.0.0")!]).count, 1)
    }

    private let changelog = """
    # Changelog

    Intro text.

    ## [Unreleased]

    ### Added

    - Something not released yet.

    ## [0.3.0] - 2026-12-01

    ### Fixed

    - A bug.

    ## [0.2.0] - 2026-11-01

    ### Added

    - **Undo a turn.** The turn card has an Undo button
      that wraps onto a second line.
    - Review notes.

    ### Changed

    - Faster.

    ## [0.1.0] - 2026-10-20

    - First release.

    [Unreleased]: https://example.com/compare/v0.3.0...HEAD
    [0.3.0]: https://example.com/compare/v0.2.0...v0.3.0
    """

    func testChangelogReleasesNewestFirstWithoutUnreleased() {
        let releases = Changelog.releases(changelog)
        XCTAssertEqual(releases.map(\.version.description), ["0.3.0", "0.2.0", "0.1.0"])
        XCTAssertEqual(releases[0].date, "2026-12-01")
        XCTAssertEqual(releases[2].body, "- First release.")
        XCTAssertEqual(releases[1].lines, [
            .heading("Added"),
            .entry("**Undo a turn.** The turn card has an Undo button that wraps onto a second line."),
            .entry("Review notes."),
            .heading("Changed"),
            .entry("Faster."),
        ])
    }

    func testWhatsNewShowsEveryVersionSinceTheOneSeen() {
        let releases = Changelog.releases(changelog)
        let current = AppVersion("0.3.0")!
        XCTAssertEqual(WhatsNew.notes(releases, lastSeen: "0.1.0", hasState: true, current: current).map(\.id), ["0.3.0", "0.2.0"])
        XCTAssertEqual(WhatsNew.notes(releases, lastSeen: "0.3.0", hasState: true, current: current), [])
        // Coming from 0.1.0, which didn't record anything.
        XCTAssertEqual(WhatsNew.notes(releases, lastSeen: nil, hasState: true, current: AppVersion("0.2.0")!).map(\.id), ["0.2.0"])
        // A first install.
        XCTAssertEqual(WhatsNew.notes(releases, lastSeen: nil, hasState: false, current: current), [])
        // Going back to an older build shows nothing.
        XCTAssertEqual(WhatsNew.notes(releases, lastSeen: "0.3.0", hasState: true, current: AppVersion("0.2.0")!), [])
    }

    func testGitHubReleasesPickTheNewestWithEveryNoteInBetween() throws {
        let json: [[String: Any]] = [
            ["tag_name": "v0.4.0-beta", "prerelease": true, "draft": false, "body": "", "html_url": "https://g/beta"],
            ["tag_name": "v0.5.0", "draft": true, "body": "", "html_url": "https://g/draft"],
            ["tag_name": "v0.2.0", "draft": false, "prerelease": false, "body": "### Added\r\n\r\n- B", "published_at": "2026-11-01T10:00:00Z",
             "html_url": "https://g/v0.2.0", "assets": [["name": "Kabuk-0.2.0.zip", "browser_download_url": "https://g/d/0.2.0.zip"]]],
            ["tag_name": "v0.3.0", "draft": false, "prerelease": false, "body": "- C", "published_at": "2026-12-01T10:00:00Z",
             "html_url": "https://g/v0.3.0", "assets": [
                ["name": "notes.txt", "browser_download_url": "https://g/d/notes.txt"],
                ["name": "Kabuk-0.3.0.zip", "browser_download_url": "https://g/d/0.3.0.zip"],
             ]],
            ["tag_name": "v0.1.0", "draft": false, "prerelease": false, "body": "- A", "html_url": "https://g/v0.1.0"],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let update = try XCTUnwrap(GitHubReleases.update(from: data, current: AppVersion("0.1.0")!))
        XCTAssertEqual(update.version.description, "0.3.0")
        XCTAssertEqual(update.download?.absoluteString, "https://g/d/0.3.0.zip")
        XCTAssertEqual(update.page.absoluteString, "https://g/v0.3.0")
        XCTAssertEqual(update.notes.map(\.id), ["0.3.0", "0.2.0"])
        XCTAssertEqual(update.notes[1].date, "2026-11-01")
        XCTAssertEqual(update.notes[1].lines, [.heading("Added"), .entry("B")])

        XCTAssertNil(GitHubReleases.update(from: data, current: AppVersion("0.3.0")!))
        XCTAssertNil(GitHubReleases.update(from: Data("{\"message\":\"rate limited\"}".utf8), current: AppVersion("0.1.0")!))
    }

    func testChecksAreDueOncePerDay() {
        let now = Date()
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.interval), now: now))
        // A clock that moved backwards doesn't stop checks for good.
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now))
    }
}
