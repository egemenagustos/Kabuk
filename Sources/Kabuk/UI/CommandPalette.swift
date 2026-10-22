import KabukCore
import SwiftUI

/// ⌘K: jump to a session or run an action by typing a few letters.
struct CommandPalette: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let status: PaneStatus?
        /// Set for a skill, which ranks by its own name rather than the title and subtitle.
        var skill: Skill? = nil
        let run: () -> Void
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("Search sessions, run a command, or type / for skills…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onKeyPress(.escape) { state.togglePalette(); return .handled }
                    .onChange(of: query) { selected = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, active: index == selected)
                                .id(item.id)
                                .onTapGesture { selected = index; run(items) }
                                .onHover { if $0 { selected = index } }
                        }
                        if items.isEmpty {
                            Text("No results").font(.system(size: 13)).foregroundStyle(.white.opacity(0.4)).padding(20)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .onChange(of: selected) { _, new in
                    if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                }
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.07).opacity(0.7)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .onAppear {
            focused = true
            if let pane = state.selectedSession?.focusedPane { state.refreshSkills(for: pane) }
        }
    }

    private func row(_ item: Item, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20)
            Text(item.title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
            Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.38)).lineLimit(1)
            Spacer()
            if let status = item.status { StatusIcon(status: status, size: 12) }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(active ? 0.12 : 0)))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        let item = items[selected]
        state.togglePalette()
        DispatchQueue.main.async { item.run() }
    }

    private var filtered: [Item] {
        guard !query.isEmpty else { return sessionItems + actionItems }
        // "/" or "$" asks for skills only, the way Claude and Codex start them.
        let skillsOnly = query.hasPrefix("/") || query.hasPrefix("$")
        let search = skillsOnly ? String(query.dropFirst()) : query
        let all = skillsOnly ? skillItems : sessionItems + actionItems + skillItems
        return all
            .compactMap { item in
                let score = item.skill.map { $0.matchScore(search) } ?? FuzzyMatcher.score(search, in: item.title + " " + item.subtitle)
                return score.map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var sessionItems: [Item] {
        state.projects.flatMap { project in
            project.sessions.map { session in
                Item(id: session.id.uuidString, title: session.title, subtitle: project.name,
                     symbol: "rectangle.on.rectangle", status: state.summary(of: session).status) {
                    state.select(session.id)
                }
            }
        }
    }

    /// The focused agent's skills; choosing one types it at the agent's prompt.
    private var skillItems: [Item] {
        guard let pane = state.selectedSession?.focusedPane else { return [] }
        let s = state
        return s.skills(for: pane).map { skill in
            Item(id: "skill-" + skill.id, title: skill.insertion.trimmingCharacters(in: .whitespaces),
                 subtitle: [skill.scopeLabel, skill.description].filter { !$0.isEmpty }.joined(separator: " · "),
                 symbol: "book.closed", status: nil, skill: skill) { s.insertSkill(skill, into: pane) }
        }
    }

    private var actionItems: [Item] {
        let s = state
        var items = [
            Item(id: "new", title: "New Session", subtitle: "⌘T", symbol: "plus", status: nil) { s.newSession() },
            Item(id: "open", title: "Open Project…", subtitle: "⌘O", symbol: "folder", status: nil) { s.chooseProject() },
        ] + s.installedAgents.map { agent in
            Item(id: "wt-\(agent.rawValue)", title: "New \(agent.displayName) Worktree Session",
                 subtitle: agent == .claude ? "⌥⌘T" : "worktree", symbol: "square.stack.3d.down.right", status: nil) {
                s.newWorktreeSession(agent: agent)
            }
        } + [
            Item(id: "wt-shell", title: "New Worktree Shell", subtitle: "worktree", symbol: "square.stack.3d.down.right", status: nil) {
                s.newWorktreeSession(agent: nil)
            },
            Item(id: "split-h", title: "Split Right", subtitle: "⌘D", symbol: "rectangle.split.2x1", status: nil) { s.split(.horizontal) },
            Item(id: "split-v", title: "Split Down", subtitle: "⇧⌘D", symbol: "rectangle.split.1x2", status: nil) { s.split(.vertical) },
            Item(id: "close-pane", title: "Close Pane", subtitle: "⌘W", symbol: "xmark.square", status: nil) { s.closePane() },
            Item(id: "find", title: "Find in Pane", subtitle: "⌘F", symbol: "text.magnifyingglass", status: nil) { s.toggleFind() },
            Item(id: "history", title: "Search Command History", subtitle: "⌘R", symbol: "clock.arrow.circlepath", status: nil) { s.toggleHistory() },
            Item(id: "sidebar", title: "Toggle Sidebar", subtitle: "⌘\\", symbol: "sidebar.left", status: nil) { s.toggleSidebar() },
            Item(id: "themes", title: "Browse Themes…", subtitle: "⇧⌘T", symbol: "paintpalette", status: nil) { s.toggleThemeGallery() },
            Item(id: "backdrop", title: s.animatedBackground ? "Turn Off Animated Background" : "Turn On Animated Background",
                 subtitle: "Metal", symbol: "sparkles", status: nil) { s.toggleAnimatedBackground() },
            Item(id: "font-up", title: "Bigger Text", subtitle: "⌘+", symbol: "textformat.size.larger", status: nil) { s.fontSize = min(s.fontSize + 1, 28) },
            Item(id: "font-down", title: "Smaller Text", subtitle: "⌘-", symbol: "textformat.size.smaller", status: nil) { s.fontSize = max(s.fontSize - 1, 9) },
            Item(id: "install", title: "Install Agent Integrations", subtitle: "hooks", symbol: "bolt.horizontal", status: nil) {
                IntegrationUI.install(installed: s.installedAgents)
            },
            Item(id: "uninstall", title: "Remove Agent Integrations", subtitle: "hooks", symbol: "bolt.slash", status: nil) {
                IntegrationUI.uninstall()
            },
        ]
        if let update = s.availableUpdate {
            items.append(Item(id: "update-available", title: "Install Kabuk \(update.version)…", subtitle: "update",
                              symbol: "arrow.down.circle", status: nil) { s.showUpdate() })
        }
        items += [
            Item(id: "check-updates", title: "Check for Updates…", subtitle: Updater.currentVersion.map { "you have \($0)" } ?? "",
                 symbol: "arrow.triangle.2.circlepath", status: nil) { s.checkForUpdates(manual: true) },
            Item(id: "whats-new", title: "What's New in Kabuk", subtitle: "release notes", symbol: "sparkles", status: nil) {
                s.showWhatsNew()
            },
            Item(id: "update-checks", title: s.updateChecks ? "Turn Off Automatic Update Checks" : "Turn On Automatic Update Checks",
                 subtitle: "once a day, from GitHub", symbol: "arrow.down.circle.dotted", status: nil) { s.updateChecks.toggle() },
        ]
        items.append(Item(id: "subagent-worktrees",
                          title: s.subagentWorktrees ? "Turn Off Subagent Worktrees" : "Turn On Subagent Worktrees",
                          subtitle: "Claude subagents that edit get their own worktree", symbol: "square.stack.3d.down.right", status: nil) {
            s.subagentWorktrees.toggle()
        })
        if let session = s.selectedSession, let worktree = session.worktree {
            items.append(Item(id: "review-worktree", title: "Review & Merge Worktree…", subtitle: worktree.branch,
                              symbol: "arrow.triangle.merge", status: nil) { s.reviewWorktree(of: session.id) })
        }
        if let pane = s.selectedSession?.focusedPane, let change = s.turnChanges[pane], change.snapshot != nil {
            let undone = s.undoneTurns[pane] != nil
            items.append(Item(id: "undo-turn", title: undone ? "Redo Last Turn" : "Undo Last Turn",
                              subtitle: "\(change.files.count) file\(change.files.count == 1 ? "" : "s")",
                              symbol: undone ? "arrow.uturn.forward" : "arrow.uturn.backward", status: nil) {
                if undone { s.redoTurn(pane) } else { s.undoTurn(pane) }
            })
        }
        let symbols = ["circle.dotted", "circle.lefthalf.filled", "circle.fill"]
        items += WorkspaceSnapshot.transparencyLevels.enumerated().map { index, level in
            Item(id: "glass-\(index)", title: "Transparency: \(level.name)", subtitle: s.opacity == level.value ? "current" : "",
                 symbol: symbols[index], status: nil) {
                withAnimation(.easeInOut(duration: 0.3)) { s.opacity = level.value }
            }
        }
        items += s.themes.map { theme in
            Item(id: "theme-" + theme.id, title: "Theme: \(theme.name)", subtitle: theme.id == s.themeID ? "current" : "",
                 symbol: "paintbrush", status: nil) {
                withAnimation(.easeInOut(duration: 0.25)) { s.themeID = theme.id }
            }
        }
        return items
    }
}
