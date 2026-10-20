import KabukCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(state.projects) { project in
                        ProjectSection(project: project, selection: selection)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            StatusBar()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Spacer()
            IconButton(symbol: "sidebar.left", help: "Hide sidebar (⌘\\)") { state.toggleSidebar() }
            IconButton(symbol: "plus", help: "New session (⌘T)") { state.newSession() }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }
}

private struct ProjectSection: View {
    @EnvironmentObject var state: AppState
    let project: Project
    let selection: Namespace.ID
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(project.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(verbatim: "\(project.sessions.count)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
                let waiting = state.needsYouCount(in: project)
                if waiting > 0 {
                    Text(verbatim: "\(waiting) needs you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.needsYou)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if hovering {
                    IconButton(symbol: "plus", size: 10, help: "New session in this project") {
                        state.newSession(in: project.id)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .frame(height: 22)
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.needsYouCount(in: project))
            .contextMenu {
                Button("New Session") { state.newSession(in: project.id) }
                Divider()
                Button("Remove Project", role: .destructive) { state.removeProject(project.id) }
            }
            .help(project.path)

            ForEach(project.sessions) { session in
                SessionRow(session: session, selection: selection)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)))
            }
        }
    }
}

private struct SessionRow: View {
    @EnvironmentObject var state: AppState
    let session: Session
    let selection: Namespace.ID
    @State private var hovering = false
    @State private var shakes: CGFloat = 0
    @State private var bounce = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        let summary = state.summary(of: session)
        let selected = state.selectedSessionID == session.id
        let emphasized = summary.unseen || summary.status.needsYou

        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
            if state.renamingSession == session.id {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($editing)
                    .onSubmit { state.rename(session.id, to: draft) }
                    .onExitCommand { state.renamingSession = nil }
                    .onAppear {
                        draft = session.title
                        editing = true
                    }
            } else {
                if session.worktree != nil {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 1.0))
                        .help("Runs in worktree \(session.worktree!.branch)")
                }
                Text(session.title)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(selected || emphasized ? 0.95 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            ActivityLabel(runtime: summary)
            StatusIcon(status: summary.status)
        }
            SessionDetail(runtime: summary)
            if let permission = summary.permission {
                PermissionCard(permission: permission)
                    .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.11))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08)))
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05))
                }
                if case .agentWorking(let agent, _) = summary.status {
                    Shimmer(color: Theme.color(for: agent))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(bounce ? 1.04 : 1, anchor: .leading)
        .modifier(ShakeEffect(trigger: shakes))
        .onTapGesture { state.select(session.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { state.renamingSession = session.id })
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onChange(of: summary.status) { old, new in
            if case .failed = new, old != new {
                withAnimation(.linear(duration: 0.45)) { shakes += 1 }
            }
            if new.needsYou && !old.needsYou {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.4)) { bounce = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { bounce = false }
                }
            }
        }
        .contextMenu {
            Button("Rename") { state.renamingSession = session.id }
            Divider()
            Button("Close Session", role: .destructive) { state.closeSession(session.id) }
        }
    }
}

/// "now", "3m", or a live timer while something runs.
private struct ActivityLabel: View {
    let runtime: PaneRuntime

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(now: context.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func text(now: Date) -> String {
        switch runtime.status {
        case .running(_, let start), .agentWorking(_, let start):
            return Self.duration(now.timeIntervalSince(start))
        default:
            let ago = now.timeIntervalSince(runtime.lastActivity)
            return ago < 60 ? "now" : Self.duration(ago)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5))
                .frame(width: size + 10, height: size + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Second line of a session row: the agent's working time and context size, then git.
private struct SessionDetail: View {
    let runtime: PaneRuntime

    var body: some View {
        let hasAgent = runtime.agent != nil && (runtime.turnStartedAt != nil || runtime.agentWorkTime > 0 || runtime.tokens != nil)
        if hasAgent || runtime.git != nil || !runtime.ports.isEmpty {
            HStack(spacing: 8) {
                if hasAgent, let agent = runtime.agent { AgentStats(runtime: runtime, agent: agent) }
                ForEach(runtime.ports.prefix(2), id: \.self) { PortChip(port: $0, compact: true) }
                if let git = runtime.git { GitBadge(git: git, compact: hasAgent || !runtime.ports.isEmpty) }
            }
            .font(.system(size: 10.5).monospacedDigit())
            .lineLimit(1)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// "✻ 3m 12s · 48k ctx", ticking while a turn is in progress.
struct AgentStats: View {
    @EnvironmentObject var state: AppState
    let runtime: PaneRuntime
    let agent: AgentKind

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Text("✻").fontWeight(.heavy)
                Text(Self.elapsed(runtime.agentTime(now: context.date)))
                if let tokens = runtime.tokens {
                    Text("·").opacity(0.5)
                    Text(verbatim: "\(TokenUsage.compact(tokens.context)) ctx")
                }
                if let cost = state.usage.cost(of: runtime.tokens) {
                    Text("·").opacity(0.5)
                    Text(Pricing.format(cost))
                }
            }
            .foregroundStyle(Theme.color(for: agent).opacity(0.8))
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let tokens = runtime.tokens else { return "\(agent.displayName) working time" }
        var text = "Context: \(tokens.context) tokens · Output: \(tokens.output) tokens"
        if let cost = state.usage.cost(of: tokens) {
            text += "\nSession cost ≈ \(Pricing.format(cost)) at API prices (not billed per token on a subscription)"
        }
        return text
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}

/// Branch name with the working tree's diff size.
struct GitBadge: View {
    let git: GitStatus
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            if !compact { Text(git.branch).lineLimit(1).truncationMode(.middle) }
            if git.ahead > 0 { Text(verbatim: "↑\(git.ahead)") }
            if git.behind > 0 { Text(verbatim: "↓\(git.behind)") }
            if git.added > 0 { Text(verbatim: "+\(git.added)").foregroundStyle(Theme.success.opacity(0.85)) }
            if git.removed > 0 { Text(verbatim: "−\(git.removed)").foregroundStyle(Theme.failure.opacity(0.85)) }
            if git.untracked > 0 { Text(verbatim: "?\(git.untracked)").foregroundStyle(Theme.needsYou.opacity(0.8)) }
        }
        .foregroundStyle(.white.opacity(0.45))
        .help("\(git.branch): \(git.changed) changed, \(git.untracked) untracked, +\(git.added) −\(git.removed)")
    }
}

/// A held Claude permission request, answerable from the sidebar.
private struct PermissionCard: View {
    @EnvironmentObject var state: AppState
    let permission: PermissionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield").font(.system(size: 10, weight: .semibold))
                Text(permission.tool).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.needsYou)
            if !permission.detail.isEmpty {
                Text(permission.detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(permission.detail)
            }
            HStack(spacing: 6) {
                answer("Allow", .allow, tint: Theme.success, prominent: true)
                if permission.canAlwaysAllow { answer("Always", .always, tint: Theme.success, prominent: false) }
                answer("Deny", .deny, tint: Theme.failure, prominent: false)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.needsYou.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.needsYou.opacity(0.25)))
        .padding(.top, 4)
    }

    private func answer(_ title: String, _ decision: PermissionDecision, tint: Color, prominent: Bool) -> some View {
        Button {
            state.answerPermission(permission.id, decision)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? .black.opacity(0.85) : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(prominent ? tint : tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help(decision == .always ? "Allow and remember this rule" : "")
    }
}

/// A port a pane's process listens on; click to open it in the browser.
struct PortChip: View {
    @EnvironmentObject var state: AppState
    let port: Int
    var compact = false
    @State private var hovering = false

    var body: some View {
        Button { state.openPort(port) } label: {
            HStack(spacing: 3) {
                Image(systemName: "network").font(.system(size: compact ? 8.5 : 9.5, weight: .semibold))
                Text(verbatim: ":\(port)").monospacedDigit()
            }
            .font(.system(size: compact ? 10.5 : 11, weight: .medium))
            .foregroundStyle(Theme.codex.opacity(hovering ? 1 : 0.85))
            .padding(.horizontal, compact ? 5 : 8)
            .padding(.vertical, compact ? 1 : 3)
            .background(Capsule().fill(Theme.codex.opacity(hovering ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open http://localhost:\(port)")
        .transition(.scale.combined(with: .opacity))
    }
}
