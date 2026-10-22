import XCTest
@testable import KabukCore

final class AgentHooksTests: XCTestCase {
    func translate(_ agent: AgentKind, _ hook: String, _ payload: [String: Any]) -> AgentHooks.Translation {
        AgentHooks.translate(agent: agent, hook: hook, payload: payload, pane: "p")
    }

    func testGemini() {
        let start = translate(.gemini, "BeforeAgent", ["prompt": "add tests\nand docs", "session_id": "s1"])
        XCTAssertEqual(start.event?.source, "gemini")
        XCTAssertEqual(start.event?.event, AgentEvent.turnStart)
        XCTAssertEqual(start.event?.prompt, "add tests")
        XCTAssertEqual(start.event?.session, "s1")
        XCTAssertEqual(start.output, "{}", "Gemini reads the output as JSON")
        XCTAssertEqual(translate(.gemini, "AfterTool", ["tool_name": "run_shell_command"]).event?.tool, "run_shell_command")
        XCTAssertEqual(translate(.gemini, "Notification", ["message": "Allow?"]).event?.event, AgentEvent.needsYou)
        let end = translate(.gemini, "AfterAgent", ["prompt": "add tests", "prompt_response": "Added three tests."])
        XCTAssertEqual(end.event?.event, AgentEvent.turnEnd)
        XCTAssertEqual(end.event?.message, "Added three tests.")
    }

    func testCopilot() {
        XCTAssertEqual(translate(.copilot, "userPromptSubmitted", ["prompt": "go"]).event?.event, AgentEvent.turnStart)
        XCTAssertEqual(translate(.copilot, "postToolUse", ["toolName": "bash"]).event?.tool, "bash")
        XCTAssertNil(translate(.copilot, "notification", ["notification_type": "agent_idle"]).event)
        XCTAssertEqual(translate(.copilot, "notification", ["notification_type": "permission_prompt", "message": "Run?"]).event?.event,
                       AgentEvent.needsYou)
        let ask = translate(.copilot, "permissionRequest", ["toolName": "bash", "toolArgs": #"{"command":"rm -rf build"}"#])
        XCTAssertEqual(ask.event?.event, AgentEvent.permission)
        XCTAssertNotNil(ask.event?.request)
        XCTAssertEqual(ask.event?.detail, "rm -rf build")
        XCTAssertNil(ask.output, "the answer comes after Kabuk replies")
        XCTAssertEqual(translate(.copilot, "agentStop", [:]).event?.event, AgentEvent.turnEnd)

        XCTAssertEqual(AgentHooks.permissionOutput(agent: .copilot, .allow), #"{"behavior":"allow"}"#)
        XCTAssertEqual(AgentHooks.permissionOutput(agent: .copilot, .deny), #"{"behavior":"deny","message":"Denied from Kabuk."}"#)
        XCTAssertNil(AgentHooks.permissionOutput(agent: .copilot, .ask))
    }

    func testAntigravity() {
        XCTAssertEqual(translate(.antigravity, "PreInvocation", [:]).event?.event, AgentEvent.turnStart)
        XCTAssertEqual(translate(.antigravity, "PostToolUse", ["toolCall": ["name": "run_command", "args": [:]]]).event?.tool, "run_command")
        let between = translate(.antigravity, "Stop", ["fullyIdle": false])
        XCTAssertNil(between.event)
        XCTAssertEqual(between.output, #"{"decision":"stop"}"#)
        XCTAssertEqual(translate(.antigravity, "Stop", ["fullyIdle": true]).event?.event, AgentEvent.turnEnd)
        XCTAssertEqual(AgentHooks.defaultOutput(agent: "antigravity", hook: "PreInvocation"), "{}")
    }

    func testOpenCode() {
        XCTAssertEqual(translate(.opencode, AgentEvent.turnStart, ["session": "ses_1"]).event?.session, "ses_1")
        XCTAssertEqual(translate(.opencode, AgentEvent.tool, ["tool": "edit"]).event?.tool, "edit")
        let ask = translate(.opencode, AgentEvent.permission, ["tool": "bash", "detail": "git push --force"])
        XCTAssertEqual(ask.event?.detail, "git push --force")
        XCTAssertNotNil(ask.event?.request)
        // Kabuk's own guesses can't come from a hook.
        XCTAssertNil(translate(.opencode, AgentEvent.quiet, [:]).event)
        XCTAssertNil(translate(.opencode, "made-up", [:]).event)
        XCTAssertEqual(AgentHooks.permissionOutput(agent: .opencode, .always), "always")
        XCTAssertEqual(AgentHooks.permissionOutput(agent: .opencode, .deny), "reject")
    }

    func testUnknownHooksSayNothing() {
        XCTAssertNil(translate(.gemini, "SessionStart", [:]).event)
        XCTAssertNil(translate(.claude, "Stop", [:]).event)
    }
}
