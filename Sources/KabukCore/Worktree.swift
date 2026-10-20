import Foundation

/// A session that runs in its own git worktree, so parallel agents don't edit the same files.
public struct WorktreeInfo: Codable, Equatable, Sendable {
    public var path: String
    public var branch: String
    public var repoRoot: String
    /// The commit the worktree branched from.
    public var baseRef: String

    public init(path: String, branch: String, repoRoot: String, baseRef: String) {
        self.path = path
        self.branch = branch
        self.repoRoot = repoRoot
        self.baseRef = baseRef
    }

    public var name: String { (path as NSString).lastPathComponent }
}

public enum WorktreeNaming {
    /// Where worktrees live: ~/.kabuk/worktrees/<repo>/<name>. Outside the repo, so they
    /// never show up in its own `git status`.
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kabuk/worktrees", isDirectory: true)
    }

    /// "claude-7f3a", "codex-01bc", "shell-9e2d".
    public static func name(agent: AgentKind?, suffix: String = randomSuffix()) -> String {
        "\(agent?.rawValue ?? "shell")-\(suffix)"
    }

    public static func branch(for name: String) -> String {
        "kabuk/\(name)"
    }

    public static func path(repoRoot: String, name: String, root: URL = root) -> String {
        let repo = (repoRoot as NSString).lastPathComponent
        return root.appendingPathComponent(repo, isDirectory: true).appendingPathComponent(name, isDirectory: true).path
    }

    public static func randomSuffix() -> String {
        String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }
}
