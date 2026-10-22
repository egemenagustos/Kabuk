import Foundation
import KabukCore

/// Watches the checkouts of a repository that worktree sessions work on in parallel, and finds
/// the files two of them both change before either is merged: whether merging both would
/// conflict, and where. Debounced per repository; the work runs on one serial queue.
@MainActor
final class ConflictRadar {
    /// A folder with its own working tree: the main checkout or a worktree. An empty branch is
    /// looked up during the scan.
    struct Checkout: Equatable, Sendable {
        var path: String
        var branch: String
    }

    /// The repository's overlaps by checkout folder; checkouts without any are left out.
    var onUpdate: ((_ repo: String, _ overlaps: [String: [Overlap]]) -> Void)?
    /// Repositories with a scan waiting or running, and of those the ones running.
    private var busy: Set<String> = []
    private var scanning: Set<String> = []
    /// Asked for again while busy; scanned once more when the scan in progress ends.
    private var again: [String: () -> [Checkout]] = [:]
    private let queue = DispatchQueue(label: "kabuk.radar", qos: .utility)

    /// Agents edit in bursts; one scan a little after the first edit covers the whole burst.
    /// Edits during a scan add just one more scan after it, however slow the repository is.
    func refresh(repo: String, checkouts: @escaping () -> [Checkout], delay: TimeInterval = 2) {
        guard busy.insert(repo).inserted else {
            // A scan that hasn't started yet will see this edit anyway.
            if scanning.contains(repo) { again[repo] = checkouts }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let list = checkouts()
            self.scanning.insert(repo)
            self.queue.async {
                let overlaps = Self.scan(repo: repo, checkouts: list)
                DispatchQueue.main.async {
                    self.busy.remove(repo)
                    self.scanning.remove(repo)
                    self.onUpdate?(repo, overlaps)
                    if let next = self.again.removeValue(forKey: repo) { self.refresh(repo: repo, checkouts: next) }
                }
            }
        }
    }

    nonisolated static func scan(repo: String, checkouts: [Checkout]) -> [String: [Overlap]] {
        // Uncommitted work counts: it's what the agent has done so far.
        let snapshots: [(Checkout, String)] = checkouts.compactMap { checkout in
            guard FileManager.default.fileExists(atPath: checkout.path),
                  let commit = TurnTracker.snapshot(checkout.path, fixedDate: true) else { return nil }
            var checkout = checkout
            if checkout.branch.isEmpty {
                checkout.branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout.path).stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (checkout, commit)
        }
        var result: [String: [Overlap]] = [:]
        for i in snapshots.indices {
            for j in snapshots.indices where j > i {
                let (a, snapA) = snapshots[i], (b, snapB) = snapshots[j]
                // Two sessions in the main checkout share its files; only worktrees run apart.
                guard a.path != b.path, a.path != repo || b.path != repo else { continue }
                guard let (forA, forB) = compare(snapA, snapB, in: repo) else { continue }
                if !forA.isEmpty { result[a.path, default: []].append(Overlap(other: b.path, otherBranch: b.branch, files: forA)) }
                if !forB.isEmpty { result[b.path, default: []].append(Overlap(other: a.path, otherBranch: a.branch, files: forB)) }
            }
        }
        return result
    }

    /// The overlapping files as each side sees them: the line ranges listed are the other side's.
    nonisolated private static func compare(_ a: String, _ b: String, in repo: String) -> ([OverlapFile], [OverlapFile])? {
        let base = Shell.git(["merge-base", a, b], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let changedA = Set(Overlaps.paths(nameOnly: Shell.git(["diff", "--name-only", "-z", "--no-renames", base, a], in: repo).stdout))
        let changedB = Set(Overlaps.paths(nameOnly: Shell.git(["diff", "--name-only", "-z", "--no-renames", base, b], in: repo).stdout))
        let shared = changedA.intersection(changedB)
        guard !shared.isEmpty else { return ([], []) }
        // Merges in memory; neither checkout nor the repository's refs change. Exit 1 means conflicts.
        let merge = Shell.git(["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages", a, b], in: repo)
        let conflicted = merge.status == 1 ? Overlaps.conflictedPaths(mergeTree: merge.stdout) : []
        // Only the shared files' lines are shown; a long list stops at what anyone would read.
        let paths = Array(shared.sorted().prefix(200))
        let hunksA = hunks(base, a, paths, in: repo), hunksB = hunks(base, b, paths, in: repo)
        return (Overlaps.files(mine: changedA, theirs: changedB, theirHunks: hunksB, conflicted: conflicted),
                Overlaps.files(mine: changedB, theirs: changedA, theirHunks: hunksA, conflicted: conflicted))
    }

    nonisolated private static func hunks(_ base: String, _ commit: String, _ paths: [String], in repo: String) -> [String: [LineRange]] {
        let diff = Shell.git(["-c", "core.quotePath=false", "diff", "-U0", "--no-color", "--no-ext-diff", "--no-prefix",
                              "--no-renames", base, commit, "--"] + paths.map { ":(literal)" + $0 }, in: repo)
        return Overlaps.hunks(diff: diff.stdout)
    }
}
