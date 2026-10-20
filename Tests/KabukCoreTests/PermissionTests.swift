import XCTest
@testable import KabukCore

final class PermissionTests: XCTestCase {
    func testRequestHeldThenClearedByProgress() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "UserPromptSubmit"))
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PermissionRequest",
                                              request: "r1", tool: "Bash", detail: "npm test", canAlwaysAllow: true))
        XCTAssertEqual(s.permission, PermissionPrompt(id: "r1", tool: "Bash", detail: "npm test", canAlwaysAllow: true))
        XCTAssertEqual(s.status, .agentNeedsYou(.claude, message: "Allow Bash: npm test"))

        // Claude's own "waiting for permission" notification must not drop the held request.
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Notification", message: "needs permission"))
        XCTAssertNotNil(s.permission)

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PostToolUse"))
        XCTAssertNil(s.permission)
        XCTAssertFalse(s.status.needsYou)
    }

    func testAgentExitClearsRequest() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PermissionRequest", request: "r", tool: "Edit"))
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "shell", event: "end", code: 0))
        XCTAssertNil(s.permission)
    }

    func testDetailSummaries() {
        XCTAssertEqual(PermissionSummary.detail(tool: "Bash", input: ["command": "rm -rf build\necho done", "description": "x"]),
                       "rm -rf build ⏎ echo done")
        XCTAssertEqual(PermissionSummary.detail(tool: "Edit", input: ["file_path": "/a/b.swift", "old_string": "x"]), "/a/b.swift")
        XCTAssertEqual(PermissionSummary.detail(tool: "mcp__x__y", input: ["b": 1, "a": "z"]), #"{"a":"z","b":1}"#)
        XCTAssertEqual(PermissionSummary.detail(tool: "Thing", input: [:]), "Thing")
        XCTAssertEqual(PermissionSummary.detail(tool: "Bash", input: ["command": String(repeating: "a", count: 400)]).count, 160)
    }

    func testHookOutput() throws {
        XCTAssertNil(PermissionSummary.hookOutput(.ask, suggestions: nil))

        let allow = try decision(PermissionSummary.hookOutput(.allow, suggestions: nil))
        XCTAssertEqual(allow["behavior"] as? String, "allow")
        XCTAssertNil(allow["updatedPermissions"])

        let rules: [Any] = [["type": "addRules", "behavior": "allow"]]
        let always = try decision(PermissionSummary.hookOutput(.always, suggestions: rules))
        XCTAssertEqual((always["updatedPermissions"] as? [Any])?.count, 1)

        let deny = try decision(PermissionSummary.hookOutput(.deny, suggestions: nil))
        XCTAssertEqual(deny["behavior"] as? String, "deny")
        XCTAssertNotNil(deny["message"])
    }

    private func decision(_ output: String?) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output).utf8)) as! [String: Any]
        let specific = json["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        return specific["decision"] as! [String: Any]
    }
}
