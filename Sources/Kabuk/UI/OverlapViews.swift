import KabukCore
import SwiftUI

/// A session row's warning that another checkout changes the same files: amber while the
/// changes still merge cleanly, red once merging both would conflict. Click for the details.
struct OverlapBadge: View {
    @EnvironmentObject var state: AppState
    let session: Session
    let overlaps: [Overlap]

    var body: some View {
        let conflicts = overlaps.reduce(0) { $0 + $1.conflicts.count }
        let files = overlaps.reduce(0) { $0 + $1.files.count }
        Button { state.overlapDetail = state.overlapDetail == session.id ? nil : session.id } label: {
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .semibold))
                Text(verbatim: "\(conflicts > 0 ? conflicts : files)").font(.system(size: 10, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(conflicts > 0 ? Theme.failure : Theme.needsYou)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(conflicts > 0
              ? "Merging would conflict in \(conflicts) file\(conflicts == 1 ? "" : "s") with parallel work"
              : "\(files) file\(files == 1 ? "" : "s") also changed in parallel work")
        .popover(isPresented: Binding(get: { state.overlapDetail == session.id },
                                      set: { if !$0, state.overlapDetail == session.id { state.overlapDetail = nil } }),
                 arrowEdge: .trailing) {
            OverlapList(session: session, repo: state.radarRepo(of: session) ?? "", overlaps: overlaps) { state.overlapDetail = nil }
                .padding(12)
                .frame(width: 340)
        }
    }
}

/// Each other checkout that shares files with the session's, what it changes in them, and a
/// way to tell the session's agent.
struct OverlapList: View {
    @EnvironmentObject var state: AppState
    /// The session whose agent gets told; nil shows no button.
    let session: Session?
    let repo: String
    let overlaps: [Overlap]
    /// Off inside the review sheet, which is what it would open.
    var offersReview = true
    var done: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(overlaps) { overlap in
                entry(overlap)
            }
        }
    }

    private func entry(_ overlap: Overlap) -> some View {
        let other = state.worktreeSession(at: overlap.other)
        let agent = other.flatMap { state.agent(of: $0) }
        let conflicts = overlap.conflicts.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let agent {
                    Image(systemName: agent.profile.glyph).font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.color(for: agent))
                }
                Text(overlap.other == repo ? "Main checkout" : state.checkoutName(overlap.other, repo: repo))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(overlap.otherBranch)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 4)
            }
            Text(conflicts > 0
                 ? "Merging both would conflict in \(conflicts) file\(conflicts == 1 ? "" : "s")."
                 : "Changes the same files. They still merge cleanly.")
                .font(.system(size: 11))
                .foregroundStyle(conflicts > 0 ? Theme.failure : Theme.needsYou)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(overlap.files.prefix(8)) { file in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(file.conflict ? Theme.failure : Theme.needsYou).frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.path)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1).truncationMode(.head)
                            let lines = Overlaps.describe(file.theirLines)
                            if !lines.isEmpty {
                                Text("It \(lines)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                            }
                        }
                    }
                }
                if overlap.files.count > 8 {
                    Text("and \(overlap.files.count - 8) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            if let session {
                HStack(spacing: 6) {
                    if let mine = state.agent(of: session) {
                        Button("Tell \(mine.displayName)") {
                            state.tellAgent(about: overlap, in: session.id)
                            done()
                        }
                        .controlSize(.small)
                        .help("Send \(mine.displayName) the files and lines to keep clear of")
                    }
                    if offersReview, session.worktree != nil {
                        Button("Review & Merge…") {
                            done()
                            state.reviewWorktree(of: session.id)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
