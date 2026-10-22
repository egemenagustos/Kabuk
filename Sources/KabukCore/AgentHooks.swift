import Foundation

/// Turns the hooks of agents other than Claude and Codex into Kabuk's `AgentEvent`s, and
/// writes what each hook must print back to its agent.
public enum AgentHooks {
    /// Each agent's own hook names that Kabuk listens to.
    public static let events: [AgentKind: [String]] = [
        .gemini: ["BeforeAgent", "AfterTool", "Notification", "AfterAgent"],
        .copilot: ["userPromptSubmitted", "postToolUse", "notification", "permissionRequest", "agentStop"],
        .antigravity: ["PreInvocation", "PostToolUse", "Stop"],
        // Kabuk's OpenCode plugin sends Kabuk's own names.
        .opencode: [AgentEvent.turnStart, AgentEvent.tool, AgentEvent.permission, AgentEvent.needsYou, AgentEvent.turnEnd],
    ]

    public struct Translation {
        /// What goes to Kabuk; nil when the hook says nothing Kabuk shows.
        public var event: HookEvent?
        /// Printed for the agent before the event is sent.
        public var output: String?
    }

    /// What the hook prints when Kabuk has nothing to add, also outside Kabuk. Gemini and
    /// Antigravity read a hook's output as JSON.
    public static func defaultOutput(agent: String, hook: String) -> String? {
        switch agent {
        case "gemini": return "{}"
        case "antigravity": return hook == "Stop" ? #"{"decision":"stop"}"# : "{}"
        default: return nil
        }
    }

    public static func translate(agent: AgentKind, hook: String, payload: [String: Any], pane: String) -> Translation {
        let output = defaultOutput(agent: agent.rawValue, hook: hook)
        func event(_ name: String, message: String? = nil, prompt: String? = nil, tool: String? = nil) -> Translation {
            Translation(event: HookEvent(pane: pane, source: agent.rawValue, event: name, message: firstLine(message),
                                         prompt: firstLine(prompt), tool: tool, session: payload.string("session_id", "sessionId")),
                        output: output)
        }
        let none = Translation(event: nil, output: output)

        switch (agent, hook) {
        case (.gemini, "BeforeAgent"), (.copilot, "userPromptSubmitted"), (.antigravity, "PreInvocation"):
            return event(AgentEvent.turnStart, prompt: payload.string("prompt"))
        case (.gemini, "AfterTool"), (.copilot, "postToolUse"):
            return event(AgentEvent.tool, tool: payload.string("tool_name", "toolName"))
        case (.antigravity, "PostToolUse"):
            return event(AgentEvent.tool, tool: (payload["toolCall"] as? [String: Any])?.string("name"))
        case (.gemini, "Notification"):
            return event(AgentEvent.needsYou, message: payload.string("message"))
        case (.copilot, "notification"):
            // Only the ones that wait for the user; agentStop already says when a turn ends.
            let type = payload.string("notification_type", "notificationType")
            guard type == "permission_prompt" || type == "elicitation_dialog" else { return none }
            return event(AgentEvent.needsYou, message: payload.string("message"))
        case (.copilot, "permissionRequest"):
            let tool = payload.string("toolName", "tool_name") ?? "Tool"
            let detail = PermissionSummary.detail(tool: tool, input: arguments(payload["toolArgs"] ?? payload["tool_input"]))
            return Translation(event: HookEvent(pane: pane, source: agent.rawValue, event: AgentEvent.permission,
                                                request: UUID().uuidString, tool: tool, detail: detail,
                                                session: payload.string("sessionId", "session_id")),
                               output: output)
        case (.gemini, "AfterAgent"):
            return event(AgentEvent.turnEnd, message: payload.string("prompt_response"), prompt: payload.string("prompt"))
        case (.copilot, "agentStop"):
            return event(AgentEvent.turnEnd)
        case (.antigravity, "Stop"):
            // Stop also comes between steps; fullyIdle says the agent is done.
            if payload["fullyIdle"] as? Bool == false { return none }
            return event(AgentEvent.turnEnd)
        case (.opencode, AgentEvent.permission):
            let tool = payload.string("tool") ?? "Tool"
            return Translation(event: HookEvent(pane: pane, source: agent.rawValue, event: AgentEvent.permission,
                                                request: UUID().uuidString, tool: tool,
                                                detail: payload.string("detail").map { PermissionSummary.oneLine($0) } ?? "",
                                                session: payload.string("session")),
                               output: nil)
        case (.opencode, let name) where AgentEvent.all.contains(name) && !AgentEvent.guesses.contains(name):
            return Translation(event: HookEvent(pane: pane, source: agent.rawValue, event: name,
                                                message: firstLine(payload.string("message")),
                                                prompt: firstLine(payload.string("prompt")), tool: payload.string("tool"),
                                                session: payload.string("session")),
                               output: nil)
        default:
            return none
        }
    }

    /// What the hook prints for the user's answer to a permission request; nil leaves it to the
    /// agent's own prompt.
    public static func permissionOutput(agent: AgentKind, _ decision: PermissionDecision) -> String? {
        switch (agent, decision) {
        case (_, .ask): return nil
        case (.copilot, .deny): return #"{"behavior":"deny","message":"Denied from Kabuk."}"#
        case (.copilot, _): return #"{"behavior":"allow"}"#
        // Kabuk's OpenCode plugin passes these words on as OpenCode's own replies.
        case (.opencode, .allow): return "once"
        case (.opencode, .always): return "always"
        case (.opencode, .deny): return "reject"
        default: return nil
        }
    }

    /// A tool's arguments, given as an object or as a JSON string.
    static func arguments(_ value: Any?) -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String, let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return object
        }
        return [:]
    }

    static func firstLine(_ text: String?, limit: Int = 200) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// The first of these keys that holds a non-empty string.
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
