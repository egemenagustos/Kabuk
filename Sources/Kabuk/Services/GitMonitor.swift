import Foundation
import KabukCore

/// Reads each pane's git branch and diff in the background, debounced per pane.
@MainActor
final class GitMonitor {
    var onUpdate: ((UUID, GitStatus?) -> Void)?
    private var pending: [UUID: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "kabuk.git", qos: .utility, attributes: .concurrent)

    func refresh(_ paneID: UUID, cwd: String, delay: TimeInterval = 0.3) {
        pending[paneID]?.cancel()
        let queue = queue
        let work = DispatchWorkItem { [weak self] in
            queue.async {
                let status = Self.read(cwd)
                DispatchQueue.main.async { self?.onUpdate?(paneID, status) }
            }
        }
        pending[paneID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated static func read(_ cwd: String) -> GitStatus? {
        guard let status = git(["status", "--porcelain=v2", "--branch"], in: cwd) else { return nil }
        // Fails in a repository without commits; then there is simply no diff to count.
        let numstat = git(["diff", "--numstat", "HEAD"], in: cwd) ?? ""
        return GitStatus.parse(status: status, numstat: numstat)
    }

    nonisolated private static func git(_ args: [String], in cwd: String) -> String? {
        let result = Shell.git(args, in: cwd)
        return result.ok ? result.stdout : nil
    }
}
