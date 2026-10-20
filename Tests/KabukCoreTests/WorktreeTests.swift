import XCTest
@testable import KabukCore

final class WorktreeTests: XCTestCase {
    func testNaming() {
        XCTAssertEqual(WorktreeNaming.name(agent: .claude, suffix: "7f3a"), "claude-7f3a")
        XCTAssertEqual(WorktreeNaming.name(agent: nil, suffix: "0001"), "shell-0001")
        XCTAssertEqual(WorktreeNaming.branch(for: "codex-01bc"), "kabuk/codex-01bc")
        XCTAssertEqual(WorktreeNaming.path(repoRoot: "/Users/me/src/snake", name: "claude-7f3a",
                                           root: URL(fileURLWithPath: "/tmp/wt")),
                       "/tmp/wt/snake/claude-7f3a")
        XCTAssertEqual(WorktreeNaming.randomSuffix().count, 4)
    }

    func testSessionWithoutWorktreeStillDecodes() throws {
        let session = Session(cwd: "/tmp")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        json.removeValue(forKey: "worktree")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.worktree)

        var withTree = session
        withTree.worktree = WorktreeInfo(path: "/w/a", branch: "kabuk/a", repoRoot: "/r", baseRef: "abc")
        let roundTrip = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(withTree))
        XCTAssertEqual(roundTrip.worktree?.name, "a")
    }
}
