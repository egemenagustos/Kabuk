import XCTest
@testable import KabukCore

final class IntegrationInstallerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        IntegrationInstaller.claudeSettings = dir.appendingPathComponent("settings.json")
        IntegrationInstaller.codexConfig = dir.appendingPathComponent("config.toml")
        IntegrationInstaller.claudeSkill = dir.appendingPathComponent("skills/kabuk-delegate/SKILL.md")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testClaudeInstallKeepsUserSettingsAndIsIdempotent() throws {
        let original = """
        {"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
        """
        try original.write(to: IntegrationInstaller.claudeSettings, atomically: true, encoding: .utf8)

        try IntegrationInstaller.installClaude()
        try IntegrationInstaller.installClaude()
        XCTAssertTrue(IntegrationInstaller.claudeInstalled())

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        XCTAssertEqual(json["theme"] as? String, "dark")
        let hooks = json["hooks"] as! [String: Any]
        let stop = hooks["Stop"] as! [[String: Any]]
        XCTAssertEqual(stop.count, 2, "user hook kept, ours added once")
        XCTAssertEqual(Set(hooks.keys), Set(IntegrationInstaller.claudeEvents))

        let backup = IntegrationInstaller.claudeSettings.appendingPathExtension("kabuk-backup")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)

        try IntegrationInstaller.uninstallClaude()
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        let afterHooks = after["hooks"] as! [String: Any]
        XCTAssertEqual(Array(afterHooks.keys), ["Stop"])
        XCTAssertFalse(IntegrationInstaller.claudeInstalled())
    }

    func testPreToolUseOnlyMatchesSubagentLaunches() throws {
        try IntegrationInstaller.installClaude()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["PreToolUse"] as! [[String: Any]]).first?["matcher"] as? String, "Agent|Task")
        XCTAssertNil((hooks["Stop"] as! [[String: Any]]).first?["matcher"])
    }

    func testOlderInstallIsOutdated() throws {
        let old = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"[ -n \\"$KABUK_HOOK\\" ] && \\"$KABUK_HOOK\\" claude Stop || true"}]}]}}
        """
        try old.write(to: IntegrationInstaller.claudeSettings, atomically: true, encoding: .utf8)
        XCTAssertTrue(IntegrationInstaller.claudeInstalled())
        XCTAssertTrue(IntegrationInstaller.claudeOutdated())
        try IntegrationInstaller.installClaude()
        XCTAssertFalse(IntegrationInstaller.claudeOutdated())
    }

    func testDelegateSkillComesAndGoesWithTheHooks() throws {
        try IntegrationInstaller.installClaude()
        let skill = try String(contentsOf: IntegrationInstaller.claudeSkill, encoding: .utf8)
        XCTAssertTrue(skill.hasPrefix("---\nname: kabuk-delegate\n"))
        XCTAssertTrue(skill.contains("\"$KABUK_HOOK\" spawn codex"))
        XCTAssertFalse(IntegrationInstaller.claudeOutdated())

        try "edited".write(to: IntegrationInstaller.claudeSkill, atomically: true, encoding: .utf8)
        XCTAssertTrue(IntegrationInstaller.claudeOutdated(), "a stale or edited skill is reinstalled")
        try IntegrationInstaller.installClaude()

        try IntegrationInstaller.uninstallClaude()
        XCTAssertFalse(FileManager.default.fileExists(atPath: IntegrationInstaller.claudeSkill.path))
    }

    func testStatusLineWithoutAUserCommand() throws {
        try IntegrationInstaller.installClaude()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        let statusLine = json["statusLine"] as! [String: Any]
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["command"] as? String, IntegrationInstaller.statusLineCommand(wrapping: nil))

        try IntegrationInstaller.uninstallClaude()
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        XCTAssertNil(json["statusLine"])
    }

    func testStatusLineWrapsTheUsersOwnAndGivesItBack() throws {
        let user = #"~/bin/status.sh && echo "$(date)""#
        let settings: [String: Any] = ["statusLine": ["type": "command", "command": user, "padding": 2]]
        try JSONSerialization.data(withJSONObject: settings).write(to: IntegrationInstaller.claudeSettings)

        try IntegrationInstaller.installClaude()
        try IntegrationInstaller.installClaude()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        var statusLine = json["statusLine"] as! [String: Any]
        XCTAssertEqual(statusLine["command"] as? String, IntegrationInstaller.statusLineCommand(wrapping: user),
                       "wrapped once, however many installs")
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertFalse(IntegrationInstaller.claudeOutdated())

        try IntegrationInstaller.uninstallClaude()
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        statusLine = json["statusLine"] as! [String: Any]
        XCTAssertEqual(statusLine["command"] as? String, user)
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
    }

    func testStatusLineReplacedLaterIsOutdatedAndWrappedAgain() throws {
        try IntegrationInstaller.installClaude()
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        json["statusLine"] = ["type": "command", "command": "echo hi"]
        try JSONSerialization.data(withJSONObject: json).write(to: IntegrationInstaller.claudeSettings)
        XCTAssertTrue(IntegrationInstaller.claudeOutdated())

        try IntegrationInstaller.installClaude()
        json = try JSONSerialization.jsonObject(with: Data(contentsOf: IntegrationInstaller.claudeSettings)) as! [String: Any]
        XCTAssertEqual((json["statusLine"] as! [String: Any])["command"] as? String,
                       IntegrationInstaller.statusLineCommand(wrapping: "echo hi"))
    }

    /// Runs the installed command the way Claude does: through sh, JSON on stdin.
    func testStatusLineCommandRunsTheUsersCommandOnTheSameInput() throws {
        func run(_ command: String, hook: String?) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var environment = ProcessInfo.processInfo.environment
            environment["KABUK_HOOK"] = hook
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"model":"opus"}"#.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let hook = dir.appendingPathComponent("hook.sh")
        let seen = dir.appendingPathComponent("seen")
        try "#!/bin/sh\ncat > '\(seen.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let command = IntegrationInstaller.statusLineCommand(wrapping: "printf 'A:'; cat")
        XCTAssertEqual(try run(command, hook: hook.path), #"A:{"model":"opus"}"#)
        XCTAssertEqual(try String(contentsOf: seen, encoding: .utf8), #"{"model":"opus"}"#)

        try FileManager.default.removeItem(at: seen)
        XCTAssertEqual(try run(command, hook: nil), #"A:{"model":"opus"}"#, "outside Kabuk only the user's command runs")
        XCTAssertFalse(FileManager.default.fileExists(atPath: seen.path))
    }

    func testClaudeRefusesBrokenJSON() throws {
        try "{ not json".write(to: IntegrationInstaller.claudeSettings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IntegrationInstaller.installClaude())
        XCTAssertEqual(try String(contentsOf: IntegrationInstaller.claudeSettings, encoding: .utf8), "{ not json")
    }

    func testCodexInstallPutsNotifyAtTopLevel() throws {
        let original = """
        model = "gpt"

        [projects."/x"]
        trust_level = "trusted"

        """
        try original.write(to: IntegrationInstaller.codexConfig, atomically: true, encoding: .utf8)
        try IntegrationInstaller.installCodex()
        try IntegrationInstaller.installCodex()
        let text = try String(contentsOf: IntegrationInstaller.codexConfig, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# kabuk:begin\nnotify = "))
        XCTAssertEqual(text.components(separatedBy: "# kabuk:begin").count, 2)
        XCTAssertTrue(text.hasSuffix(original))

        try IntegrationInstaller.uninstallCodex()
        XCTAssertEqual(try String(contentsOf: IntegrationInstaller.codexConfig, encoding: .utf8), original)
    }

    func testCodexLeavesExistingNotifyAlone() throws {
        let original = "notify = [\"my-script\"]\nmodel = \"x\"\n"
        try original.write(to: IntegrationInstaller.codexConfig, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IntegrationInstaller.installCodex())
        XCTAssertEqual(try String(contentsOf: IntegrationInstaller.codexConfig, encoding: .utf8), original)
    }
}

final class AgentIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        IntegrationInstaller.geminiSettings = dir.appendingPathComponent("gemini/settings.json")
        IntegrationInstaller.copilotHooks = dir.appendingPathComponent("copilot/hooks/kabuk.json")
        IntegrationInstaller.antigravityHooks = dir.appendingPathComponent("gemini/config/hooks.json")
        IntegrationInstaller.antigravityScript = dir.appendingPathComponent("gemini/config/kabuk-hook.sh")
        IntegrationInstaller.opencodePlugin = dir.appendingPathComponent("opencode/plugins/kabuk.js")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    func testGeminiKeepsUserSettings() throws {
        try FileManager.default.createDirectory(at: IntegrationInstaller.geminiSettings.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"theme":"Dracula","hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
            .write(to: IntegrationInstaller.geminiSettings, atomically: true, encoding: .utf8)
        try IntegrationInstaller.install(.gemini)
        try IntegrationInstaller.install(.gemini)
        XCTAssertTrue(IntegrationInstaller.installed(.gemini))
        XCTAssertFalse(IntegrationInstaller.outdated(.gemini))

        let settings = try json(IntegrationInstaller.geminiSettings)
        XCTAssertEqual(settings["theme"] as? String, "Dracula")
        let hooks = settings["hooks"] as! [String: Any]
        XCTAssertEqual((hooks["AfterAgent"] as! [[String: Any]]).count, 2, "user hook kept, ours added once")
        let ours = ((hooks["BeforeAgent"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(ours["timeout"] as? Int, 5000)
        XCTAssertTrue((ours["command"] as! String).contains("gemini BeforeAgent"))

        try IntegrationInstaller.uninstall(.gemini)
        XCTAssertFalse(IntegrationInstaller.installed(.gemini))
        XCTAssertEqual(Array((try json(IntegrationInstaller.geminiSettings)["hooks"] as! [String: Any]).keys), ["AfterAgent"])
    }

    func testCopilotHasAFileOfItsOwn() throws {
        try IntegrationInstaller.install(.copilot)
        let file = try json(IntegrationInstaller.copilotHooks)
        XCTAssertEqual(file["version"] as? Int, 1)
        let hooks = file["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(AgentHooks.events[.copilot]!))
        XCTAssertEqual(((hooks["permissionRequest"] as! [[String: Any]])[0])["timeoutSec"] as? Int, 600)
        XCTAssertTrue(IntegrationInstaller.installed(.copilot))
        XCTAssertFalse(IntegrationInstaller.outdated(.copilot))
        try IntegrationInstaller.uninstall(.copilot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: IntegrationInstaller.copilotHooks.path))
    }

    func testUninstallLeavesTheUsersOwnFile() throws {
        try FileManager.default.createDirectory(at: IntegrationInstaller.opencodePlugin.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "export default {}".write(to: IntegrationInstaller.opencodePlugin, atomically: true, encoding: .utf8)
        XCTAssertFalse(IntegrationInstaller.installed(.opencode))
        try IntegrationInstaller.uninstall(.opencode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: IntegrationInstaller.opencodePlugin.path))
    }

    func testOpenCodePlugin() throws {
        try IntegrationInstaller.install(.opencode)
        XCTAssertTrue(IntegrationInstaller.installed(.opencode))
        XCTAssertFalse(IntegrationInstaller.outdated(.opencode))
        let text = try String(contentsOf: IntegrationInstaller.opencodePlugin, encoding: .utf8)
        XCTAssertTrue(text.contains("export default"))
        for event in AgentHooks.events[.opencode]! where event != AgentEvent.needsYou {
            XCTAssertTrue(text.contains("\"\(event)\""), "plugin sends \(event)")
        }
        try IntegrationInstaller.uninstall(.opencode)
        XCTAssertFalse(IntegrationInstaller.installed(.opencode))
    }

    func testAntigravityKeepsOtherHookSets() throws {
        try FileManager.default.createDirectory(at: IntegrationInstaller.antigravityHooks.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try #"{"logger":{"Stop":[{"type":"command","command":"log"}]}}"#
            .write(to: IntegrationInstaller.antigravityHooks, atomically: true, encoding: .utf8)
        try IntegrationInstaller.install(.antigravity)
        XCTAssertTrue(IntegrationInstaller.installed(.antigravity))
        XCTAssertFalse(IntegrationInstaller.outdated(.antigravity))
        let hooks = try json(IntegrationInstaller.antigravityHooks)
        XCTAssertEqual(Set(hooks.keys), ["logger", "kabuk"])
        let ours = hooks["kabuk"] as! [String: Any]
        XCTAssertNotNil(((ours["PostToolUse"] as! [[String: Any]])[0])["matcher"])
        XCTAssertTrue((((ours["Stop"] as! [[String: Any]])[0])["command"] as! String).hasSuffix("kabuk-hook.sh Stop"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: IntegrationInstaller.antigravityScript.path))

        try IntegrationInstaller.uninstall(.antigravity)
        XCTAssertEqual(Array(try json(IntegrationInstaller.antigravityHooks).keys), ["logger"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: IntegrationInstaller.antigravityScript.path))
    }

    /// Outside Kabuk the hooks must still print what Gemini and Antigravity read.
    func testHooksAnswerOutsideKabuk() throws {
        let gemini = Shell.run("/bin/sh", ["-c", IntegrationInstaller.geminiCommand("AfterAgent")], unsetting: "KABUK_HOOK")
        XCTAssertEqual(gemini, "{}")
        try IntegrationInstaller.install(.antigravity)
        let stop = Shell.run("/bin/sh", [IntegrationInstaller.antigravityScript.path, "Stop"], unsetting: "KABUK_HOOK")
        XCTAssertEqual(stop, #"{"decision":"stop"}"#)
    }
}

private enum Shell {
    static func run(_ executable: String, _ args: [String], unsetting key: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env[key] = nil
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
