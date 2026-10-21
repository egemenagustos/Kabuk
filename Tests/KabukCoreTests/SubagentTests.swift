import XCTest
@testable import KabukCore

final class SubagentTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_030)

    func claude(_ event: String, agent: String? = nil, type: String? = nil, tool: String? = nil, kind: String? = nil,
                detail: String? = nil, cwd: String? = nil, message: String? = nil) -> HookEvent {
        HookEvent(pane: "p", source: "claude", event: event, cwd: cwd, message: message, kind: kind, tool: tool, detail: detail,
                  agent: agent, agentType: type)
    }

    func working() -> PaneRuntime {
        var s = PaneRuntime(cwd: "/repo")
        s = StatusReducer.reduce(s, claude("UserPromptSubmit"), now: t0)
        return s
    }

    func testLaunchStartToolsAndStop() {
        var s = working()
        s = StatusReducer.reduce(s, claude("PreToolUse", tool: "Agent", kind: "general-purpose", detail: "Write the tests"), now: t0)
        XCTAssertEqual(s.launches, [SubagentLaunch(type: "general-purpose", description: "Write the tests")])
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "a1", type: "general-purpose"), now: t0)
        XCTAssertEqual(s.subagents.map(\.title), ["Write the tests"])
        XCTAssertTrue(s.launches.isEmpty)

        s = StatusReducer.reduce(s, claude("PostToolUse", agent: "a1", type: "general-purpose", tool: "Edit",
                                           cwd: "/repo/.claude/worktrees/agent-a1"), now: t0)
        XCTAssertEqual(s.subagents[0].toolCount, 1)
        XCTAssertEqual(s.subagents[0].lastTool, "Edit")
        XCTAssertEqual(s.subagents[0].cwd, "/repo/.claude/worktrees/agent-a1")
        XCTAssertEqual(s.cwd, "/repo", "a subagent's worktree doesn't move the pane")

        s = StatusReducer.reduce(s, claude("SubagentStop", agent: "a1", message: "Added 4 tests"), now: t1)
        XCTAssertEqual(s.subagents[0].state, .done)
        XCTAssertEqual(s.subagents[0].summary, "Added 4 tests")
        XCTAssertEqual(s.subagents[0].elapsed(now: t1), 30)
        XCTAssertEqual(s.status, .agentWorking(.claude, since: t0))
    }

    func testDescriptionFromTheHookWinsAndTypesPairUp() {
        var s = working()
        s = StatusReducer.reduce(s, claude("PreToolUse", tool: "Agent", kind: "Explore", detail: "Find the parser"), now: t0)
        s = StatusReducer.reduce(s, claude("PreToolUse", tool: "Agent", kind: "general-purpose", detail: "Fix the parser"), now: t0)
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "b", type: "general-purpose"), now: t0)
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "a", type: "Explore", detail: "From meta.json"), now: t0)
        XCTAssertEqual(s.subagents.map(\.title), ["Fix the parser", "From meta.json"])
        XCTAssertTrue(s.launches.isEmpty)
    }

    func testBackgroundSubagentOutlivesTheTurn() {
        var s = working()
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "done", type: "Explore"), now: t0)
        s = StatusReducer.reduce(s, claude("SubagentStop", agent: "done"), now: t0)
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "bg", type: "general-purpose"), now: t0)
        s = StatusReducer.reduce(s, claude("Stop"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))

        // Its tool use doesn't make the finished main agent look busy again.
        s = StatusReducer.reduce(s, claude("PostToolUse", agent: "bg", tool: "Bash"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))
        XCTAssertNil(s.turnStartedAt)

        s = StatusReducer.reduce(s, claude("UserPromptSubmit"), now: t1)
        XCTAssertEqual(s.subagents.map(\.id), ["bg"])

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "shell", event: "end", code: 0), now: t1)
        XCTAssertTrue(s.subagents.isEmpty)
    }

    func testOneSubagentDoesNotClearAnothersPermission() {
        var s = working()
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PermissionRequest", request: "r1", tool: "Bash",
                                              detail: "rm -rf build", agent: "a"), now: t0)
        XCTAssertEqual(s.permission?.agent, "a")
        s = StatusReducer.reduce(s, claude("PostToolUse", agent: "b", tool: "Read"), now: t0)
        s = StatusReducer.reduce(s, claude("SubagentStart", agent: "c", type: "Explore"), now: t0)
        XCTAssertNotNil(s.permission)
        s = StatusReducer.reduce(s, claude("PostToolUse", agent: "a", tool: "Bash"), now: t0)
        XCTAssertNil(s.permission)
    }

    func testIsolationOnlyForEditingAgentsInARepository() {
        let input: [String: Any] = ["description": "Fix", "prompt": "Fix it", "subagent_type": "general-purpose"]
        let updated = SubagentIsolation.updatedInput(input, enabled: true, inGitRepository: true)
        XCTAssertEqual(updated?["isolation"] as? String, "worktree")
        XCTAssertEqual(updated?["prompt"] as? String, "Fix it")
        XCTAssertNil(SubagentIsolation.updatedInput(input, enabled: false, inGitRepository: true))
        XCTAssertNil(SubagentIsolation.updatedInput(input, enabled: true, inGitRepository: false))
        XCTAssertNil(SubagentIsolation.updatedInput(["subagent_type": "Explore"], enabled: true, inGitRepository: true))
        XCTAssertNil(SubagentIsolation.updatedInput(["isolation": "none"], enabled: true, inGitRepository: true))
        XCTAssertNotNil(SubagentIsolation.updatedInput(["prompt": "x"], enabled: true, inGitRepository: true), "no type means general-purpose")

        let output = SubagentIsolation.hookOutput(["isolation": "worktree"])
        XCTAssertEqual(output, #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"isolation":"worktree"}}}"#)
    }

    func testFindsTheRepositoryAbove() {
        let existing: Set<String> = ["/work/app/.git"]
        XCTAssertTrue(SubagentIsolation.inGitRepository("/work/app/src/ui", fileExists: existing.contains))
        XCTAssertFalse(SubagentIsolation.inGitRepository("/work/other", fileExists: existing.contains))
    }

    func testTranscriptSteps() {
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"go"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Looking at the parser."},{"type":"tool_use","name":"Read","input":{"file_path":"/r/parser.swift"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}
        not json
        """
        let steps = SubagentTranscript.steps(Data(jsonl.utf8))
        XCTAssertEqual(steps.map(\.title), ["Claude", "Read", "Bash"])
        XCTAssertEqual(steps[1].detail, "/r/parser.swift")
        XCTAssertEqual(steps[2].detail, "swift test")
        XCTAssertEqual(SubagentTranscript.steps(Data(jsonl.utf8), limit: 1).map(\.title), ["Bash"])
    }
}
