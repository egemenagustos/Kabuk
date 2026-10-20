import Foundation

/// Adds (and removes) Kabuk's entries in the Claude Code and Codex configs.
///
/// Every entry runs `$KABUK_HOOK`, which only Kabuk panes set, so agents started in other
/// terminals skip it and exit 0.
public enum IntegrationInstaller {
    public static var claudeSettings = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    public static var codexConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")

    public static let claudeEvents = ["UserPromptSubmit", "PostToolUse", "Notification", "Stop", "PermissionRequest"]
    private static let marker = "KABUK_HOOK"
    private static let codexBegin = "# kabuk:begin"
    private static let codexEnd = "# kabuk:end"

    public static func claudeCommand(_ event: String) -> String {
        #"[ -n "$KABUK_HOOK" ] && "$KABUK_HOOK" claude \#(event) || true"#
    }

    public enum InstallError: LocalizedError {
        case unreadable(String)
        case codexNotifyTaken

        public var errorDescription: String? {
            switch self {
            case .unreadable(let file): return "\(file) could not be read (not valid JSON)."
            case .codexNotifyTaken: return "~/.codex/config.toml already has a `notify` setting; Kabuk left it unchanged."
            }
        }
    }

    // MARK: Claude Code

    public static func installClaude() throws {
        var settings = try readClaudeSettings()
        backup(claudeSettings)
        var hooks = removingKabuk(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // A permission request waits for the user's answer; everything else returns at once.
            let timeout = event == "PermissionRequest" ? 600 : 5
            groups.append(["hooks": [["type": "command", "command": claudeCommand(event), "timeout": timeout]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeClaudeSettings(settings)
    }

    public static func uninstallClaude() throws {
        var settings = try readClaudeSettings()
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let cleaned = removingKabuk(from: hooks)
        settings["hooks"] = cleaned.isEmpty ? nil : cleaned
        try writeClaudeSettings(settings)
    }

    public static func claudeInstalled() -> Bool {
        guard let settings = try? readClaudeSettings(), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hasKabuk(hooks)
    }

    private static func hasKabuk(_ hooks: [String: Any]) -> Bool {
        hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains(where: isKabukGroup)
        }
    }

    private static func isKabukGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    public static func removingKabuk(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = groups.filter { !isKabukGroup($0) }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func readClaudeSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettings), !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadable("~/.claude/settings.json")
        }
        return json
    }

    private static func writeClaudeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: claudeSettings, options: .atomic)
    }

    // MARK: Codex

    public static var codexBlock: String {
        """
        \(codexBegin)
        notify = ["sh", "-c", '[ -n "$KABUK_HOOK" ] && exec "$KABUK_HOOK" codex "$1" || true', "kabuk"]
        \(codexEnd)

        """
    }

    public static func installCodex() throws {
        let existing = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        let stripped = removingCodexBlock(existing)
        // TOML keys before the first [table] are top level; that's where `notify` must live.
        let topLevel = stripped.components(separatedBy: "\n").prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
        if topLevel.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) {
            throw InstallError.codexNotifyTaken
        }
        backup(codexConfig)
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (codexBlock + stripped).write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    public static func uninstallCodex() throws {
        guard let existing = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
        try removingCodexBlock(existing).write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    public static func codexInstalled() -> Bool {
        ((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "").contains(codexBegin)
    }

    public static func removingCodexBlock(_ text: String) -> String {
        guard let start = text.range(of: codexBegin), let end = text.range(of: codexEnd, range: start.upperBound..<text.endIndex) else {
            return text
        }
        var upper = end.upperBound
        while upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        var result = text
        result.removeSubrange(start.lowerBound..<upper)
        return result
    }

    // MARK: Helpers

    /// Keeps the first original copy; later installs never overwrite it.
    private static func backup(_ url: URL) {
        let copy = url.appendingPathExtension("kabuk-backup")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path), !fm.fileExists(atPath: copy.path) else { return }
        try? fm.copyItem(at: url, to: copy)
    }
}
