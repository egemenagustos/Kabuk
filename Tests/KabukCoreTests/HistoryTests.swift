import XCTest
@testable import KabukCore

final class HistoryTests: XCTestCase {
    func testZshHistoryFormats() {
        var raw = Data(": 1700000000:0;git status\n: 1700000100:3;echo one \\\n  two\nls -la\n".utf8)
        // "ş" is 0xC5 0x9F; zsh metafies 0x9F (>= 0x83) as 0x83 0xBF.
        raw.append(contentsOf: [0x3A, 0x20, 0x31, 0x3A, 0x30, 0x3B, 0x65, 0x63, 0x68, 0x6F, 0x20, 0xC5, 0x83, 0xBF, 0x0A])
        let entries = ZshHistory.parse(raw)
        XCTAssertEqual(entries.map(\.command), ["git status", "echo one \n  two", "ls -la", "echo ş"])
        XCTAssertEqual(entries[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(entries[2].date, Date(timeIntervalSince1970: 2), "plain lines are dated by position")
        XCTAssertFalse(entries[2].hasKnownDate)
        XCTAssertTrue(entries[0].hasKnownDate)
        XCTAssertEqual(ZshHistory.parse(Data("  padded command \n".utf8)).map(\.command), ["padded command"])
    }

    func testSearchDedupesAndRanks() {
        let d = { Date(timeIntervalSince1970: $0) }
        let entries = [
            HistoryEntry(command: "npm run dev", cwd: "/a", date: d(1)),
            HistoryEntry(command: "git push", cwd: "/a", date: d(2)),
            HistoryEntry(command: "npm run dev", cwd: "/b", date: d(3)),
            HistoryEntry(command: "npm test", cwd: "/a", date: d(4)),
        ]
        XCTAssertEqual(HistorySearch.search(entries, query: "").map(\.command), ["npm test", "npm run dev", "git push"])
        XCTAssertEqual(HistorySearch.search(entries, query: "").first(where: { $0.command == "npm run dev" })?.cwd, "/b")
        XCTAssertEqual(HistorySearch.search(entries, query: "nrd").map(\.command), ["npm run dev"])
        XCTAssertEqual(HistorySearch.search(entries, query: "", cwd: "/a").map(\.command), ["npm test", "git push", "npm run dev"])
        XCTAssertEqual(HistorySearch.search(entries, query: "zzz"), [])
    }

    func testShouldRecord() {
        XCTAssertTrue(HistoryEntry.shouldRecord("ls"))
        XCTAssertFalse(HistoryEntry.shouldRecord(" secret-token"))
        XCTAssertFalse(HistoryEntry.shouldRecord("   "))
    }
}
