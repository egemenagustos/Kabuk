import Foundation

/// A Claude subagent working under a pane's main agent, as its hooks report it.
public struct Subagent: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable { case working, done }

    public var id: String
    /// "general-purpose", "Explore", "fork", or a custom agent's name.
    public var type: String
    /// The short task description Claude gave it.
    public var description: String
    public var state: State = .working
    public var startedAt: Date
    public var finishedAt: Date?
    public var toolCount = 0
    public var lastTool: String?
    /// Where its tools run; a folder other than the pane's means it has a worktree.
    public var cwd: String?
    /// The worktree's branch, looked up once the folder is known.
    public var branch: String?
    public var transcript: String?
    /// The first line of its final message.
    public var summary: String?

    public init(id: String, type: String, description: String, startedAt: Date) {
        self.id = id
        self.type = type
        self.description = description
        self.startedAt = startedAt
    }

    /// What the sidebar and the strip call it: the task, or the type when there's no task.
    public var title: String { description.isEmpty ? type : description }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

/// A subagent launch seen in PreToolUse, waiting for its SubagentStart to give it an id.
public struct SubagentLaunch: Equatable, Sendable {
    public var type: String
    public var description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

/// Gives editing subagents their own git worktree by adding `isolation: "worktree"` to the
/// Agent tool call, so parallel subagents don't write over each other's files.
public enum SubagentIsolation {
    /// Built-in agents that only read; a worktree would be wasted on them.
    public static let readOnlyTypes: Set<String> = ["Explore", "Plan", "claude-code-guide", "statusline-setup"]
    public static let launchTools: Set<String> = ["Agent", "Task"]

    /// The Agent tool input with isolation added, or nil to leave the call alone.
    public static func updatedInput(_ input: [String: Any], enabled: Bool, inGitRepository: Bool) -> [String: Any]? {
        guard enabled, inGitRepository, input["isolation"] == nil else { return nil }
        let type = input["subagent_type"] as? String ?? "general-purpose"
        guard !readOnlyTypes.contains(type) else { return nil }
        var updated = input
        updated["isolation"] = "worktree"
        return updated
    }

    /// The PreToolUse hook's stdout that swaps in the new input.
    public static func hookOutput(_ input: [String: Any]) -> String? {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PreToolUse", "updatedInput": input]]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// True when `path` or a folder above it has a `.git`, without starting git.
    public static func inGitRepository(_ path: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        while true {
            if fileExists(url.appendingPathComponent(".git").path) { return true }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return false }
            url = parent
        }
    }
}

/// One step of a subagent's transcript, for the live view.
public struct TranscriptStep: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case tool, text }

    public var id: Int
    public var kind: Kind
    /// The tool's name, or "Claude" for text.
    public var title: String
    public var detail: String

    public init(id: Int, kind: Kind, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public enum SubagentTranscript {
    /// The assistant's tool calls and text in a subagent's JSONL transcript, oldest first, the
    /// last `limit` of them.
    public static func steps(_ data: Data, limit: Int = 60) -> [TranscriptStep] {
        var steps: [TranscriptStep] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    steps.append(TranscriptStep(id: steps.count, kind: .tool, title: name,
                                                detail: PermissionSummary.detail(tool: name, input: input)))
                case "text":
                    let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        steps.append(TranscriptStep(id: steps.count, kind: .text, title: "Claude",
                                                    detail: PermissionSummary.oneLine(text, limit: 400)))
                    }
                default:
                    continue
                }
            }
        }
        return Array(steps.suffix(limit))
    }
}
