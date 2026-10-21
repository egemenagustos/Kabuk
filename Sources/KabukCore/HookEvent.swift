import Foundation

/// One line of JSON sent to the Kabuk socket by the zsh integration or `kabuk-hook`.
public struct HookEvent: Codable, Equatable, Sendable {
    public var pane: String
    /// `shell`, `claude` or `codex`.
    public var source: String
    /// shell: `start`, `end`, `prompt`
    /// claude: hook event name (`UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`), or `StatusLine`
    /// codex: notify type (`agent-turn-complete`, `approval-requested`)
    public var event: String
    public var cmd: String?
    public var code: Int32?
    public var cwd: String?
    public var message: String?
    public var prompt: String?
    public var kind: String?
    public var tokens: TokenUsage?
    /// Set when the sender waits on the connection for a reply (permission requests).
    public var request: String?
    public var tool: String?
    public var detail: String?
    /// Claude offered "always allow" rules for this request.
    public var canAlwaysAllow: Bool?
    /// The agent's own session id (Claude) or thread id (Codex), for the cost ledger.
    public var session: String?
    /// Set when a Claude subagent sent the event: its id and type ("general-purpose", "Explore", …).
    public var agent: String?
    public var agentType: String?
    /// The subagent's transcript, on SubagentStart and SubagentStop.
    public var transcript: String?
    /// The plan's 5-hour and weekly usage: Claude's status line, or a finished Codex turn.
    public var limits: PlanLimits?

    public init(pane: String, source: String, event: String, cmd: String? = nil, code: Int32? = nil,
                cwd: String? = nil, message: String? = nil, prompt: String? = nil, kind: String? = nil,
                tokens: TokenUsage? = nil, request: String? = nil, tool: String? = nil, detail: String? = nil,
                canAlwaysAllow: Bool? = nil, session: String? = nil, agent: String? = nil, agentType: String? = nil,
                transcript: String? = nil, limits: PlanLimits? = nil) {
        self.pane = pane
        self.source = source
        self.event = event
        self.cmd = cmd
        self.code = code
        self.cwd = cwd
        self.message = message
        self.prompt = prompt
        self.kind = kind
        self.tokens = tokens
        self.request = request
        self.tool = tool
        self.detail = detail
        self.canAlwaysAllow = canAlwaysAllow
        self.session = session
        self.agent = agent
        self.agentType = agentType
        self.transcript = transcript
        self.limits = limits
    }

    /// The prompt as the user typed it. Claude also submits its own notices, such as
    /// "<task-notification>" when a background subagent finishes; those aren't the user's words.
    public var userPrompt: String? {
        guard let prompt, !prompt.isEmpty, !prompt.hasPrefix("<") else { return nil }
        return prompt
    }

    public static func parse(_ line: Data) -> HookEvent? {
        try? JSONDecoder().decode(HookEvent.self, from: line)
    }

    /// Splits a socket payload into events, skipping malformed lines.
    public static func parseAll(_ data: Data) -> [HookEvent] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { parse(Data($0)) }
    }

    public func encodedLine() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
