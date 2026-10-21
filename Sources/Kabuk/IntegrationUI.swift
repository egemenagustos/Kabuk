import AppKit
import KabukCore

/// Menu and palette entry points for installing the agent hooks, with a summary alert.
@MainActor
enum IntegrationUI {
    static func install() {
        var lines: [String] = []
        do {
            try IntegrationInstaller.installClaude()
            lines.append("✓ Claude Code: hooks added to ~/.claude/settings.json.")
        } catch {
            lines.append("✕ Claude Code: \(error.localizedDescription)")
        }
        do {
            try IntegrationInstaller.installCodex()
            lines.append("✓ Codex: notify added to ~/.codex/config.toml.")
        } catch {
            lines.append("✕ Codex: \(error.localizedDescription)")
        }
        lines.append("\nOn first install the original files were backed up with a .kabuk-backup extension. Restart any running Claude or Codex sessions to pick up the change.")
        alert("Agent Integration", lines.joined(separator: "\n"))
    }

    /// Hooks installed by an older Kabuk miss newer events (subagents). Asks once per set of events.
    static func offerUpdateIfOutdated() {
        let key = "declinedIntegrationUpdate"
        let events = IntegrationInstaller.claudeEvents.joined(separator: ",")
        guard IntegrationInstaller.claudeOutdated(), UserDefaults.standard.string(forKey: key) != events else { return }
        let alert = NSAlert()
        alert.messageText = "Update the Claude Code integration?"
        alert.informativeText = "This version of Kabuk can show Claude's subagents and give them their own worktrees. That needs a few more hooks in ~/.claude/settings.json."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            install()
        } else {
            UserDefaults.standard.set(events, forKey: key)
        }
    }

    static func uninstall() {
        var lines: [String] = []
        do {
            try IntegrationInstaller.uninstallClaude()
            lines.append("✓ Claude Code hooks removed.")
        } catch {
            lines.append("✕ Claude Code: \(error.localizedDescription)")
        }
        do {
            try IntegrationInstaller.uninstallCodex()
            lines.append("✓ Codex notify removed.")
        } catch {
            lines.append("✕ Codex: \(error.localizedDescription)")
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
