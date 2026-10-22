import Foundation

/// A coding agent Kabuk knows by name: one of the built-in ones, or one the user added in
/// agents.json. Encoded as its name, so files written when this was an enum still read.
public struct AgentKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    /// Only agents in the registry; "shell", "kabuk" and unknown programs are not agents.
    public init?(rawValue: String) {
        guard AgentRegistry.profile(named: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(_ name: String) {
        rawValue = name
    }

    public static let claude = AgentKind("claude")
    public static let codex = AgentKind("codex")
    public static let opencode = AgentKind("opencode")
    public static let gemini = AgentKind("gemini")
    public static let antigravity = AgentKind("antigravity")
    public static let copilot = AgentKind("copilot")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var profile: AgentProfile {
        AgentRegistry.profile(named: rawValue) ?? AgentProfile(name: rawValue, displayName: rawValue.capitalized, programs: [])
    }

    public var displayName: String { profile.displayName }
}

/// Everything that differs from one agent to the next.
public struct AgentProfile: Equatable, Sendable {
    /// How the agent starts with a task already given.
    public enum PromptStyle: Equatable, Sendable {
        /// `agent "task"`
        case argument
        /// `agent -i "task"`
        case flag(String)
        /// No way to pass one; Kabuk types it once the agent is up.
        case typed
    }

    public var name: String
    public var displayName: String
    /// Command names that start it; the first is the one Kabuk runs.
    public var programs: [String]
    public var color: String
    /// SF Symbol shown beside its numbers.
    public var glyph: String
    public var prompt: PromptStyle
    /// Its hooks say when a turn starts. Without that, pressing return in its pane starts one.
    public var reportsTurnStart: Bool
    /// What goes before a skill's name at its prompt; nil when Kabuk doesn't list its skills.
    public var skillPrefix: String?
    /// Words that, as the first argument, run something else than a session (`codex login`).
    public var subcommands: Set<String>
    /// `agent "task"` gets to work right away, before any hook says so.
    public var argumentStartsTurn: Bool
    /// Kabuk can install hooks for it.
    public var integrated: Bool
    /// Until its hooks report, Kabuk guesses its turns: return starts one, a terminal
    /// notification or a few quiet seconds end it. Claude and Codex keep to their hooks.
    public var guessesTurns: Bool

    public init(name: String, displayName: String, programs: [String], color: String = "#94a3b8",
                glyph: String = "cpu", prompt: PromptStyle = .typed, reportsTurnStart: Bool = false,
                skillPrefix: String? = nil, subcommands: Set<String> = [], argumentStartsTurn: Bool = false,
                integrated: Bool = false, guessesTurns: Bool = true) {
        self.name = name
        self.displayName = displayName
        self.programs = programs
        self.color = color
        self.glyph = glyph
        self.prompt = prompt
        self.reportsTurnStart = reportsTurnStart
        self.skillPrefix = skillPrefix
        self.subcommands = subcommands
        self.argumentStartsTurn = argumentStartsTurn
        self.integrated = integrated
        self.guessesTurns = guessesTurns
    }

    public var program: String { programs.first ?? name }
}

/// The agents Kabuk recognizes: built in, plus the user's from agents.json.
public enum AgentRegistry {
    public static let builtIn: [AgentProfile] = [
        AgentProfile(name: "claude", displayName: "Claude", programs: ["claude"], color: "#ed8c5c", glyph: "asterisk",
                     prompt: .argument, reportsTurnStart: true, skillPrefix: "/", integrated: true, guessesTurns: false),
        AgentProfile(name: "codex", displayName: "Codex", programs: ["codex"], color: "#5cd1c7",
                     glyph: "chevron.left.forwardslash.chevron.right", prompt: .argument, skillPrefix: "$",
                     subcommands: ["exec", "e", "login", "logout", "mcp", "resume", "apply", "a", "completion", "debug", "help",
                                   "proto", "sandbox", "app-server", "cloud", "features"],
                     argumentStartsTurn: true, integrated: true, guessesTurns: false),
        AgentProfile(name: "opencode", displayName: "OpenCode", programs: ["opencode"], color: "#e8e3d5", glyph: "terminal",
                     prompt: .flag("--prompt"), reportsTurnStart: true,
                     subcommands: ["run", "serve", "web", "auth", "agent", "upgrade", "uninstall", "models", "stats", "export",
                                   "import", "github", "mcp", "acp", "debug", "session", "attach", "help"],
                     integrated: true),
        AgentProfile(name: "gemini", displayName: "Gemini", programs: ["gemini"], color: "#818cf8", glyph: "sparkles",
                     prompt: .flag("-i"), reportsTurnStart: true, subcommands: ["mcp", "extensions", "hooks", "skills"],
                     integrated: true),
        AgentProfile(name: "antigravity", displayName: "Antigravity", programs: ["agy"], color: "#f472b6",
                     glyph: "arrow.up.forward.circle", reportsTurnStart: true, integrated: true),
        AgentProfile(name: "copilot", displayName: "Copilot", programs: ["copilot"], color: "#c084fc", glyph: "airplane",
                     prompt: .flag("-i"), reportsTurnStart: true, subcommands: ["help", "login", "logout", "mcp", "plugin", "update", "version"],
                     integrated: true),
        AgentProfile(name: "cursor", displayName: "Cursor", programs: ["cursor-agent"], prompt: .argument,
                     subcommands: ["login", "logout", "status", "update", "mcp", "ls", "resume", "help"]),
        AgentProfile(name: "amp", displayName: "Amp", programs: ["amp"]),
        AgentProfile(name: "aider", displayName: "Aider", programs: ["aider"]),
        AgentProfile(name: "goose", displayName: "Goose", programs: ["goose"]),
        AgentProfile(name: "droid", displayName: "Droid", programs: ["droid"]),
        AgentProfile(name: "qwen", displayName: "Qwen Code", programs: ["qwen"], prompt: .flag("-i")),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var user: [AgentProfile] = []

    /// Built-in agents first; a user entry can't take a built-in name or program.
    public static var all: [AgentProfile] {
        lock.lock()
        defer { lock.unlock() }
        return builtIn + user
    }

    public static var agents: [AgentKind] { all.map { AgentKind($0.name) } }

    public static func profile(named name: String) -> AgentProfile? {
        all.first { $0.name == name }
    }

    /// The agent a command name starts, if any.
    public static func agent(program: String) -> AgentKind? {
        all.first { $0.programs.contains(program) }.map { AgentKind($0.name) }
    }

    public static func setUserAgents(_ profiles: [AgentProfile]) {
        let taken = Set(builtIn.map(\.name)), programs = Set(builtIn.flatMap(\.programs))
        var seen: Set<String> = []
        let kept = profiles.filter { p in
            !p.name.isEmpty && !taken.contains(p.name) && !p.programs.isEmpty
                && p.programs.allSatisfy { !programs.contains($0) } && seen.insert(p.name).inserted
        }
        lock.lock()
        user = kept
        lock.unlock()
    }

    /// agents.json: `{ "agents": [{ "name": "kiro", "program": "kiro-cli", "color": "#ff9900", "prompt": "argument" }] }`.
    /// `prompt` is "argument", a flag such as "-p", or left out to have Kabuk type the task.
    public static func userAgents(from data: Data) -> [AgentProfile] {
        struct File: Decodable {
            struct Entry: Decodable {
                var name: String
                var displayName: String?
                var program: String?
                var programs: [String]?
                var color: String?
                var prompt: String?
            }
            var agents: [Entry]
        }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.agents.map { entry in
            let name = entry.name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            let prompt: AgentProfile.PromptStyle = switch entry.prompt {
            case nil, "", "typed": .typed
            case "argument": .argument
            case let flag?: .flag(flag)
            }
            return AgentProfile(name: name, displayName: entry.displayName ?? entry.name,
                                programs: entry.programs ?? entry.program.map { [$0] } ?? [name],
                                color: entry.color.flatMap { TerminalTheme.rgb($0) == nil ? nil : $0 } ?? "#94a3b8",
                                prompt: prompt)
        }
    }
}
