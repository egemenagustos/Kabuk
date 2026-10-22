import XCTest
@testable import KabukCore

final class AgentEventTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_012)

    func shell(_ event: String, cmd: String? = nil, code: Int32? = nil) -> HookEvent {
        HookEvent(pane: "p", source: "shell", event: event, cmd: cmd, code: code)
    }

    func agent(_ source: String, _ event: String, message: String? = nil, prompt: String? = nil) -> HookEvent {
        HookEvent(pane: "p", source: source, event: event, message: message, prompt: prompt)
    }

    func testHookedAgentLifecycle() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "gemini"), now: t0)
        XCTAssertEqual(s.status, .agentReady(.gemini))
        XCTAssertEqual(s.tag, "gemini")
        s = StatusReducer.reduce(s, agent("gemini", AgentEvent.turnStart, prompt: "fix the bug"), now: t0)
        XCTAssertEqual(s.status, .agentWorking(.gemini, since: t0))
        XCTAssertEqual(s.lastPrompt, "fix the bug")
        XCTAssertTrue(s.hooked)
        s = StatusReducer.reduce(s, agent("gemini", AgentEvent.tool), now: t0)
        XCTAssertEqual(s.status, .agentWorking(.gemini, since: t0))
        s = StatusReducer.reduce(s, agent("gemini", AgentEvent.needsYou, message: "Allow shell?"), now: t0)
        XCTAssertEqual(s.status, .agentNeedsYou(.gemini, message: "Allow shell?"))
        s = StatusReducer.reduce(s, agent("gemini", AgentEvent.turnEnd), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))
        XCTAssertNil(s.turnStartedAt)
        XCTAssertEqual(s.agentWorkTime, 12)
        XCTAssertEqual(s.agent, .gemini)

        s = StatusReducer.reduce(s, shell("end", code: 0), now: t1)
        XCTAssertNil(s.agent)
        XCTAssertFalse(s.hooked)
    }

    func testPermissionIsHeldAndClearedByProgress() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "copilot"), now: t0)
        var ask = agent("copilot", AgentEvent.permission)
        ask.request = "r1"
        ask.tool = "bash"
        ask.detail = "rm -rf build"
        s = StatusReducer.reduce(s, ask, now: t0)
        XCTAssertEqual(s.permission?.id, "r1")
        XCTAssertEqual(s.status, .agentNeedsYou(.copilot, message: "Allow bash: rm -rf build"))
        s = StatusReducer.reduce(s, agent("copilot", AgentEvent.tool), now: t1)
        XCTAssertNil(s.permission)
        XCTAssertEqual(s.status, .agentWorking(.copilot, since: t1))
    }

    func testGuessesForAgentsWithoutHooks() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "aider"), now: t0)
        let aider = s.agent!
        XCTAssertEqual(s.status, .agentReady(aider))
        s = StatusReducer.submitted(s, now: t0)
        XCTAssertEqual(s.status, .agentWorking(aider, since: t0))
        // A question in a notification waits for the user; anything else ends the turn.
        var asked = StatusReducer.reduce(s, agent("aider", AgentEvent.notification, message: "Approve edit?"), now: t1)
        XCTAssertEqual(asked.status, .agentNeedsYou(aider, message: "Approve edit?"))
        asked = StatusReducer.submitted(asked, now: t1)
        XCTAssertEqual(asked.status, .agentWorking(aider, since: t1))

        let done = StatusReducer.reduce(s, agent("aider", AgentEvent.notification, message: "Done"), now: t1)
        XCTAssertEqual(done.status, .succeeded(finishedAt: t1))
        XCTAssertEqual(done.lastDuration, 12)
        let quiet = StatusReducer.reduce(s, agent("aider", AgentEvent.quiet), now: t1)
        XCTAssertEqual(quiet.status, .succeeded(finishedAt: t1))
        // Quiet means nothing while the agent isn't working.
        let ready = StatusReducer.reduce(PaneRuntime(cwd: "/"), shell("start", cmd: "aider"), now: t0)
        XCTAssertEqual(StatusReducer.reduce(ready, agent("aider", AgentEvent.quiet), now: t1), ready)
    }

    func testGuessesStopOnceHooksReport() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "opencode"), now: t0)
        // Before any hook, return starts a turn.
        XCTAssertEqual(StatusReducer.submitted(s, now: t0).status, .agentWorking(.opencode, since: t0))
        s = StatusReducer.reduce(s, agent("opencode", AgentEvent.turnStart), now: t0)
        XCTAssertEqual(StatusReducer.reduce(s, agent("opencode", AgentEvent.quiet), now: t1), s)
        XCTAssertEqual(StatusReducer.reduce(s, agent("opencode", AgentEvent.notification, message: "done"), now: t1), s)
        s = StatusReducer.reduce(s, agent("opencode", AgentEvent.turnEnd), now: t1)
        XCTAssertEqual(StatusReducer.submitted(s, now: t1), s)
    }

    func testClaudeAndCodexIgnoreGuesses() {
        var claude = PaneRuntime(cwd: "/")
        claude = StatusReducer.reduce(claude, shell("start", cmd: "claude"), now: t0)
        XCTAssertEqual(StatusReducer.reduce(claude, agent("claude", AgentEvent.notification, message: "Done"), now: t1), claude)
        var codex = PaneRuntime(cwd: "/")
        codex = StatusReducer.reduce(codex, shell("start", cmd: "codex \"go\""), now: t0)
        XCTAssertEqual(StatusReducer.reduce(codex, agent("codex", AgentEvent.quiet), now: t1), codex)
    }

    func testGuessesForAnotherAgentAreIgnored() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "aider"), now: t0)
        XCTAssertEqual(StatusReducer.reduce(s, agent("goose", AgentEvent.notification, message: "Done?"), now: t1), s)
        XCTAssertEqual(StatusReducer.reduce(s, agent("nobody", AgentEvent.turnStart), now: t1), s)
    }

    func testNotificationText() {
        XCTAssertEqual(AgentEvent.notificationText(code: 9, payload: "Task finished"), "Task finished")
        XCTAssertNil(AgentEvent.notificationText(code: 9, payload: "4;1;50"), "ConEmu progress")
        XCTAssertEqual(AgentEvent.notificationText(code: 9, payload: "3 tests failed; see log"), "3 tests failed; see log")
        XCTAssertEqual(AgentEvent.notificationText(code: 777, payload: "notify;Amp;Waiting for approval"), "Amp: Waiting for approval")
        XCTAssertNil(AgentEvent.notificationText(code: 777, payload: "preexec"))
        XCTAssertEqual(AgentEvent.notificationText(code: 99, payload: "i=1:d=1;Done"), "Done")
        XCTAssertNil(AgentEvent.notificationText(code: 99, payload: "i=1:d=0;Partial"))
        XCTAssertNil(AgentEvent.notificationText(code: 99, payload: "i=1:p=close;"))
        XCTAssertNil(AgentEvent.notificationText(code: 7, payload: "file:///tmp"))
        XCTAssertTrue(AgentEvent.asksForInput("Claude needs your permission"))
        XCTAssertFalse(AgentEvent.asksForInput("Agent finished"))
    }
}
