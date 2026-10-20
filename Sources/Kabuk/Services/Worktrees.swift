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
}
