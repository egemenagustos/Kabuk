import Foundation
import KabukCore

/// Creates and removes the git worktrees behind worktree sessions. Call off the main thread.
enum Worktrees {
    enum Failure: LocalizedError {
        case notARepository
        case git(String)

        var errorDescription: String? {
            switch self {
            case .notARepository: return "The current folder isn't inside a git repository."
            case .git(let message): return message.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// The main checkout's folder, also when `cwd` is inside one of its worktrees (where
    /// `--show-toplevel` would name the worktree itself).
    static func repoRoot(_ cwd: String) -> String? {
        let result = Shell.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: cwd)
        let commonDir = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !commonDir.isEmpty else { return nil }
        let url = URL(fileURLWithPath: commonDir)
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent().path : url.path
    }

    /// Branches from the HEAD of the folder the user is in, which may itself be a worktree.
    static func create(from cwd: String, agent: AgentKind?) -> Result<WorktreeInfo, Failure> {
        guard let repo = repoRoot(cwd) else { return .failure(.notARepository) }
        let base = Shell.git(["rev-parse", "HEAD"], in: cwd)
        guard base.ok else { return .failure(.git("The repository has no commits yet.")) }
        let name = WorktreeNaming.name(agent: agent)
        let branch = WorktreeNaming.branch(for: name)
        let path = WorktreeNaming.path(repoRoot: repo, name: name)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let added = Shell.git(["worktree", "add", "-b", branch, path, "HEAD"], in: cwd)
        guard added.ok else { return .failure(.git(added.stderr)) }
        return .success(WorktreeInfo(path: path, branch: branch, repoRoot: repo,
                                     baseRef: base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    static func isDirty(_ info: WorktreeInfo) -> Bool {
        let status = Shell.git(["status", "--porcelain"], in: info.path)
        return status.ok && !status.stdout.isEmpty
    }

    /// Removes the worktree folder. The branch stays, so committed work is never lost.
    static func remove(_ info: WorktreeInfo, force: Bool) -> Failure? {
        let result = Shell.git(["worktree", "remove"] + (force ? ["--force"] : []) + [info.path], in: info.repoRoot)
        return result.ok ? nil : .git(result.stderr)
    }

    /// Removes the worktree and, once its work is merged, the branch too.
    static func discard(_ info: WorktreeInfo) -> Failure? {
        if let failure = remove(info, force: true) { return failure }
        let deleted = Shell.git(["branch", "-D", info.branch], in: info.repoRoot)
        return deleted.ok ? nil : .git(deleted.stderr)
    }

    // MARK: Review and merge

    /// What the branch would bring into the main checkout's branch: its commits, and every
    /// change against the merge base, uncommitted ones included.
    static func summary(_ info: WorktreeInfo) -> Result<WorktreeSummary, Failure> {
        let head = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], in: info.repoRoot)
        let target = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.ok, !target.isEmpty, target != "HEAD" else {
            return .failure(.git("The main checkout isn't on a branch, so there's nothing to merge into."))
        }
        let base = Shell.git(["merge-base", "HEAD", target], in: info.path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return .failure(.git("\(info.branch) and \(target) share no history.")) }
        let log = Shell.git(["log", "--format=%h%x09%s", "\(target)..HEAD"], in: info.path)
        let numstat = Shell.git(["diff", "--numstat", "--no-renames", base], in: info.path)
        let change = TurnDiff.change(numstat: numstat.stdout, before: TurnBaseline(base: base, top: info.path, untracked: [:]),
                                     untrackedAfter: TurnTracker.untracked(info.path),
                                     lineCount: { TurnTracker.lineCount(URL(fileURLWithPath: info.path).appendingPathComponent($0)) })
        let dirty = !Shell.git(["status", "--porcelain"], in: info.path).stdout.isEmpty
        let targetDirty = !Shell.git(["status", "--porcelain", "--untracked-files=no"], in: info.repoRoot).stdout.isEmpty
        return .success(WorktreeSummary(target: target, commits: WorktreeReview.parseLog(log.stdout),
                                        change: change.files.isEmpty ? nil : change, dirty: dirty, targetDirty: targetDirty))
    }

    static func commitAll(_ info: WorktreeInfo, message: String) -> Failure? {
        let added = Shell.git(["add", "-A"], in: info.path)
        guard added.ok else { return .git(added.stderr) }
        let commit = Shell.git(["commit", "-q", "-m", message], in: info.path)
        return commit.ok ? nil : .git(commit.stderr.isEmpty ? commit.stdout : commit.stderr)
    }

    /// Merges the branch into the main checkout's branch. A merge that stops on conflicts is
    /// rolled back, so the main checkout is never left half-merged.
    static func merge(_ info: WorktreeInfo, summary: WorktreeSummary, squash: Bool) -> Failure? {
        if let blocker = summary.mergeBlocker { return .git(blocker) }
        let repo = info.repoRoot
        if squash {
            let merge = Shell.git(["merge", "--squash", info.branch], in: repo)
            guard merge.ok else {
                _ = Shell.git(["reset", "--merge"], in: repo)
                return .git(conflictMessage(merge))
            }
            let message = WorktreeReview.squashMessage(branch: info.branch, commits: summary.commits)
            let commit = Shell.git(["commit", "-q", "-m", message], in: repo)
            guard commit.ok else {
                _ = Shell.git(["reset", "--merge"], in: repo)
                return .git(commit.stderr.isEmpty ? commit.stdout : commit.stderr)
            }
            return nil
        }
        let merge = Shell.git(["merge", "--no-ff", "--no-edit", info.branch], in: repo)
        guard merge.ok else {
            _ = Shell.git(["merge", "--abort"], in: repo)
            return .git(conflictMessage(merge))
        }
        return nil
    }

    private static func conflictMessage(_ result: Shell.Result) -> String {
        let output = result.stdout + result.stderr
        guard output.contains("CONFLICT") else { return output }
        let files = output.split(separator: "\n").filter { $0.hasPrefix("CONFLICT") }.joined(separator: "\n")
        return "The merge has conflicts, so nothing was changed:\n\n\(files)\n\nAsk the agent to merge the target branch into its worktree and resolve them, then merge again."
    }
}
