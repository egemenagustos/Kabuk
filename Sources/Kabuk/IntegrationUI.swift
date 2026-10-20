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
