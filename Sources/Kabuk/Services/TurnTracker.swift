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
        let base = stash.isEmpty ? Shell.git(["rev-parse", "HEAD"], in: root).stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stash
        guard !base.isEmpty else { return nil }
        return TurnBaseline(base: base, top: root, untracked: untracked(root))
    }

    nonisolated private static func change(since before: TurnBaseline) -> TurnChange? {
        let numstat = Shell.git(["diff", "--numstat", before.base], in: before.top)
        guard numstat.ok else { return nil }
        let change = TurnDiff.change(numstat: numstat.stdout, before: before, untrackedAfter: untracked(before.top),
                                     lineCount: { lineCount(URL(fileURLWithPath: before.top).appendingPathComponent($0)) })
        return change.files.isEmpty ? nil : change
    }

    nonisolated private static func untracked(_ top: String) -> [String: Date] {
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
