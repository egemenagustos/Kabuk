import Foundation

/// Derives the pane tag and agent kind from a command line.
public enum CommandInfo {
    private static let wrappers: Set<String> = ["sudo", "env", "time", "nohup", "exec", "command", "caffeinate"]

    private static let tagMap: [String: String] = [
        "npm": "node", "npx": "node", "node": "node", "pnpm": "node", "yarn": "node", "bun": "node",
        "deno": "node", "vite": "node", "next": "node", "tsx": "node",
        "python": "python", "python3": "python", "pip": "python", "pip3": "python", "uv": "python",
        "pytest": "python", "ipython": "python",
        "swift": "swift", "xcodebuild": "swift", "xcrun": "swift",
        "cargo": "rust", "rustc": "rust",
        "go": "go",
        "vim": "vim", "nvim": "vim", "vi": "vim",
        "docker": "docker", "docker-compose": "docker", "kubectl": "k8s",
        "ssh": "ssh", "mosh": "ssh",
        "git": "git", "gh": "git", "lazygit": "git",
        "make": "make", "brew": "brew",
    ]

    /// Steps that only prepare the shell; `cd app && npm run dev` is about npm.
    private static let setupPrograms: Set<String> = ["cd", "pushd", "export", "source", ".", "set", "unset", "clear"]

    /// Words of the command's main step, with leading `VAR=value` assignments and wrappers removed.
    public static func words(_ command: String) -> [String] {
        let steps = command.components(separatedBy: "&&").flatMap { $0.components(separatedBy: ";") }
        let main = steps.first { step in
            guard let first = step.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
            return !setupPrograms.contains(String(first))
        } ?? steps.first ?? command
        var words = main.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = words.first, first.contains("=") || wrappers.contains(first) {
            words.removeFirst()
        }
        return words
    }

    public static func program(_ command: String) -> String? {
        guard let first = words(command).first else { return nil }
        return (first as NSString).lastPathComponent
    }

    public static func agent(_ command: String) -> AgentKind? {
        guard let program = program(command) else { return nil }
        return AgentRegistry.agent(program: program)
    }

    /// An agent's tag is its name: `agy` shows as "antigravity".
    public static func tag(_ command: String) -> String {
        guard let program = program(command) else { return "zsh" }
        if let agent = AgentRegistry.agent(program: program) { return agent.rawValue }
        return tagMap[program] ?? program
    }

    /// `codex "fix the bug"` starts working right away; bare `codex` waits for input.
    public static func startsWithPrompt(_ command: String, agent: AgentKind) -> Bool {
        let profile = agent.profile
        guard profile.argumentStartsTurn else { return false }
        let args = words(command).dropFirst()
        guard let first = args.first(where: { !$0.hasPrefix("-") }) else { return false }
        return !profile.subcommands.contains(first)
    }
}
