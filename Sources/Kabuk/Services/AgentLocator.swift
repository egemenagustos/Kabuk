import Foundation
import KabukCore

/// Finds which agents are installed, and reads the user's own agents from agents.json.
enum AgentLocator {
    static var userAgentsURL: URL { ShellIntegration.supportDir.appendingPathComponent("agents.json") }

    static func loadUserAgents() {
        guard let data = try? Data(contentsOf: userAgentsURL) else { return }
        AgentRegistry.setUserAgents(AgentRegistry.userAgents(from: data))
    }

    /// Asks a login shell, which has the user's PATH, for every agent's program. Claude and
    /// Codex stay listed even when it can't find them, as they always were.
    static func installed(_ done: @escaping @MainActor ([AgentKind]) -> Void) {
        let profiles = AgentRegistry.all
        let programs = profiles.flatMap(\.programs)
        DispatchQueue.global(qos: .utility).async {
            // `whence -p` prints a path per program it finds and nothing for the rest.
            let script = programs.map { "whence -p '\($0)' || command -v '\($0)'" }.joined(separator: "; ")
            let result = Shell.run(ShellIntegration.userShell, ["-l", "-c", script + "; true"])
            let found = Set(result.stdout.split(whereSeparator: \.isNewline).map { ($0 as NSString).lastPathComponent })
            let agents = profiles.filter { profile in
                profile.name == "claude" || profile.name == "codex" || profile.programs.contains(where: found.contains)
            }.compactMap { AgentKind(rawValue: $0.name) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(agents) } }
        }
    }
}
