import XCTest
@testable import KabukCore

final class SkillTests: XCTestCase {
    var dir: URL!
    var home: URL { dir.appendingPathComponent("home") }
    var repo: URL { dir.appendingPathComponent("repo") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("app/src"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func skill(_ folder: URL, _ name: String, _ frontmatter: String? = nil) throws {
        let path = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let text = frontmatter ?? "---\nname: \(name)\ndescription: About \(name).\n---\n\n# \(name)\n"
        try text.write(to: path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFrontmatter() {
        let plain = SkillFrontmatter.parse("---\nname: review\ndescription: Review the diff.\n---\nbody")
        XCTAssertEqual(plain?.name, "review")
        XCTAssertEqual(plain?.description, "Review the diff.")
        XCTAssertEqual(plain?.userInvocable, true)

        let quoted = SkillFrontmatter.parse("---\r\nname: \"deploy\"\r\ndescription: 'It''s: quoted'\r\n---\r\n")
        XCTAssertEqual(quoted?.name, "deploy")
        XCTAssertEqual(quoted?.description, "It's: quoted")

        let folded = SkillFrontmatter.parse("---\nname: x\ndescription: >\n  First line,\n  second line.\nuser-invocable: false\n---\n")
        XCTAssertEqual(folded?.description, "First line, second line.")
        XCTAssertEqual(folded?.userInvocable, false)

        XCTAssertNil(SkillFrontmatter.parse("# No frontmatter"))
        XCTAssertNil(SkillFrontmatter.parse("---\nname: never closed\n"))
    }

    func testInsertion() {
        let claude = Skill(agent: .claude, name: "foo", description: "", invocation: "plug:foo", scope: .plugin("plug"), path: "")
        let codex = Skill(agent: .codex, name: "foo", description: "", invocation: "foo", scope: .user, path: "")
        XCTAssertEqual(claude.insertion, "/plug:foo ")
        XCTAssertEqual(codex.insertion, "$foo ")
    }

    func testNameMatchesRankBeforeDescriptionMatches() {
        let reverse = Skill(agent: .claude, name: "reverse-engineer-anything", description: String(repeating: "Long text. ", count: 40),
                            invocation: "reverse-engineer-anything", scope: .user, path: "")
        let memory = Skill(agent: .claude, name: "import-memory", description: "Import a memory export from another AI assistant.",
                           invocation: "anthropic-skills:import-memory", scope: .synced, path: "")
        XCTAssertNotNil(reverse.matchScore("rev"))
        XCTAssertNil(memory.matchScore("rev"), "scattered letters in a description don't count")
        XCTAssertLessThan(memory.matchScore("AI assistant")!, reverse.matchScore("rev")!, "the description still finds it, last")
        XCTAssertNil(memory.matchScore("zzz"))
    }

    func testClaudeSkills() throws {
        let claude = home.appendingPathComponent(".claude")
        try skill(claude.appendingPathComponent("skills"), "shared")
        try skill(claude.appendingPathComponent("skills"), "hidden", "---\nname: hidden\nuser-invocable: false\n---\n")
        try skill(claude.appendingPathComponent("skills"), "bare", "# No frontmatter")
        try skill(repo.appendingPathComponent(".claude/skills"), "shared")
        try skill(repo.appendingPathComponent(".claude/skills"), "repo-only")
        try skill(repo.appendingPathComponent("app/.claude/skills"), "app-only")
        try skill(dir.appendingPathComponent(".claude/skills"), "above-the-repo")
        try skill(claude.appendingPathComponent("skills/synced/abc"), "docs")

        let onPath = dir.appendingPathComponent("plugins/lsp")
        let offPath = dir.appendingPathComponent("plugins/off")
        try skill(onPath.appendingPathComponent("skills"), "check")
        try skill(offPath.appendingPathComponent("skills"), "nope")
        try write("""
        {"version":2,"plugins":{
          "lsp@market":[{"scope":"user","installPath":"\(onPath.path)"}],
          "off@market":[{"scope":"user","installPath":"\(offPath.path)"}]}}
        """, to: claude.appendingPathComponent("plugins/installed_plugins.json"))
        try write(#"{"enabledPlugins":{"lsp@market":true,"off@market":false}}"#, to: claude.appendingPathComponent("settings.json"))

        let found = SkillCatalog.scan(agent: .claude, cwd: repo.appendingPathComponent("app/src").path, home: home)
        XCTAssertEqual(found.map(\.invocation), ["bare", "shared", "app-only", "repo-only", "lsp:check", "anthropic-skills:docs"])
        XCTAssertEqual(found.first { $0.invocation == "shared" }?.scope, .user, "the user's skill wins over the project's")
        XCTAssertEqual(found.first { $0.invocation == "lsp:check" }?.scopeLabel, "lsp")
        XCTAssertEqual(found.first { $0.invocation == "anthropic-skills:docs" }?.scope, .synced)
    }

    func testCodexSkills() throws {
        try skill(home.appendingPathComponent(".agents/skills"), "agents-skill")
        try skill(home.appendingPathComponent(".codex/skills"), "codex-skill")
        try skill(home.appendingPathComponent(".codex/skills/.system"), "review-agent")
        try skill(repo.appendingPathComponent(".agents/skills"), "repo-skill")
        try skill(repo.appendingPathComponent(".claude/skills"), "claude-only")

        let found = SkillCatalog.scan(agent: .codex, cwd: repo.path, home: home)
        XCTAssertEqual(found.map(\.invocation), ["agents-skill", "codex-skill", "repo-skill", "review-agent"])
        XCTAssertEqual(found.last?.scope, .builtIn)
    }

    func testOutsideARepositoryOnlyTheFolderCounts() throws {
        let loose = dir.appendingPathComponent("loose/inner")
        try skill(loose.appendingPathComponent(".claude/skills"), "here")
        try skill(dir.appendingPathComponent("loose/.claude/skills"), "parent")

        let found = SkillCatalog.scan(agent: .claude, cwd: loose.path, home: home)
        XCTAssertEqual(found.map(\.invocation), ["here"])
    }
}
