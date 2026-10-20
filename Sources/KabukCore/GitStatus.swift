import Foundation

/// A pane's repository state, shown as branch and diff badges.
public struct GitStatus: Equatable, Sendable {
    public var branch: String
    public var ahead = 0
    public var behind = 0
    /// Tracked files with changes, staged or not.
    public var changed = 0
    public var untracked = 0
    public var added = 0
    public var removed = 0

    public init(branch: String, ahead: Int = 0, behind: Int = 0, changed: Int = 0, untracked: Int = 0,
                added: Int = 0, removed: Int = 0) {
        self.branch = branch
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.untracked = untracked
        self.added = added
        self.removed = removed
    }

    public var isDirty: Bool { changed + untracked > 0 }

    /// Parses `git status --porcelain=v2 --branch` and, optionally, `git diff --numstat HEAD`.
    public static func parse(status: String, numstat: String = "") -> GitStatus? {
        var result = GitStatus(branch: "")
        var oid = ""
        for line in status.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                result.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.ab ") {
                for part in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") {
                result.changed += 1
            } else if line.hasPrefix("? ") {
                result.untracked += 1
            }
        }
        guard !result.branch.isEmpty else { return nil }
        if result.branch == "(detached)" { result.branch = String(oid.prefix(7)) }
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2 else { continue }
            result.added += Int(fields[0]) ?? 0
            result.removed += Int(fields[1]) ?? 0
        }
        return result
    }
}
