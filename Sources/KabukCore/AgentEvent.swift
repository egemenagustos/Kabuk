import Foundation

/// The events every agent other than Claude and Codex sends, whatever its own hooks are called.
/// `kabuk-hook` translates each agent's hooks into these; Kabuk itself adds the guesses.
public enum AgentEvent {
    /// The user gave the agent a task. `prompt` holds it when the hook has it.
    public static let turnStart = "turn-start"
    /// The agent used a tool; it's working.
    public static let tool = "tool"
    /// The agent asks to use a tool and `kabuk-hook` waits for the answer (`request`, `tool`, `detail`).
    public static let permission = "permission"
    /// The agent waits for the user; `message` says why.
    public static let needsYou = "needs-you"
    /// The agent finished its turn.
    public static let turnEnd = "turn-end"

    /// A terminal notification (OSC 9, 99 or 777) from the agent's pane, with its text in `message`.
    public static let notification = "notification"
    /// The agent's pane printed nothing for a while during a turn.
    public static let quiet = "quiet"

    public static let guesses: Set<String> = [notification, quiet]
    public static let all: Set<String> = [turnStart, tool, permission, needsYou, turnEnd, notification, quiet]
    /// Signs that a held permission request was answered in the terminal.
    static let progress: Set<String> = [turnStart, tool, turnEnd]

    /// From the agent's own hooks rather than Kabuk's guesses.
    static func fromHooks(_ event: String) -> Bool {
        !guesses.contains(event) && event != "StatusLine"
    }

    /// Whether a notification asks the user for something, rather than saying the agent is done.
    public static func asksForInput(_ message: String?) -> Bool {
        guard let text = message?.lowercased(), !text.isEmpty else { return false }
        let words = ["permission", "approve", "approval", "allow", "confirm", "waiting for", "needs your", "input",
                     "question", "respond", "?"]
        return words.contains { text.contains($0) }
    }

    /// The text of a terminal notification, or nil for an OSC that isn't one:
    /// `9;text` (iTerm2), `777;notify;title;body` (rxvt), `99;metadata;text` (kitty).
    /// OSC 9 with a number first is ConEmu's progress and the like, not a notification.
    public static func notificationText(code: Int, payload: String) -> String? {
        let text: String
        switch code {
        case 9:
            if let first = payload.split(separator: ";", maxSplits: 1).first, first.allSatisfy(\.isNumber),
               payload.contains(";") || payload.allSatisfy(\.isNumber) {
                return nil
            }
            text = payload
        case 777:
            let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.first == "notify" else { return nil }
            text = [parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : ""]
                .filter { !$0.isEmpty }.joined(separator: ": ")
        case 99:
            let parts = payload.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { return nil }
            let metadata = parts[0].split(separator: ":")
            // Only the last chunk of a notification, and not queries or closes.
            if metadata.contains("d=0") || metadata.contains(where: { $0.hasPrefix("p=") && $0 != "p=title" && $0 != "p=body" }) {
                return nil
            }
            text = parts[1]
        default:
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : PermissionSummary.oneLine(trimmed, limit: 200)
    }
}
