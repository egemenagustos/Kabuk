import KabukCore
import SwiftUI

private let violet = Color(red: 0.75, green: 0.65, blue: 1.0)

/// The glyph for a subagent: Claude's spinner while it works, a check when it's done.
struct SubagentStatus: View {
    let subagent: Subagent
    var size: CGFloat = 11

    var body: some View {
        StatusIcon(status: subagent.state == .working ? .agentWorking(.claude, since: subagent.startedAt)
                                                      : .succeeded(finishedAt: subagent.finishedAt ?? subagent.startedAt),
                   size: size)
    }
}

/// "12s" ticking while the subagent works, frozen once it's done.
struct SubagentTime: View {
    let subagent: Subagent

    var body: some View {
        if subagent.state == .working {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(AgentStats.elapsed(subagent.elapsed(now: context.date)))
            }
        } else {
            Text(AgentStats.elapsed(subagent.elapsed()))
        }
    }
}

struct BranchBadge: View {
    let branch: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.3d.down.right").font(.system(size: 8.5, weight: .semibold))
            Text(branch).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(violet.opacity(0.9))
        .help("Works in its own worktree on \(branch)")
    }
}

/// A subagent under its session in the sidebar.
struct SubagentRow: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let subagent: Subagent
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                SubagentStatus(subagent: subagent)
                Text(subagent.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(subagent.state == .working ? 0.85 : 0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                SubagentTime(subagent: subagent)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.35))
            }
            HStack(spacing: 6) {
                Text(subagent.type)
                if subagent.toolCount > 0 { Text(verbatim: "· \(subagent.toolCount) tool\(subagent.toolCount == 1 ? "" : "s")") }
                if let branch = subagent.branch { BranchBadge(branch: branch) }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(1)
            .padding(.leading, 17)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { state.showSubagent(subagent.id, in: paneID) }
        .onHover { hovering = $0 }
        .help(subagent.summary ?? subagent.description)
    }
}

/// Chips along the bottom of a pane for the main agent's subagents and child sessions.
struct SubagentStrip: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let subagents: [Subagent]
    let children: [Session]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                ForEach(subagents) { subagent in
                    chip(action: { state.showSubagent(subagent.id, in: paneID) }) {
                        SubagentStatus(subagent: subagent, size: 10)
                        Text(subagent.title).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                        SubagentTime(subagent: subagent).foregroundStyle(.white.opacity(0.4))
                        if subagent.branch != nil {
                            Image(systemName: "square.stack.3d.down.right").font(.system(size: 9)).foregroundStyle(violet)
                        }
                    }
                    .help(subagent.summary ?? "\(subagent.type): \(subagent.description)")
                }
                ForEach(children) { child in
                    let summary = state.summary(of: child)
                    chip(action: { state.select(child.id) }) {
                        StatusIcon(status: summary.status, size: 10)
                        Text(child.title).lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                        if let agent = summary.agent {
                            Text(agent.displayName).foregroundStyle(Theme.color(for: agent).opacity(0.8))
                        }
                        Image(systemName: "square.stack.3d.down.right").font(.system(size: 9)).foregroundStyle(violet)
                    }
                    .help("Open \(child.title)")
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.never)
        .frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private func chip<Content: View>(action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { content() }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.07)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// A subagent's live view: what it was asked, its latest steps, and its worktree.
struct SubagentSheet: View {
    @EnvironmentObject var state: AppState
    let request: SubagentDetailRequest
    @State private var steps: [TranscriptStep] = []

    var body: some View {
        let subagent = state.subagent(request)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let subagent { SubagentStatus(subagent: subagent, size: 13) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(subagent?.title ?? "Subagent").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(subagent?.type ?? "")
                        if let subagent { SubagentTime(subagent: subagent) }
                        if let count = subagent?.toolCount, count > 0 { Text(verbatim: "· \(count) tool\(count == 1 ? "" : "s")") }
                        if let branch = subagent?.branch { BranchBadge(branch: branch) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button("Done") { state.closeSubagentDetail() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(14)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if steps.isEmpty {
                            Text(subagent?.transcript == nil ? "Kabuk hasn't seen this subagent's transcript." : "No steps yet.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)).padding(.vertical, 20)
                        }
                        ForEach(steps) { step in
                            StepRow(step: step).id(step.id)
                        }
                        if let summary = subagent?.summary {
                            Label(summary, systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.success)
                                .padding(.top, 6)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: steps.count) { _, _ in
                    if let last = steps.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let subagent, subagent.branch != nil {
                HStack(spacing: 8) {
                    Text(subagent.cwd.map(PaneContainer.abbreviate) ?? "")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Open Shell Here") {
                        if let cwd = subagent.cwd {
                            state.closeSubagentDetail()
                            state.split(.vertical, from: request.paneID, command: "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'")
                        }
                    }
                    .controlSize(.small)
                    Button("Review & Merge…") { state.reviewSubagentWorktree(subagent) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(subagent.state == .working)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Color.white.opacity(0.04))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
            }
        }
        .frame(width: 680, height: 520)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .task(id: request.subagentID) { await follow() }
    }

    /// Re-reads the transcript every second while the sheet is open.
    private func follow() async {
        while !Task.isCancelled {
            if let path = state.subagent(request)?.transcript {
                let read = await Task.detached { () -> [TranscriptStep]? in
                    guard let data = FileManager.default.contents(atPath: path) else { return nil }
                    return SubagentTranscript.steps(data)
                }.value
                if let read, read != steps { steps = read }
            }
            if state.subagent(request)?.state == .done && !steps.isEmpty { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private struct StepRow: View {
    let step: TranscriptStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(step.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(step.kind == .tool ? Theme.running : Theme.claude)
                .frame(width: 70, alignment: .trailing)
            Text(step.detail)
                .font(.system(size: 12, design: step.kind == .tool ? .monospaced : .default))
                .foregroundStyle(.white.opacity(step.kind == .tool ? 0.7 : 0.88))
                .lineLimit(step.kind == .tool ? 2 : 6)
                .textSelection(.enabled)
        }
    }
}
