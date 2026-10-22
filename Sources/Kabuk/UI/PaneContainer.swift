import KabukCore
import SwiftUI

/// One terminal card: header with command, folder and tag, and a border that reacts to status.
struct PaneContainer: View {
    @EnvironmentObject var state: AppState
    let pane: Pane
    let isFocused: Bool
    let showsChrome: Bool
    var worktree: WorktreeInfo?

    var body: some View {
        let runtime = state.runtime(pane)
        VStack(spacing: 0) {
            header(runtime)
            TerminalPaneView(paneID: pane.id, cwd: pane.cwd,
                             isFocused: isFocused && !state.paletteVisible && !state.themeGalleryVisible && state.findPane == nil
                                && state.diffRequest == nil && !state.historyVisible && state.worktreeReview == nil
                                && state.subagentDetail == nil && state.updateSheet == nil && state.skillPickerPane == nil)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            let children = state.childSessions(of: pane.id)
            if !runtime.subagents.isEmpty || !children.isEmpty {
                SubagentStrip(paneID: pane.id, subagents: runtime.subagents, children: children)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: runtime.subagents.map(\.id))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.color(state.theme.background).opacity(state.opacity))
        )
        .overlay(alignment: .bottomLeading) {
            if let failure = state.failures[pane.id] {
                FailureChip(paneID: pane.id, failure: failure)
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let change = state.turnChanges[pane.id], state.expandedTurnCards.contains(pane.id) {
                TurnCard(paneID: pane.id, change: change)
                    .padding(14)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.findPane == pane.id {
                FindBar()
                    .padding(.top, 40)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(StatusBorder(status: runtime.status, focused: isFocused))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(isFocused ? 0.35 : 0.15), radius: isFocused ? 18 : 8, y: 6)
        .opacity(isFocused || !showsChrome ? 1 : 0.82)
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }

    private func header(_ runtime: PaneRuntime) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            // When space runs out the folder shrinks first, then the title; the branch stays.
            Text(title(runtime))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .layoutPriority(1)
            Text(Self.abbreviate(runtime.cwd))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
                .truncationMode(.head)
            if let git = runtime.git {
                GitBadge(git: git)
                    .font(.system(size: 11).monospacedDigit())
                    .fixedSize()
                    .layoutPriority(2)
            }
            Spacer(minLength: 8)
            if let agent = runtime.agent, runtime.turnStartedAt != nil || runtime.tokens != nil {
                AgentStats(runtime: runtime, agent: agent)
                    .font(.system(size: 11).monospacedDigit())
                    .fixedSize()
            }
            ForEach(runtime.ports.prefix(3), id: \.self) { PortChip(port: $0).fixedSize() }
            if let change = state.turnChanges[pane.id], !state.expandedTurnCards.contains(pane.id) {
                TurnChip(paneID: pane.id, change: change)
                    .fixedSize()
                    .transition(.scale.combined(with: .opacity))
            }
            if let worktree {
                WorktreeChip(worktree: worktree).fixedSize()
            }
            if let agent = runtime.agent, agent.profile.skillPrefix != nil {
                SkillsButton(paneID: pane.id, agent: agent)
            }
            TagChip(tag: runtime.tag, agent: runtime.agent)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func title(_ runtime: PaneRuntime) -> String {
        switch runtime.status {
        case .running(let cmd, _): return cmd
        case .agentWorking(let agent, _), .agentReady(let agent): return runtime.lastPrompt.map { "\(agent.displayName) · \($0)" } ?? agent.displayName
        case .agentNeedsYou(let agent, let message): return message ?? "\(agent.displayName) needs you"
        default: return runtime.agent.map(\.displayName) ?? runtime.command ?? "zsh"
        }
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct WorktreeChip: View {
    let worktree: WorktreeInfo

    var body: some View {
        Label(worktree.name, systemImage: "square.stack.3d.down.right")
            .font(.system(size: 10.5, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(red: 0.75, green: 0.65, blue: 1.0))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color(red: 0.75, green: 0.65, blue: 1.0).opacity(0.13)))
            .help("Worktree \(worktree.branch)\n\(PaneContainer.abbreviate(worktree.path))")
    }
}

private struct TagChip: View {
    let tag: String
    let agent: AgentKind?

    var body: some View {
        Text(tag)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(agent.map { Theme.color(for: $0) } ?? .white.opacity(0.6))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill((agent.map { Theme.color(for: $0) } ?? .white).opacity(0.12)))
            .contentTransition(.interpolate)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tag)
    }
}

/// Glowing card edge. Agents get a rotating gradient, waiting gets a pulse,
/// finished commands flash once.
private struct StatusBorder: View {
    let status: PaneStatus
    let focused: Bool
    @State private var flash: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.white.opacity(focused ? 0.16 : 0.07), lineWidth: 1)

            switch status {
            case .agentWorking(let agent, _):
                SweepingBorder(color: Theme.color(for: agent))
                    .transition(.opacity)
            case .agentNeedsYou:
                BreathingBorder(color: Theme.needsYou)
                    .transition(.opacity)
            case .running:
                shape.strokeBorder(Theme.running.opacity(0.35), lineWidth: 1)
                    .transition(.opacity)
            default:
                EmptyView()
            }

            if let flash {
                shape.strokeBorder(flash, lineWidth: 2).transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.3), value: status.priority)
        .onChange(of: status) { _, new in
            switch new {
            case .succeeded: flash(Theme.success)
            case .failed: flash(Theme.failure)
            default: break
            }
        }
    }

    private func flash(_ color: Color) {
        withAnimation(.easeOut(duration: 0.15)) { flash = color }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 1.1)) { flash = nil }
        }
    }
}

/// ⌘F inside a pane: live match count, return / shift-return to step, escape to close.
private struct FindBar: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Find", text: $state.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 170)
                .focused($focused)
                .onSubmit { state.findStep(forward: true) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    state.findStep(forward: false)
                    return .handled
                }
                .onKeyPress(.escape) {
                    state.closeFind()
                    return .handled
                }
                .onChange(of: state.findQuery) { state.updateFind() }
            Text(countText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(state.findSummary.total == 0 && !state.findQuery.isEmpty ? 0.35 : 0.55))
                .contentTransition(.numericText())
            IconButton(symbol: "chevron.up", size: 10, help: "Previous (⇧⌘G)") { state.findStep(forward: false) }
            IconButton(symbol: "chevron.down", size: 10, help: "Next (⌘G)") { state.findStep(forward: true) }
            IconButton(symbol: "xmark", size: 10, help: "Close (Esc)") { state.closeFind() }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(Capsule().fill(Color(white: 0.08).opacity(0.75)))
        .glass(in: Capsule(), tint: .black.opacity(0.3))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .focusOnAppear($focused)
    }

    private var countText: String {
        if state.findQuery.isEmpty { return "" }
        let s = state.findSummary
        return s.total == 0 ? "No matches" : "\(s.index)/\(s.total)"
    }
}

/// Offers to send a failed command and its output to an agent.
private struct FailureChip: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let failure: CommandFailure

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.failure)
            Text(verbatim: "exit \(failure.code)")
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            ask("Ask Claude", .claude)
            ask("Codex", .codex)
            let others = state.installedAgents.filter { $0 != .claude && $0 != .codex }
            if !others.isEmpty {
                Menu {
                    ForEach(others, id: \.self) { agent in
                        Button("Ask \(agent.displayName)") { state.askAgent(about: paneID, agent: agent) }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Ask another agent")
            }
            IconButton(symbol: "xmark", size: 9, help: "Dismiss") { state.dismissFailure(paneID) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 34)
        .background(Capsule().fill(Color(white: 0.08).opacity(0.85)))
        .glass(in: Capsule(), tint: .black.opacity(0.3))
        .overlay(Capsule().strokeBorder(Theme.failure.opacity(0.35)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .help(failure.output.isEmpty ? failure.command : String(failure.output.suffix(600)))
    }

    private func ask(_ title: String, _ agent: AgentKind) -> some View {
        Button { state.askAgent(about: paneID, agent: agent) } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.color(for: agent))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.color(for: agent).opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}
