import AppKit
import KabukCore

/// Menu and palette entry points for installing the agent hooks, with a summary alert.
@MainActor
enum IntegrationUI {
    /// Claude and Codex always, as before; other agents when they're installed.
    static func agents(installed: [AgentKind]) -> [AgentKind] {
        [.claude, .codex] + IntegrationInstaller.hookedAgents.filter(installed.contains)
    }

    static func install(installed: [AgentKind]) {
        install(agents(installed: installed))
    }

    private static func install(_ agents: [AgentKind]) {
        var lines: [String] = []
        for agent in agents {
            do {
                try IntegrationInstaller.install(agent)
                lines.append("✓ " + summary(agent))
            } catch {
                lines.append("✕ \(agent.displayName): \(error.localizedDescription)")
            }
        }
        lines.append("\nOn first install the original files were backed up with a .kabuk-backup extension. Restart any running agent sessions to pick up the change.")
        alert("Agent Integration", lines.joined(separator: "\n"))
    }

    private static func summary(_ agent: AgentKind) -> String {
        switch agent {
        case .claude:
            return "Claude Code: hooks added to ~/.claude/settings.json, and the kabuk-delegate skill to ~/.claude/skills, so Claude can hand work to another agent in a new worktree."
        case .codex:
            return "Codex: notify added to ~/.codex/config.toml."
        case .opencode:
            return "OpenCode: a plugin added as \(IntegrationInstaller.location(agent)). In Kabuk, opencode runs with its own server so the plugin sees its pane."
        default:
            return "\(agent.displayName): hooks added to \(IntegrationInstaller.location(agent))."
        }
    }

    /// An integration installed by an older Kabuk misses newer events (subagents) or the status
    /// line (plan limits). Asks once per set of them.
    static func offerUpdateIfOutdated() {
        let key = "declinedIntegrationUpdate"
        let outdated = ([AgentKind.claude, .codex] + IntegrationInstaller.hookedAgents).filter(IntegrationInstaller.outdated)
        let events = (IntegrationInstaller.claudeEvents + ["statusLine"] + outdated.map(\.rawValue)).joined(separator: ",")
        guard !outdated.isEmpty, UserDefaults.standard.string(forKey: key) != events else { return }
        let alert = NSAlert()
        if outdated == [.claude] {
            alert.messageText = "Update the Claude Code integration?"
            alert.informativeText = "This version of Kabuk can show your Claude plan limits, show Claude's subagents, give them their own worktrees, and let Claude hand work to other agents. That needs a status line command and a few more hooks in ~/.claude/settings.json, and a skill in ~/.claude/skills. Your own status line keeps working."
        } else {
            alert.messageText = "Update the agent integrations?"
            alert.informativeText = "This version of Kabuk sets up \(outdated.map(\.displayName).joined(separator: ", ")) differently than the one that installed the integration. Your own hooks and settings stay as they are."
        }
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            install(outdated)
        } else {
            UserDefaults.standard.set(events, forKey: key)
        }
    }

    static func uninstall() {
        var lines: [String] = []
        let others = IntegrationInstaller.hookedAgents.filter(IntegrationInstaller.installed)
        for agent in [AgentKind.claude, .codex] + others {
            do {
                try IntegrationInstaller.uninstall(agent)
                lines.append("✓ \(agent.displayName): removed.")
            } catch {
                lines.append("✕ \(agent.displayName): \(error.localizedDescription)")
            }
        }
        alert("Agent Integration", lines.joined(separator: "\n"))
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
