import XCTest
@testable import KabukCore

final class AgentRegistryTests: XCTestCase {
    override func tearDown() {
        AgentRegistry.setUserAgents([])
    }

    func testProgramsMapToAgents() {
        XCTAssertEqual(CommandInfo.agent("agy"), .antigravity)
        XCTAssertEqual(CommandInfo.tag("agy --resume"), "antigravity")
        XCTAssertEqual(CommandInfo.agent("env OPENAI_KEY=1 opencode ."), .opencode)
        XCTAssertEqual(CommandInfo.agent("cursor-agent --model gpt-5")?.rawValue, "cursor")
        XCTAssertEqual(CommandInfo.agent("gemini -i 'fix it'"), .gemini)
        XCTAssertEqual(CommandInfo.agent("copilot"), .copilot)
        XCTAssertNil(CommandInfo.agent("gemini-tool"))
        XCTAssertNil(AgentKind(rawValue: "shell"))
        XCTAssertNil(AgentKind(rawValue: "kabuk"))
    }

    func testOnlyCodexStartsWorkingFromItsArgument() {
        XCTAssertTrue(CommandInfo.startsWithPrompt("codex \"add tests\"", agent: .codex))
        XCTAssertFalse(CommandInfo.startsWithPrompt("codex login", agent: .codex))
        XCTAssertFalse(CommandInfo.startsWithPrompt("claude \"add tests\"", agent: .claude))
        XCTAssertFalse(CommandInfo.startsWithPrompt("gemini -i \"add tests\"", agent: .gemini))
    }

    func testUserAgents() {
        let file = """
        {"agents": [
          {"name": "kiro", "program": "kiro-cli", "color": "#ff9900", "prompt": "argument"},
          {"name": "Crush", "prompt": "-p"},
          {"name": "fake-claude", "program": "claude"},
          {"name": "codex", "program": "my-codex"},
          {"name": "bad-color", "program": "bc", "color": "orange"}
        ]}
        """
        AgentRegistry.setUserAgents(AgentRegistry.userAgents(from: Data(file.utf8)))
        let kiro = CommandInfo.agent("kiro-cli chat")
        XCTAssertEqual(kiro?.rawValue, "kiro")
        XCTAssertEqual(kiro?.profile.color, "#ff9900")
        XCTAssertEqual(kiro?.profile.prompt, .argument)
        XCTAssertEqual(CommandInfo.agent("crush")?.profile.prompt, .flag("-p"))
        XCTAssertEqual(CommandInfo.agent("crush")?.displayName, "Crush")
        // A built-in program or name can't be taken over.
        XCTAssertEqual(CommandInfo.agent("claude"), .claude)
        XCTAssertNil(CommandInfo.agent("my-codex"))
        XCTAssertEqual(CommandInfo.agent("bc")?.profile.color, "#94a3b8")
        XCTAssertTrue(AgentRegistry.userAgents(from: Data("not json".utf8)).isEmpty)
    }

    /// limits.json was written when AgentKind was an enum: a flat array of keys and values.
    func testReadsFilesWrittenByTheEnum() throws {
        let old = #"["claude",{"updatedAt":0},"codex",{"updatedAt":0}]"#
        let limits = try JSONDecoder().decode([AgentKind: PlanLimits].self, from: Data(old.utf8))
        XCTAssertEqual(Set(limits.keys), [.claude, .codex])
        let encoded = try JSONEncoder().encode([AgentKind.claude: limits[.claude]!])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).hasPrefix(#"["claude","#))
    }

    func testSkillsOnlyForAgentsWithAPrefix() {
        let skill = Skill(agent: .codex, name: "x", description: "", invocation: "x", scope: .user, path: "")
        XCTAssertEqual(skill.insertion, "$x ")
        XCTAssertTrue(SkillCatalog.scan(agent: .gemini, cwd: NSTemporaryDirectory()).isEmpty)
    }
}
