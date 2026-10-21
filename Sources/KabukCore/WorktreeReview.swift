import Foundation

/// A commit on a worktree's branch that its target branch doesn't have yet.
public struct WorktreeCommit: Equatable, Identifiable, Sendable {
    public var hash: String
    public var subject: String
    public var id: String { hash }

    public init(hash: String, subject: String) {
        self.hash = hash
        self.subject = subject
    }
}

/// Everything the review sheet shows about a worktree before it's merged.
public struct WorktreeSummary: Equatable, Sendable {
    /// The branch checked out in the main checkout, which the worktree merges into.
    public var target: String
    public var commits: [WorktreeCommit]
    /// Committed and uncommitted changes against the merge base, as a turn-style change list.
    public var change: TurnChange?
    /// The worktree has uncommitted changes, which a merge wouldn't include.
    public var dirty: Bool
    /// The main checkout has uncommitted changes to tracked files; merging there is refused.
    public var targetDirty: Bool

    public init(target: String, commits: [WorktreeCommit], change: TurnChange?, dirty: Bool, targetDirty: Bool) {
        self.target = target
        self.commits = commits
        self.change = change
        self.dirty = dirty
        self.targetDirty = targetDirty
    }

    /// Why merging isn't possible right now, or nil when it is.
    public var mergeBlocker: String? {
        if targetDirty { return "\(target) has uncommitted changes in the main checkout. Commit or stash them first." }
        if dirty { return "Commit the worktree's changes first; a merge only takes commits." }
        if commits.isEmpty { return "The branch has no commits that \(target) doesn't have." }
        return nil
    }
}

public enum WorktreeReview {
    /// Parses `git log --format=%h%x09%s`.
    public static func parseLog(_ text: String) -> [WorktreeCommit] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return WorktreeCommit(hash: String(parts[0]), subject: String(parts[1]))
        }
    }

    /// The commit message for a squash merge: one commit's own subject, or the branch with
    /// every subject listed below it.
    public static func squashMessage(branch: String, commits: [WorktreeCommit]) -> String {
        if commits.count == 1 { return commits[0].subject }
        let list = commits.reversed().map { "- " + $0.subject }.joined(separator: "\n")
        return "Merge \(branch)\n\n\(list)"
    }

    /// A commit message for "Commit all" when the user leaves it empty.
    public static func defaultCommitMessage(_ change: TurnChange?) -> String {
        guard let files = change?.files, !files.isEmpty else { return "Work in progress" }
        if files.count == 1 { return "Update \(files[0].path)" }
        return "Update \(files.count) files"
    }
}
