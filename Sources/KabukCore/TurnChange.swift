import Foundation

/// One file an agent touched during a turn.
public struct FileChange: Equatable, Identifiable, Sendable {
    public var path: String
    /// Nil for binary files and for untracked files whose content changed in place.
    public var added: Int?
    public var removed: Int?
    public var isNew: Bool

    public var id: String { path }

    public init(path: String, added: Int?, removed: Int?, isNew: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.isNew = isNew
    }
}

/// What changed in the working tree between the start and end of an agent turn.
public struct TurnChange: Equatable, Sendable {
    public var files: [FileChange]
    /// The snapshot commit the turn started from; diffs are taken against it.
    public var base: String
    /// The working tree's top-level folder; file paths are relative to it.
    public var top: String
    public var finishedAt: Date

    public init(files: [FileChange], base: String, top: String, finishedAt: Date = Date()) {
        self.files = files
        self.base = base
        self.top = top
        self.finishedAt = finishedAt
    }

    public var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    public var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

/// The working tree at the start of a turn.
public struct TurnBaseline: Sendable {
    public var base: String
    public var top: String
    /// Untracked files and their modification dates; `git stash create` doesn't cover them.
    public var untracked: [String: Date]

    public init(base: String, top: String, untracked: [String: Date]) {
        self.base = base
        self.top = top
        self.untracked = untracked
    }
}

public enum TurnDiff {
    /// Parses `git diff --numstat` output ("12\t3\tpath", "-\t-\timage.png" for binaries).
    public static func parseNumstat(_ text: String) -> [FileChange] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { return nil }
            return FileChange(path: String(fields[2]), added: Int(fields[0]), removed: Int(fields[1]))
        }
    }

    /// Combines tracked changes with untracked files that appeared or changed during the turn.
    /// `lineCount` returns a new file's line count, or nil for binary or huge files.
    public static func change(numstat: String, before: TurnBaseline, untrackedAfter: [String: Date],
                              lineCount: (String) -> Int?, now: Date = Date()) -> TurnChange {
        var files = parseNumstat(numstat)
        for (path, modified) in untrackedAfter.sorted(by: { $0.key < $1.key }) {
            if let previous = before.untracked[path] {
                if modified > previous { files.append(FileChange(path: path, added: nil, removed: nil)) }
            } else {
                files.append(FileChange(path: path, added: lineCount(path), removed: 0, isNew: true))
            }
        }
        return TurnChange(files: files, base: before.base, top: before.top, finishedAt: now)
    }
}

/// A line of unified diff output, classified for coloring.
public struct DiffLine: Equatable, Identifiable, Sendable {
    public enum Kind: Sendable { case header, hunk, add, remove, context }

    public var id: Int
    public var kind: Kind
    public var text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    public static func classify(_ diff: String) -> [DiffLine] {
        diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let line = String(raw)
            let kind: Kind
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ")
                || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                kind = .header
            } else if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+") {
                kind = .add
            } else if line.hasPrefix("-") {
                kind = .remove
            } else {
                kind = .context
            }
            return DiffLine(id: index, kind: kind, text: line)
        }
    }

    /// Shows a new file's content as one big addition.
    public static func allAdded(_ content: String) -> [DiffLine] {
        content.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
            DiffLine(id: $0.offset, kind: .add, text: "+" + $0.element)
        }
    }
}
