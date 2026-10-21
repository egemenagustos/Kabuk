import KabukCore
import SwiftUI

/// A worktree's branch before it goes into the main checkout: its commits and changed files,
/// then commit, merge, squash-merge or open a pull request.
struct WorktreeReviewSheet: View {
    @EnvironmentObject var state: AppState
    let request: WorktreeReviewRequest
    @State private var summary: WorktreeSummary?
    @State private var failure: String?
    @State private var working: String?
    @State private var merged: String?
    @State private var message = ""

    private static let violet = Color(red: 0.75, green: 0.65, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Group {
                if let merged {
                    mergedView(merged)
                } else if let summary {
                    content(summary)
                } else if let failure {
                    Text(failure).font(.system(size: 12)).foregroundStyle(Theme.failure)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if merged == nil, let summary {
                footer(summary)
            }
        }
        .frame(width: 640, height: 520)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .task(id: request) { await reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.down.right").foregroundStyle(Self.violet)
            Text(request.info.branch).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
            if let target = summary?.target {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                Text(target).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button("Done") { state.closeWorktreeReview() }
                // Escape closes a diff opened on top of this sheet first.
                .keyboardShortcut(state.diffRequest == nil ? .cancelAction : nil)
                .controlSize(.small)
        }
        .padding(14)
    }

    private func content(_ summary: WorktreeSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(summary.commits.isEmpty ? "No commits yet" : "\(summary.commits.count) commit\(summary.commits.count == 1 ? "" : "s")") {
                    ForEach(summary.commits) { commit in
                        HStack(spacing: 10) {
                            Text(commit.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(Self.violet.opacity(0.8))
                            Text(commit.subject).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                    }
                }
                if let change = summary.change {
                    section("\(change.files.count) file\(change.files.count == 1 ? "" : "s") changed", trailing: AnyView(DiffCounts(added: change.added, removed: change.removed))) {
                        ForEach(change.files) { file in
                            FileRow(file: file) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    state.diffRequest = DiffRequest(file: file, change: change, paneID: state.agentPane(of: request))
                                }
                            }
                        }
                    }
                }
                if summary.dirty {
                    commitBox(summary)
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                trailing
            }
            .padding(.horizontal, 8)
            content()
        }
    }

    private func commitBox(_ summary: WorktreeSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Uncommitted changes", systemImage: "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.needsYou)
            HStack(spacing: 8) {
                TextField(WorktreeReview.defaultCommitMessage(summary.change), text: $message)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commit(summary) }
                Button("Commit All") { commit(summary) }
                    .controlSize(.small)
                    .disabled(working != nil)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.needsYou.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.needsYou.opacity(0.2)))
    }

    private func footer(_ summary: WorktreeSummary) -> some View {
        HStack(spacing: 8) {
            if let working {
                ProgressView().controlSize(.mini)
                Text(working).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            } else if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(Theme.failure).lineLimit(3)
                    .help(failure)
            } else if let blocker = summary.mergeBlocker {
                Text(blocker).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Open PR") { state.openPullRequest(request) }
                .controlSize(.small)
                .disabled(working != nil || summary.commits.isEmpty)
                .help("Push \(request.info.branch) and open a pull request with gh")
            Button("Merge") { merge(summary, squash: false) }
                .controlSize(.small)
                .disabled(working != nil || summary.mergeBlocker != nil)
                .help("Merge with a merge commit, keeping every commit")
            Button("Squash & Merge") { merge(summary, squash: true) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(working != nil || summary.mergeBlocker != nil)
                .help("Put the branch's changes into \(summary.target) as one commit")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private func mergedView(_ target: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.success)
            Text("Merged into \(target)").font(.system(size: 15, weight: .semibold))
            Text("The worktree and \(request.info.branch) aren't needed any more.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 10) {
                Button("Keep Them") { state.closeWorktreeReview() }.controlSize(.regular)
                Button(request.sessionID == nil ? "Remove Worktree and Branch" : "Close Session, Remove Worktree and Branch") {
                    state.discardWorktree(request)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func reload() async {
        let info = request.info
        let result = await Task.detached { Worktrees.summary(info) }.value
        switch result {
        case .success(let value): summary = value
        case .failure(let error): failure = error.localizedDescription
        }
    }

    private func commit(_ summary: WorktreeSummary) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let commitMessage = text.isEmpty ? WorktreeReview.defaultCommitMessage(summary.change) : text
        run("Committing…") { [info = request.info] in Worktrees.commitAll(info, message: commitMessage) } then: {
            message = ""
        }
    }

    private func merge(_ summary: WorktreeSummary, squash: Bool) {
        run(squash ? "Squash-merging…" : "Merging…") { [info = request.info] in
            Worktrees.merge(info, summary: summary, squash: squash)
        } then: {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { merged = summary.target }
        }
    }

    private func run(_ label: String, _ work: @escaping @Sendable () -> Worktrees.Failure?, then: @escaping () -> Void) {
        working = label
        failure = nil
        Task {
            let result = await Task.detached(operation: work).value
            working = nil
            if let result {
                failure = result.localizedDescription
            } else {
                then()
            }
            await reload()
        }
    }
}
