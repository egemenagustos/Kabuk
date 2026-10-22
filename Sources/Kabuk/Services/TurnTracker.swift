import Foundation
import KabukCore

/// Snapshots a pane's working tree when an agent turn starts and diffs it when the turn ends.
/// Everything runs on one serial queue, so a turn's end always sees its own start.
@MainActor
final class TurnTracker {
    var onChange: ((UUID, TurnChange?) -> Void)?
    private let queue = DispatchQueue(label: "kabuk.turns", qos: .utility)
    nonisolated(unsafe) private var baselines: [UUID: TurnBaseline] = [:]

    func begin(_ paneID: UUID, cwd: String) {
        queue.async { [weak self] in
            self?.baselines[paneID] = Self.baseline(cwd)
        }
    }

    func finish(_ paneID: UUID) {
        queue.async { [weak self] in
            guard let self, let before = self.baselines.removeValue(forKey: paneID) else { return }
            let change = Self.change(since: before)
            DispatchQueue.main.async { self.onChange?(paneID, change) }
        }
    }

    nonisolated private static func baseline(_ cwd: String) -> TurnBaseline? {
        let top = Shell.git(["rev-parse", "--show-toplevel"], in: cwd)
        guard top.ok else { return nil }
        let root = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A commit of the current working tree, without touching it; empty when nothing is dirty.
        let stash = Shell.git(["stash", "create"], in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = Shell.git(["rev-parse", "HEAD"], in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = stash.isEmpty ? head : stash
        guard !base.isEmpty else { return nil }
        return TurnBaseline(base: base, top: root, untracked: untracked(root), snapshot: snapshot(root),
                            head: head.isEmpty ? nil : head)
    }

    /// A commit of the whole working tree, untracked files included. It's built in a throwaway
    /// index, so neither the user's index nor their files are touched. Nothing refers to it;
    /// git keeps it for weeks before pruning, far longer than an undo needs. With `fixedDate`, the
    /// same working tree always gives the same commit, so taking it again writes nothing new.
    nonisolated static func snapshot(_ top: String, fixedDate: Bool = false) -> String? {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("kabuk-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        // Starting from a copy of the real index lets git reuse its cached file stats.
        let real = Shell.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: top).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.copyItem(atPath: real, toPath: index.path)
        var env = ["GIT_INDEX_FILE": index.path,
                   "GIT_AUTHOR_NAME": "Kabuk", "GIT_AUTHOR_EMAIL": "kabuk@localhost",
                   "GIT_COMMITTER_NAME": "Kabuk", "GIT_COMMITTER_EMAIL": "kabuk@localhost"]
        if fixedDate {
            env["GIT_AUTHOR_DATE"] = "@1000000000 +0000"
            env["GIT_COMMITTER_DATE"] = "@1000000000 +0000"
        }
        guard Shell.git(["add", "-A"], in: top, environment: env).ok else { return nil }
        let tree = Shell.git(["write-tree"], in: top, environment: env)
        guard tree.ok else { return nil }
        let head = Shell.git(["rev-parse", "-q", "--verify", "HEAD"], in: top).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = Shell.git(["commit-tree", tree.stdout.trimmingCharacters(in: .whitespacesAndNewlines)]
                                + (head.isEmpty ? [] : ["-p", head]) + ["-m", "Kabuk turn snapshot"],
                               in: top, environment: env)
        let id = commit.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.ok && !id.isEmpty ? id : nil
    }

    nonisolated private static func change(since before: TurnBaseline) -> TurnChange? {
        let numstat = Shell.git(["diff", "--numstat", "--no-renames", before.base], in: before.top)
        guard numstat.ok else { return nil }
        let change = TurnDiff.change(numstat: numstat.stdout, before: before, untrackedAfter: untracked(before.top),
                                     lineCount: { lineCount(URL(fileURLWithPath: before.top).appendingPathComponent($0)) })
        return change.files.isEmpty ? nil : change
    }

    nonisolated static func untracked(_ top: String) -> [String: Date] {
        let list = Shell.git(["ls-files", "--others", "--exclude-standard"], in: top)
        var result: [String: Date] = [:]
        for path in list.stdout.split(separator: "\n").prefix(2000) {
            let url = URL(fileURLWithPath: top).appendingPathComponent(String(path))
            result[String(path)] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        return result
    }

    /// Lines in a text file; nil for binaries and files over 1 MB.
    nonisolated static func lineCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000, !data.contains(0) else { return nil }
        let newlines = data.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
        return newlines + (data.last == 10 || data.isEmpty ? 0 : 1)
    }

    /// How many commits the agent made since the turn started.
    nonisolated static func commitsSince(_ change: TurnChange) -> Int {
        guard let head = change.head else { return 0 }
        return Int(Shell.git(["rev-list", "--count", "\(head)..HEAD"], in: change.top).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Puts the turn's files back as they were when it started, and the branch back where it
    /// was. Returns what redo needs: a snapshot of the files as they are now and the current HEAD.
    nonisolated static func undo(_ change: TurnChange) -> Result<UndoneTurn, TurnUndoFailure> {
        guard let start = change.snapshot else { return .failure(.message("No snapshot was taken when this turn started.")) }
        guard let now = snapshot(change.top) else { return .failure(.message("Couldn't save the current files for redo.")) }
        let head = Shell.git(["rev-parse", "HEAD"], in: change.top).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = restore(change, to: start, head: change.head, currentHead: head) { return .failure(failure) }
        return .success(UndoneTurn(snapshot: now, head: head.isEmpty ? nil : head))
    }

    nonisolated static func redo(_ change: TurnChange, _ undone: UndoneTurn) -> TurnUndoFailure? {
        let head = Shell.git(["rev-parse", "HEAD"], in: change.top).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return restore(change, to: undone.snapshot, head: undone.head, currentHead: head)
    }

    nonisolated private static func restore(_ change: TurnChange, to snapshot: String, head: String?,
                                            currentHead: String) -> TurnUndoFailure? {
        let top = change.top
        if let head, head != currentHead {
            // Mixed: the branch and index go back, the files are handled below.
            let reset = Shell.git(["reset", "--quiet", "--mixed", head], in: top)
            guard reset.ok else { return .message(reset.stderr) }
        }
        let paths = change.files.map(\.path)
        let listed = Shell.git(["ls-tree", "-r", "--name-only", snapshot, "--"] + paths, in: top)
        guard listed.ok else { return .message(listed.stderr) }
        let present = Set(listed.stdout.split(separator: "\n").map(String.init))
        var restore: [String] = []
        for step in TurnUndo.steps(paths: paths, inSnapshot: present) {
            switch step {
            case .restore(let path):
                restore.append(path)
            case .delete(let path):
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: top).appendingPathComponent(path))
            }
        }
        if !restore.isEmpty {
            let result = Shell.git(["restore", "--source=\(snapshot)", "--worktree", "--"] + restore, in: top)
            guard result.ok else { return .message(result.stderr) }
        }
        return nil
    }

    /// The diff of one file against the turn's starting point, ready for display.
    nonisolated static func diff(_ file: FileChange, in change: TurnChange) -> [DiffLine] {
        if file.isNew {
            let url = URL(fileURLWithPath: change.top).appendingPathComponent(file.path)
            guard lineCount(url) != nil, let text = try? String(contentsOf: url, encoding: .utf8) else {
                return [DiffLine(id: 0, kind: .header, text: "Binary or large file")]
            }
            return DiffLine.allAdded(text)
        }
        let result = Shell.git(["diff", "--no-color", change.base, "--", file.path], in: change.top)
        return result.stdout.isEmpty ? [DiffLine(id: 0, kind: .header, text: "No textual changes")] : DiffLine.classify(result.stdout)
    }
}

/// What an undone turn needs to be redone.
struct UndoneTurn: Equatable, Sendable {
    var snapshot: String
    var head: String?
}

enum TurnUndoFailure: LocalizedError, Equatable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
