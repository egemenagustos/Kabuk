import XCTest
@testable import KabukCore

final class InsightsTests: XCTestCase {
    func testClaudeTranscriptCountsEachMessageOnce() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hi"}}
        {"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50,"output_tokens":5}}}
        {"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":30},"output_tokens":40}}}
        {"type":"assistant","message":{"id":"m2","model":"claude-haiku-5-5","usage":{"input_tokens":3,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":60}}}
        not json
        """
        let usage = TokenUsage.fromClaudeTranscript(Data(jsonl.utf8))
        XCTAssertEqual(usage?.context, 2063)
        XCTAssertEqual(usage?.output, 100)
        XCTAssertEqual(usage?.byModel["claude-opus-5-5"],
                       TokenBreakdown(input: 10, cacheWrite5m: 20, cacheWrite1h: 30, cacheRead: 1000, output: 40))
        XCTAssertEqual(usage?.byModel["claude-haiku-5-5"], TokenBreakdown(input: 3, cacheRead: 2000, output: 60))
        XCTAssertNil(TokenUsage.fromClaudeTranscript(Data("{}".utf8)))
    }

    func testCodexRolloutUsesLastTokenCount() {
        let jsonl = """
        {"type":"session_meta","payload":{"id":"x"}}
        {"type":"turn_context","payload":{"model":"gpt-test"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10},"last_token_usage":{"input_tokens":100,"output_tokens":10}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":600,"output_tokens":70},"last_token_usage":{"input_tokens":800,"output_tokens":60}}}}
        {"type":"event_msg","payload":{"type":"token_count","info":null}}
        """
        let usage = TokenUsage.fromCodexRollout(Data(jsonl.utf8))
        XCTAssertEqual(usage?.context, 860)
        XCTAssertEqual(usage?.byModel, ["gpt-test": TokenBreakdown(input: 300, cacheRead: 600, output: 70)])
    }

    func testCompactNumbers() {
        XCTAssertEqual(TokenUsage.compact(950), "950")
        XCTAssertEqual(TokenUsage.compact(12_300), "12.3k")
        XCTAssertEqual(TokenUsage.compact(48_000), "48k")
        XCTAssertEqual(TokenUsage.compact(250_400), "250k")
        XCTAssertEqual(TokenUsage.compact(1_250_000), "1.25M")
    }

    func testGitStatusParse() {
        let status = """
        # branch.oid 1234567890abcdef
        # branch.head feature/scores
        # branch.upstream origin/feature/scores
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 abc def demo/snake.mjs
        2 R. N... 100644 100644 100644 abc def R100 new.txt\told.txt
        ? notes.md
        ? tmp/
        """
        let numstat = "12\t3\tdemo/snake.mjs\n-\t-\timage.png\n4\t0\tnew.txt\n"
        let git = GitStatus.parse(status: status, numstat: numstat)
        XCTAssertEqual(git, GitStatus(branch: "feature/scores", ahead: 2, behind: 1, changed: 2, untracked: 2, added: 16, removed: 3))
        XCTAssertEqual(git?.isDirty, true)

        let detached = GitStatus.parse(status: "# branch.oid abcdef1234\n# branch.head (detached)\n")
        XCTAssertEqual(detached?.branch, "abcdef1")
        XCTAssertNil(GitStatus.parse(status: ""))
    }

    func testThemes() throws {
        XCTAssertTrue(TerminalTheme.builtIn.allSatisfy(\.isValid))
        XCTAssertEqual(Set(TerminalTheme.builtIn.map(\.id)).count, TerminalTheme.builtIn.count)
        XCTAssertNotNil(TerminalTheme.rgb("#ff8800"))
        XCTAssertNil(TerminalTheme.rgb("#ff88"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var custom = TerminalTheme.kabuk
        custom.name = "Mine"
        try JSONEncoder().encode(custom).write(to: dir.appendingPathComponent("mine.json"))
        try Data("{broken".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let loaded = TerminalTheme.load(from: dir)
        XCTAssertEqual(loaded.map(\.name), ["Mine"])
        XCTAssertEqual(loaded.first?.id, "user:mine")
    }

    func testOldSnapshotStillLoads() throws {
        let old = #"{"projects":[],"sidebarVisible":false,"opacity":0.25,"fontSize":14}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(old.utf8))
        XCTAssertEqual(snapshot.opacity, 0.25)
        XCTAssertEqual(snapshot.themeID, "kabuk")
        XCTAssertTrue(snapshot.animatedBackground)

        // The old default (0.5) moves to Glass; a value the user picked otherwise stays.
        let oldDefault = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"projects":[],"opacity":0.5}"#.utf8))
        XCTAssertEqual(oldDefault.opacity, WorkspaceSnapshot.glass)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"projects":[]}"#.utf8)).opacity, WorkspaceSnapshot.glass)
    }

    func testAgentTimeAccumulatesAcrossTurns() {
        let t0 = Date(timeIntervalSince1970: 0)
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "shell", event: "start", cmd: "claude"), now: t0)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "UserPromptSubmit"), now: t0)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Notification", message: "permission"), now: t0 + 5)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PostToolUse"), now: t0 + 20)
        XCTAssertEqual(s.agentTime(now: t0 + 25), 25)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Stop",
                                              tokens: TokenUsage(context: 5000, output: 300)), now: t0 + 30)
        XCTAssertEqual(s.lastDuration, 30)
        XCTAssertEqual(s.agentWorkTime, 30)
        XCTAssertEqual(s.tokens, TokenUsage(context: 5000, output: 300))
        XCTAssertEqual(s.agentTime(now: t0 + 100), 30, "idle time between turns is not counted")

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "UserPromptSubmit"), now: t0 + 100)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Stop"), now: t0 + 110)
        XCTAssertEqual(s.agentWorkTime, 40)

        // Starting the agent again resets its stats.
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "shell", event: "end", code: 0), now: t0 + 120)
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "shell", event: "start", cmd: "claude"), now: t0 + 130)
        XCTAssertEqual(s.agentWorkTime, 0)
        XCTAssertNil(s.tokens)
    }
}
