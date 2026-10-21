import Foundation

/// A note the user left on one line of a diff, for the agent to act on.
public struct DiffComment: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    /// The line number in the new file, or in the old one for a removed line.
    public var line: Int?
    public var removed: Bool
    public var code: String
    public var note: String

    public init(id: UUID = UUID(), path: String, line: Int?, removed: Bool = false, code: String, note: String) {
        self.id = id
        self.path = path
        self.line = line
        self.removed = removed
        self.code = code
        self.note = note
    }

    public init(path: String, diffLine: DiffLine, note: String) {
        self.init(path: path, line: diffLine.newLine ?? diffLine.oldLine, removed: diffLine.kind == .remove,
                  code: diffLine.code, note: note)
    }

    /// "src/app.ts:42", "src/app.ts:42 (removed line)".
    public var location: String {
        let base = line.map { "\(path):\($0)" } ?? path
        return removed ? base + " (removed line)" : base
    }
}

public enum ReviewPrompt {
    /// One prompt carrying every note, grouped in the order they were written.
    public static func build(_ comments: [DiffComment]) -> String {
        var text = "I reviewed your changes and left notes on specific lines:\n"
        for comment in comments {
            let code = comment.code.trimmingCharacters(in: .whitespaces)
            text += "\n- \(comment.location)"
            if !code.isEmpty { text += "\n  `\(code.count > 120 ? String(code.prefix(119)) + "…" : code)`" }
            text += "\n  \(comment.note.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return text + "\n\nPlease address each note."
    }
}
