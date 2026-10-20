import XCTest
@testable import KabukCore

final class StatusReducerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_012)

    func shell(_ event: String, cmd: String? = nil, code: Int32? = nil, cwd: String? = nil) -> HookEvent {
        HookEvent(pane: "p", source: "shell", event: event, cmd: cmd, code: code, cwd: cwd)
    }

    func testCommandRunsThenSucceeds() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "npm run dev"), now: t0)
        XCTAssertEqual(s.status, .running(command: "npm run dev", startedAt: t0))
        XCTAssertEqual(s.tag, "node")
        s = StatusReducer.reduce(s, shell("end", code: 0, cwd: "/tmp"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))
        XCTAssertEqual(s.lastDuration, 12)
        XCTAssertEqual(s.cwd, "/tmp")
        XCTAssertEqual(s.tag, "zsh")
    }

    func testFailureAndInterrupt() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "false"), now: t0)
        s = StatusReducer.reduce(s, shell("end", code: 1), now: t1)
        XCTAssertEqual(s.status, .failed(code: 1, finishedAt: t1))

        s = StatusReducer.reduce(s, shell("start", cmd: "sleep 100"), now: t0)
        s = StatusReducer.reduce(s, shell("end", code: 130), now: t1)
        XCTAssertEqual(s.status, .idle)
    }

    func testPromptOnlyUpdatesCwd() {
        var s = PaneRuntime(cwd: "/")
        s.status = .succeeded(finishedAt: t0)
        s = StatusReducer.reduce(s, shell("prompt", cwd: "/Users"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t0))
        XCTAssertEqual(s.cwd, "/Users")
    }

    func testClaudeLifecycle() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "claude"), now: t0)
        XCTAssertEqual(s.status, .agentReady(.claude))
        XCTAssertEqual(s.tag, "claude")

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "UserPromptSubmit", prompt: "fix it"), now: t0)
        XCTAssertEqual(s.status, .agentWorking(.claude, since: t0))
        XCTAssertEqual(s.lastPrompt, "fix it")

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Notification",
                                              message: "Claude needs your permission to use Bash"), now: t0)
        XCTAssertTrue(s.status.needsYou)

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "PostToolUse"), now: t0)
        XCTAssertEqual(s.status, .agentWorking(.claude, since: t0))

        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "claude", event: "Stop"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))
        XCTAssertEqual(s.agent, .claude)

        // The idle reminder must not turn a finished turn into "needs you".
        let reminder = HookEvent(pane: "p", source: "claude", event: "Notification",
                                 message: "Claude is waiting for your input")
        XCTAssertEqual(StatusReducer.reduce(s, reminder, now: t1).status, .succeeded(finishedAt: t1))

        s = StatusReducer.reduce(s, shell("end", code: 0), now: t1)
        XCTAssertNil(s.agent)
        XCTAssertEqual(s.tag, "zsh")
    }

    func testCodexLifecycle() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "codex"), now: t0)
        XCTAssertEqual(s.status, .agentReady(.codex))
        s = StatusReducer.submitted(s, now: t0)
        XCTAssertEqual(s.status, .agentWorking(.codex, since: t0))
        s = StatusReducer.reduce(s, HookEvent(pane: "p", source: "codex", event: "agent-turn-complete"), now: t1)
        XCTAssertEqual(s.status, .succeeded(finishedAt: t1))
        XCTAssertEqual(s.lastDuration, 12)

        var started = PaneRuntime(cwd: "/")
        started = StatusReducer.reduce(started, shell("start", cmd: "codex \"add tests\""), now: t0)
        XCTAssertEqual(started.status, .agentWorking(.codex, since: t0))
        var resumed = PaneRuntime(cwd: "/")
        resumed = StatusReducer.reduce(resumed, shell("start", cmd: "codex resume --last"), now: t0)
        XCTAssertEqual(resumed.status, .agentReady(.codex))
    }

    func testSubmitIgnoredOutsideCodex() {
        var s = PaneRuntime(cwd: "/")
        s = StatusReducer.reduce(s, shell("start", cmd: "claude"), now: t0)
        XCTAssertEqual(StatusReducer.submitted(s, now: t1), s)
    }

    func testCommandInfo() {
        XCTAssertEqual(CommandInfo.tag("FOO=1 sudo /usr/bin/python3 x.py"), "python")
        XCTAssertEqual(CommandInfo.tag("htop"), "htop")
        XCTAssertEqual(CommandInfo.agent("~/.local/bin/claude --continue"), .claude)
        XCTAssertNil(CommandInfo.agent("claude-mods"))
        XCTAssertEqual(CommandInfo.tag("cd ~/app && python3 -m http.server 8765"), "python")
        XCTAssertEqual(CommandInfo.agent("cd repo; export X=1 && claude --continue"), .claude)
        XCTAssertEqual(CommandInfo.tag("cd /tmp"), "cd")
        XCTAssertEqual(CommandInfo.tag("npm test | tee log"), "node")
    }
}
