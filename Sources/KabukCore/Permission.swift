import Foundation

/// A Claude permission request that Kabuk can answer without switching to the pane.
public struct PermissionPrompt: Equatable, Sendable {
    public var id: String
    public var tool: String
    public var detail: String
    /// Claude offered rules ("always allow this") that an Always answer can apply.
    public var canAlwaysAllow: Bool
    /// The subagent asking, if it isn't the main agent.
    public var agent: String?

    public init(id: String, tool: String, detail: String, canAlwaysAllow: Bool, agent: String? = nil) {
        self.id = id
        self.tool = tool
        self.detail = detail
        self.canAlwaysAllow = canAlwaysAllow
        self.agent = agent
    }
}

/// How the user answered a permission request, as sent back to `kabuk-hook`.
public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny, always
    /// Leave it to Claude's own prompt in the terminal.
    case ask
}

public enum PermissionSummary {
    /// One line describing what the tool wants to do: the command for Bash, the file for
    /// edits, the URL for fetches, otherwise compact JSON.
    public static func detail(tool: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "notebook_path", "path", "url", "pattern", "query", "prompt"]
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                return oneLine(value)
            }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return tool
        }
        return oneLine(String(decoding: data, as: UTF8.self))
    }

    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    /// The hook's stdout for a decision, or nil to stay silent and let Claude ask.
    public static func hookOutput(_ decision: PermissionDecision, suggestions: Any?) -> String? {
        var body: [String: Any]
        switch decision {
        case .ask:
            return nil
        case .allow:
            body = ["behavior": "allow"]
        case .always:
            body = ["behavior": "allow"]
            if let suggestions = suggestions as? [Any], !suggestions.isEmpty {
                body["updatedPermissions"] = suggestions
            }
        case .deny:
            body = ["behavior": "deny", "message": "Denied from Kabuk."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
