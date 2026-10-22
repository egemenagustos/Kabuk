import Foundation

/// Lines changed in a file, numbered as they were at the merge base of two checkouts.
public struct LineRange: Equatable, Sendable {
    public var start: Int
    /// 0 for lines added after `start` without replacing any.
    public var count: Int

    public init(start: Int, count: Int) {
        self.start = start
        self.count = count
    }

    var last: Int { start + max(count, 1) - 1 }
}

/// A file two checkouts of the same repository both change.
public struct OverlapFile: Equatable, Identifiable, Sendable {
    public var path: String
    /// Merging both checkouts would stop on a conflict in this file.
    public var conflict: Bool
    /// Where the other checkout changes it.
    public var theirLines: [LineRange]
    public var id: String { path }

    public init(path: String, conflict: Bool, theirLines: [LineRange] = []) {
        self.path = path
        self.conflict = conflict
        self.theirLines = theirLines
    }
}

/// What one checkout has in common with another one working on the same repository.
public struct Overlap: Equatable, Identifiable, Sendable {
    /// The other checkout's folder: a worktree, or the main checkout.
    public var other: String
    public var otherBranch: String
    /// Conflicts first.
    public var files: [OverlapFile]
    public var id: String { other }

    public init(other: String, otherBranch: String, files: [OverlapFile]) {
        self.other = other
        self.otherBranch = otherBranch
        self.files = files
    }

    public var conflicts: [OverlapFile] { files.filter(\.conflict) }
}

/// Works out which files two checkouts both change and which of them would conflict, from the
/// output of `git diff` and `git merge-tree`.
public enum Overlaps {
    /// Paths `git merge-tree --write-tree -z --name-only --no-messages` lists as conflicted:
    /// everything after the tree id.
    public static func conflictedPaths(mergeTree output: String) -> Set<String> {
        Set(output.split(separator: "\0", omittingEmptySubsequences: true).dropFirst().map(String.init))
    }

    /// Paths in `git diff --name-only -z`.
    public static func paths(nameOnly output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// The old-side line ranges of each file in `git diff -U0 --no-prefix`.
    public static func hunks(diff: String) -> [String: [LineRange]] {
        var result: [String: [LineRange]] = [:]
        var oldPath: String?
        var current: String?
        // ---/+++ name the file only above its first hunk; below it they're removed "-- …" or
        // added "++ …" lines.
        var inHeader = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                oldPath = nil
                current = nil
                inHeader = true
            } else if inHeader, line.hasPrefix("--- ") {
                oldPath = name(line.dropFirst(4))
            } else if inHeader, line.hasPrefix("+++ ") {
                // A deleted file's new side is /dev/null, an added file's old side.
                let newPath = name(line.dropFirst(4))
                current = newPath == "/dev/null" ? oldPath : newPath
            } else if line.hasPrefix("@@ ") {
                inHeader = false
                if let path = current, let range = oldRange(line) { result[path, default: []].append(range) }
            }
        }
        return result
    }

    /// git ends a name that has a space in it with a tab.
    private static func name(_ text: Substring) -> String {
        String(text.hasSuffix("\t") ? text.dropLast() : text)
    }

    /// "@@ -40,21 +40,3 @@" → 40, 21. A missing count means one line.
    static func oldRange(_ header: Substring) -> LineRange? {
        guard let old = header.split(separator: " ").dropFirst().first, old.hasPrefix("-") else { return nil }
        let parts = old.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
        guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
        return LineRange(start: start, count: parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
    }

    /// The files both checkouts change, conflicts first, then by path.
    public static func files(mine: Set<String>, theirs: Set<String>, theirHunks: [String: [LineRange]],
                             conflicted: Set<String>) -> [OverlapFile] {
        mine.intersection(theirs)
            .map { OverlapFile(path: $0, conflict: conflicted.contains($0), theirLines: theirHunks[$0] ?? []) }
            .sorted { ($0.conflict ? 0 : 1, $0.path) < ($1.conflict ? 0 : 1, $1.path) }
    }

    /// "changes lines 2, 40–60 and adds lines after lines 8, 12", or "" without ranges (a binary file).
    public static func describe(_ ranges: [LineRange]) -> String {
        let shown = ranges.prefix(6)
        let changed = shown.filter { $0.count > 0 }.map { $0.count == 1 ? "\($0.start)" : "\($0.start)–\($0.last)" }
        let after = shown.filter { $0.count == 0 && $0.start > 0 }.map { "\($0.start)" }
        var parts: [String] = []
        if !changed.isEmpty {
            let one = changed.count == 1 && shown.first { $0.count > 0 }!.count == 1
            parts.append("changes " + (one ? "line " : "lines ") + changed.joined(separator: ", "))
        }
        var places: [String] = []
        if shown.contains(where: { $0.count == 0 && $0.start == 0 }) { places.append("at the top") }
        if !after.isEmpty { places.append((after.count == 1 ? "after line " : "after lines ") + after.joined(separator: ", ")) }
        if !places.isEmpty { parts.append("adds lines " + places.joined(separator: " and ")) }
        let more = ranges.count > shown.count ? " (\(ranges.count - shown.count) more places)" : ""
        return parts.joined(separator: " and ") + (parts.isEmpty ? "" : more)
    }
}

public enum OverlapPrompt {
    /// Tells an agent what the other checkout changes, so it can keep clear of it. `otherName`
    /// reads after "you and": "Codex", "whoever works in the main checkout".
    public static func build(_ overlap: Overlap, otherName: String, otherFolder: String) -> String {
        var text = "Heads-up from Kabuk: you and \(otherName) are changing the same files in parallel. "
            + "It works on branch \(overlap.otherBranch), in \(otherFolder)."
        let conflicts = overlap.conflicts
        let others = overlap.files.filter { !$0.conflict }
        if !conflicts.isEmpty {
            text += "\n\nMerging both branches would conflict in:"
            for file in conflicts { text += line(file) }
        }
        if !others.isEmpty {
            text += conflicts.isEmpty ? "\n\nThe changes don't conflict yet, in:" : "\n\nBoth of you also change, without conflicting yet:"
            for file in others { text += line(file) }
        }
        return text + "\n\nLine numbers are from before either change. Keep clear of those lines if your task allows it; "
            + "if it doesn't, tell me before changing them further."
    }

    private static func line(_ file: OverlapFile) -> String {
        let lines = Overlaps.describe(file.theirLines)
        return "\n- \(file.path)" + (lines.isEmpty ? "" : ", where it \(lines)")
    }
}
