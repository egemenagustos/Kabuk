import AppKit
import Combine
import KabukCore
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project]
    @Published var selectedSessionID: UUID?
    @Published var sidebarVisible: Bool
    @Published var opacity: Double { didSet { scheduleSave() } }
    @Published var fontSize: Double {
        didSet {
            terminals.fontSize = fontSize
            scheduleSave()
        }
    }
    @Published var themeID: String {
        didSet {
            terminals.theme = theme
            scheduleSave()
        }
    }
    @Published var animatedBackground: Bool { didSet { scheduleSave() } }
    @Published private(set) var themes: [TerminalTheme] = TerminalTheme.builtIn
    @Published var paletteVisible = false
    @Published var themeGalleryVisible = false
    @Published var renamingSession: UUID?
    @Published private(set) var runtimes: [UUID: PaneRuntime] = [:]
    @Published private(set) var appActive = true

    /// The pane whose find bar is open.
    @Published var findPane: UUID?
    @Published var findQuery = ""
    @Published private(set) var findSummary: (index: Int, total: Int) = (0, 0)

    let terminals = TerminalRegistry()
    let notifier = Notifier()
    let git = GitMonitor()
    let turns = TurnTracker()
    let usage = UsageLedger()
    let history = HistoryStore()
    let ports = PortMonitor()
    /// The last failed command in each pane, for "Ask Claude".
    @Published private(set) var failures: [UUID: CommandFailure] = [:]
    /// A failure arrives in two halves, in either order: the output read back from the terminal
    /// and the shell's end event over the socket. It shows once both are in.
    private var capturedOutput: [UUID: CapturedFailure] = [:]
    private var failedCommand: [UUID: (command: String, cwd: String)] = [:]
    @Published var historyVisible = false
    /// What each pane's agent changed in its last turn.
    @Published private(set) var turnChanges: [UUID: TurnChange] = [:]
    /// Panes whose turn summary card is open rather than folded into the header.
    @Published var expandedTurnCards: Set<UUID> = []
    /// The file whose turn diff is on screen.
    @Published var diffRequest: DiffRequest?
    /// The demo's caption strip, shown only when Kabuk runs with KABUK_DEMO.
    @Published var demoCaption: DemoCaption?
    static let isDemo = ProcessInfo.processInfo.environment["KABUK_DEMO"] != nil
    /// Open connections from `kabuk-hook`, waiting for a permission answer, by request id.
    private var permissionReplies: [String: SocketServer.Reply] = [:]
    /// Commands to type into a pane once its shell shows the first prompt.
    private var pendingCommands: [UUID: String] = [:]
    private var saveWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    /// Long commands that finish off screen are worth a notification; quick ones are not.
    static let longCommand: TimeInterval = 10

    init(snapshot: WorkspaceSnapshot?) {
        let home = NSHomeDirectory()
        var snapshot = snapshot ?? WorkspaceSnapshot(projects: [], selectedSession: nil)
        if snapshot.projects.allSatisfy({ $0.sessions.isEmpty }) {
            let session = Session(cwd: home)
            snapshot.projects = [Project(name: "Home", path: home, sessions: [session])]
            snapshot.selectedSession = session.id
        }
        // Early builds named the default project in Turkish.
        for i in snapshot.projects.indices where snapshot.projects[i].name == "Ana Dizin" {
            snapshot.projects[i].name = "Home"
        }
        projects = snapshot.projects
        selectedSessionID = snapshot.selectedSession ?? snapshot.projects.first?.sessions.first?.id
        sidebarVisible = snapshot.sidebarVisible
        opacity = snapshot.opacity
        fontSize = snapshot.fontSize
        themeID = snapshot.themeID
        animatedBackground = snapshot.animatedBackground
        terminals.fontSize = snapshot.fontSize
        reloadThemes()
        terminals.theme = theme

        git.onUpdate = { [weak self] id, status in self?.setGit(status, for: id) }
        turns.onChange = { [weak self] id, change in self?.turnFinished(id, change) }
        terminals.onCommandStart = { [weak self] id in self?.commandStarted(id) }
        terminals.onFailure = { [weak self] id, failure in self?.commandFailed(id, failure) }
        ports.shells = { [weak self] in self?.terminals.shellPIDs ?? [:] }
        ports.shouldScan = { [weak self] in
            // Something is running (a server, an agent that may start one) or a port is still shown.
            self?.runtimes.values.contains { $0.status.isBusy || $0.agent != nil || !$0.ports.isEmpty } ?? false
        }
        ports.onUpdate = { [weak self] result in self?.setPorts(result) }
        ports.start()

        terminals.onSubmit = { [weak self] in self?.paneSubmitted($0) }
        terminals.onExit = { [weak self] in self?.closePane($0) }
        notifier.onOpenSession = { [weak self] id in
            NSApp.activate(ignoringOtherApps: true)
            self?.select(id)
        }
        notifier.onPermissionAnswer = { [weak self] request, decision in
            self?.answerPermission(request, decision)
        }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appActive = true
                self?.markVisibleSeen()
                self?.refreshGitForSelection()
                self?.releaseVisiblePermissions()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = false }
        })
    }

    // MARK: Lookups

    var selectedSession: Session? {
        guard let id = selectedSessionID, let loc = location(of: id) else { return nil }
        return projects[loc.project].sessions[loc.session]
    }

    var allSessions: [Session] { projects.flatMap(\.sessions) }

    func location(of sessionID: UUID) -> (project: Int, session: Int)? {
        for (p, project) in projects.enumerated() {
            if let s = project.sessions.firstIndex(where: { $0.id == sessionID }) { return (p, s) }
        }
        return nil
    }

    func session(containing paneID: UUID) -> Session? {
        allSessions.first { $0.root.contains(paneID) }
    }

    func project(of sessionID: UUID) -> Project? {
        location(of: sessionID).map { projects[$0.project] }
    }

    func runtime(_ pane: Pane) -> PaneRuntime {
        runtimes[pane.id] ?? PaneRuntime(cwd: pane.cwd)
    }

    /// The most important pane of a session, which the sidebar shows.
    func summary(of session: Session) -> PaneRuntime {
        let all = session.root.panes.map(runtime)
        let focused = session.root.panes.first { $0.id == session.focusedPane }.map(runtime)
        let top = all.max { $0.status.priority < $1.status.priority }
        if let focused, let top, focused.status.priority == top.status.priority { return focused }
        var result = top ?? PaneRuntime(cwd: NSHomeDirectory())
        result.unseen = all.contains { $0.unseen }
        return result
    }

    var needsYouCount: Int { runtimes.values.filter { $0.status.needsYou }.count }
    var busyCount: Int { runtimes.values.filter { $0.status.isBusy }.count }
    var unseenCount: Int { runtimes.values.filter { $0.unseen }.count }

    func needsYouCount(in project: Project) -> Int {
        project.sessions.flatMap { $0.root.panes }.filter { runtime($0).status.needsYou }.count
    }

    private func isVisible(_ paneID: UUID) -> Bool {
        appActive && (selectedSession?.root.contains(paneID) ?? false)
    }

    // MARK: Sessions

    func newSession(in projectID: UUID? = nil, cwd: String? = nil) {
        let index = projectID.flatMap { id in projects.firstIndex { $0.id == id } }
            ?? selectedSessionID.flatMap { location(of: $0)?.project }
            ?? 0
        guard projects.indices.contains(index) else { return }
        let session = Session(cwd: cwd ?? projects[index].path)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            projects[index].sessions.append(session)
            selectedSessionID = session.id
        }
        scheduleSave()
    }

    func select(_ sessionID: UUID) {
        guard location(of: sessionID) != nil, selectedSessionID != sessionID else { return }
        withAnimation(.easeInOut(duration: 0.18)) { selectedSessionID = sessionID }
        markVisibleSeen()
        refreshGitForSelection()
        releaseVisiblePermissions()
        scheduleSave()
    }

    func selectSession(at index: Int) {
        let sessions = allSessions
        guard sessions.indices.contains(index) else { return }
        select(sessions[index].id)
    }

    func cycleSession(_ offset: Int) {
        let sessions = allSessions
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == selectedSessionID } ?? 0
        let next = (current + offset + sessions.count) % sessions.count
        select(sessions[next].id)
    }

    /// Closes a session, first asking what to do with its worktree if it has one.
    func closeSession(_ sessionID: UUID) {
        guard let loc = location(of: sessionID) else { return }
        guard let worktree = projects[loc.project].sessions[loc.session].worktree else {
            removeSession(sessionID)
            return
        }
        switch confirmWorktreeClose(worktree) {
        case .cancel:
            return
        case .keep:
            removeSession(sessionID)
        case .remove(let force):
            removeSession(sessionID)
            DispatchQueue.global(qos: .userInitiated).async {
                let failure = Worktrees.remove(worktree, force: force)
                DispatchQueue.main.async {
                    if let failure { Self.alert("Couldn't remove the worktree", failure.localizedDescription) }
                }
            }
        }
    }

    private enum WorktreeCloseChoice { case remove(force: Bool), keep, cancel }

    private func confirmWorktreeClose(_ worktree: WorktreeInfo) -> WorktreeCloseChoice {
        let dirty = Worktrees.isDirty(worktree)
        let alert = NSAlert()
        alert.messageText = "Remove the worktree \(worktree.name)?"
        alert.informativeText = (dirty
            ? "It has uncommitted changes that will be lost if you remove it.\n\n"
            : "") + "\(PaneContainer.abbreviate(worktree.path))\nThe branch \(worktree.branch) is kept either way."
        alert.addButton(withTitle: dirty ? "Remove Anyway" : "Remove Worktree")
        alert.addButton(withTitle: "Keep Worktree")
        alert.addButton(withTitle: "Cancel")
        if dirty { alert.alertStyle = .warning }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .remove(force: dirty)
        case .alertSecondButtonReturn: return .keep
        default: return .cancel
        }
    }

    private func removeSession(_ sessionID: UUID) {
        guard let loc = location(of: sessionID) else { return }
        let session = projects[loc.project].sessions[loc.session]
        for pane in session.root.panes {
            terminals.close(pane.id)
            runtimes[pane.id] = nil
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            projects[loc.project].sessions.remove(at: loc.session)
            if selectedSessionID == sessionID {
                let remaining = projects[loc.project].sessions
                selectedSessionID = remaining.indices.contains(loc.session) ? remaining[loc.session].id
                    : remaining.last?.id ?? allSessions.first?.id
            }
        }
        if allSessions.isEmpty { newSession(in: projects[loc.project].id) }
        updateBadge()
        scheduleSave()
    }

    /// Opens a session in a fresh git worktree of the focused pane's repository and, for an
    /// agent, starts it there.
    func newWorktreeSession(agent: AgentKind?) {
        let cwd = selectedSession.flatMap { s in s.root.panes.first { $0.id == s.focusedPane } }.map { runtime($0).cwd }
            ?? NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Worktrees.create(from: cwd, agent: agent)
            DispatchQueue.main.async {
                switch result {
                case .failure(let failure):
                    Self.alert("Couldn't create a worktree", failure.localizedDescription)
                case .success(let info):
                    self?.addWorktreeSession(info, agent: agent)
                }
            }
        }
    }

    private func addWorktreeSession(_ info: WorktreeInfo, agent: AgentKind?) {
        let projectIndex = projects.firstIndex { $0.path == info.repoRoot } ?? {
            projects.append(Project(name: (info.repoRoot as NSString).lastPathComponent, path: info.repoRoot))
            return projects.count - 1
        }()
        let session = Session(title: info.name, cwd: info.path, worktree: info)
        if let agent { pendingCommands[session.focusedPane] = agent.rawValue }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            projects[projectIndex].sessions.append(session)
            selectedSessionID = session.id
        }
        scheduleSave()
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func rename(_ sessionID: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        updateSession(sessionID) { session in
            if trimmed.isEmpty {
                session.autoTitle = true
            } else {
                session.title = trimmed
                session.autoTitle = false
            }
        }
        renamingSession = nil
    }

    private func updateSession(_ sessionID: UUID, _ update: (inout Session) -> Void) {
        guard let loc = location(of: sessionID) else { return }
        update(&projects[loc.project].sessions[loc.session])
        scheduleSave()
    }

    // MARK: Projects

    func openProject(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.path == path }) {
            if let first = existing.sessions.first { select(first.id) } else { newSession(in: existing.id) }
            return
        }
        let session = Session(cwd: path)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            projects.append(Project(name: url.lastPathComponent, path: path, sessions: [session]))
            selectedSessionID = session.id
        }
        scheduleSave()
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    func removeProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        for pane in project.sessions.flatMap({ $0.root.panes }) {
            terminals.close(pane.id)
            runtimes[pane.id] = nil
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            projects.removeAll { $0.id == projectID }
        }
        if projects.isEmpty { projects = [Project(name: "Home", path: NSHomeDirectory())] }
        if allSessions.isEmpty {
            newSession(in: projects[0].id)
        } else if selectedSession == nil {
            selectedSessionID = allSessions.first?.id
        }
        updateBadge()
        scheduleSave()
    }

    // MARK: Panes

    /// Splits the focused pane (or `paneID`), optionally running `command` in the new one.
    func split(_ axis: SplitAxis, from paneID: UUID? = nil, command: String? = nil) {
        guard let session = paneID.flatMap({ session(containing: $0) }) ?? selectedSession else { return }
        let focused = paneID ?? session.focusedPane
        let cwd = runtimes[focused]?.cwd ?? session.root.panes.first { $0.id == focused }?.cwd ?? NSHomeDirectory()
        let pane = Pane(cwd: cwd)
        if let command { pendingCommands[pane.id] = command }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            updateSession(session.id) {
                $0.root = $0.root.splitting(focused, axis: axis, newPane: pane)
                $0.focusedPane = pane.id
            }
        }
    }

    func closePane(_ paneID: UUID? = nil) {
        guard let paneID = paneID ?? selectedSession?.focusedPane,
              let session = session(containing: paneID) else { return }
        guard let root = session.root.removing(paneID) else {
            closeSession(session.id)
            return
        }
        terminals.close(paneID)
        runtimes[paneID] = nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            updateSession(session.id) {
                let index = $0.root.paneIDs.firstIndex(of: paneID) ?? 0
                $0.root = root
                if $0.focusedPane == paneID {
                    let ids = root.paneIDs
                    $0.focusedPane = ids[min(max(index - 1, 0), ids.count - 1)]
                }
            }
        }
        updateBadge()
    }

    func focus(_ direction: FocusDirection) {
        guard let session = selectedSession,
              let target = session.root.neighbor(of: session.focusedPane, direction) else { return }
        updateSession(session.id) { $0.focusedPane = target }
    }

    func setFractions(session sessionID: UUID, split splitID: UUID, _ fractions: [Double]) {
        updateSession(sessionID) { $0.root = $0.root.settingFractions(splitID, fractions) }
    }

    func paneFocused(_ paneID: UUID) {
        guard let session = session(containing: paneID), session.focusedPane != paneID else { return }
        updateSession(session.id) { $0.focusedPane = paneID }
    }

    // MARK: Events

    func handle(_ event: HookEvent, reply: SocketServer.Reply? = nil) {
        guard let paneID = UUID(uuidString: event.pane), let session = session(containing: paneID),
              let pane = session.root.panes.first(where: { $0.id == paneID }) else {
            reply?(.ask)
            return
        }
        let old = runtime(pane)
        var new = StatusReducer.reduce(old, event)
        if event.source == "shell", event.event == "prompt", let command = pendingCommands.removeValue(forKey: paneID),
           let terminal = terminals.views[paneID] {
            terminal.send(source: terminal, data: ArraySlice(Array((command + "\r").utf8)))
        }
        if let request = event.request, let reply {
            if isVisible(paneID) {
                // The user is looking at this pane: Claude's own prompt is right there.
                reply(.ask)
                new.permission = nil
            } else {
                permissionReplies[request] = reply
            }
        }
        if let stale = old.permission, new.permission?.id != stale.id {
            permissionReplies.removeValue(forKey: stale.id)?(.ask)
        }
        apply(new, to: paneID, old: old, session: session, event: event)
    }

    // MARK: Permissions

    /// Answers a held permission request from the sidebar or a notification.
    func answerPermission(_ requestID: String, _ decision: PermissionDecision) {
        permissionReplies.removeValue(forKey: requestID)?(decision)
        guard let (paneID, old) = runtimes.first(where: { $0.value.permission?.id == requestID }).map({ ($0.key, $0.value) }) else {
            return
        }
        var new = old
        new.permission = nil
        if decision != .ask {
            new.status = .agentWorking(.claude, since: old.turnStartedAt ?? Date())
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { runtimes[paneID] = new }
        updateBadge()
    }

    /// Hands held requests for panes now on screen back to Claude's own prompt.
    private func releaseVisiblePermissions() {
        for (paneID, runtime) in runtimes where runtime.permission != nil && isVisible(paneID) {
            answerPermission(runtime.permission!.id, .ask)
        }
    }

    private func paneSubmitted(_ paneID: UUID) {
        guard let session = session(containing: paneID), let old = runtimes[paneID] else { return }
        let new = StatusReducer.submitted(old)
        if new != old { apply(new, to: paneID, old: old, session: session, event: nil) }
    }

    private func apply(_ runtime: PaneRuntime, to paneID: UUID, old: PaneRuntime, session: Session, event: HookEvent?) {
        var new = runtime
        let visible = isVisible(paneID)
        let title = session.title

        switch (old.status, new.status) {
        case (.agentWorking(let agent, _), .succeeded):
            if !visible {
                new.unseen = true
                notifier.post(title: "\(agent.displayName) finished", body: new.lastPrompt ?? title, sessionID: session.id)
            }
        case (.running(let cmd, _), .succeeded), (.running(let cmd, _), .failed):
            if !visible, (new.lastDuration ?? 0) >= Self.longCommand {
                new.unseen = true
                let ok = { if case .succeeded = new.status { return true } else { return false } }()
                let seconds = Int(new.lastDuration ?? 0)
                notifier.post(title: ok ? "Command finished (\(seconds)s)" : "Command failed (\(seconds)s)",
                              body: cmd, sessionID: session.id)
            }
        case (_, .agentNeedsYou(let agent, let message)) where !old.status.needsYou:
            if !visible {
                notifier.post(title: "\(agent.displayName) needs you", body: message ?? title, sessionID: session.id,
                              permissionRequest: new.permission?.id)
            }
        default:
            break
        }

        runtimes[paneID] = new
        if let event, event.source == "shell", event.event == "start", let command = event.cmd {
            ports.scan(after: 1.5)
            history.record(command, cwd: old.cwd)
        }
        if let event, event.source == "shell", event.event == "end", case .failed = new.status,
           let command = new.command, CommandInfo.agent(command) == nil {
            failedCommand[paneID] = (command, new.cwd)
            showFailure(paneID)
        }
        if let event, Self.touchesFiles(event) { git.refresh(paneID, cwd: new.cwd) }
        if let event, event.tokens != nil, let agent = new.agent ?? AgentKind(rawValue: event.source) {
            usage.record(event, agent: agent)
        }
        // turnStartedAt marks an agent turn in progress, for Claude and Codex alike.
        if old.turnStartedAt == nil, new.turnStartedAt != nil {
            turns.begin(paneID, cwd: new.cwd)
        } else if old.turnStartedAt != nil, new.turnStartedAt == nil {
            turns.finish(paneID)
        }
        if session.autoTitle, let event, let auto = autoTitle(for: event, runtime: new) {
            updateSession(session.id) { $0.title = auto }
        } else if new.cwd != old.cwd {
            scheduleSave()
        }
        updateBadge()
    }

    private func autoTitle(for event: HookEvent, runtime: PaneRuntime) -> String? {
        let text: String?
        switch (event.source, event.event) {
        case ("shell", "start"): text = event.cmd
        case ("claude", "UserPromptSubmit"): text = event.prompt
        case ("codex", "agent-turn-complete"): text = runtime.lastPrompt
        default: text = nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > 42 ? String(text.prefix(40)) + "…" : text
    }

    private func markVisibleSeen() {
        guard appActive, let session = selectedSession else { return }
        for id in session.root.paneIDs where runtimes[id]?.unseen == true {
            runtimes[id]?.unseen = false
        }
        updateBadge()
    }

    private func updateBadge() {
        let count = needsYouCount + unseenCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: Ports

    private func setPorts(_ result: [UUID: [Int]]) {
        for (paneID, ports) in result where runtimes[paneID]?.ports ?? [] != ports {
            guard let pane = session(containing: paneID)?.root.panes.first(where: { $0.id == paneID }) else { continue }
            var r = runtime(pane)
            r.ports = ports
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { runtimes[paneID] = r }
        }
    }

    func openPort(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Failed commands

    /// The terminal's own start mark, not the socket's start event: the socket can lag behind
    /// the terminal and would clear the failure of a command that already finished.
    private func commandStarted(_ paneID: UUID) {
        capturedOutput[paneID] = nil
        failedCommand[paneID] = nil
        if failures[paneID] != nil { withAnimation { failures[paneID] = nil } }
    }

    private func commandFailed(_ paneID: UUID, _ captured: CapturedFailure) {
        capturedOutput[paneID] = captured
        showFailure(paneID)
    }

    private func showFailure(_ paneID: UUID) {
        guard let captured = capturedOutput[paneID], let ended = failedCommand[paneID] else { return }
        capturedOutput[paneID] = nil
        failedCommand[paneID] = nil
        let failure = CommandFailure(command: ended.command, cwd: ended.cwd, code: captured.code, output: captured.output)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { failures[paneID] = failure }
    }

    func dismissFailure(_ paneID: UUID) {
        withAnimation(.easeOut(duration: 0.2)) { failures[paneID] = nil }
    }

    /// Hands a failed command to an agent: pasted into an idle agent pane of the same session
    /// if there is one, otherwise in a new pane to the right.
    func askAgent(about paneID: UUID, agent: AgentKind) {
        guard let failure = failures[paneID], let session = session(containing: paneID) else { return }
        let prompt = failure.prompt
        let idle = session.root.panes.first { pane in
            let r = runtime(pane)
            return pane.id != paneID && r.agent == agent && !r.status.isBusy && !r.status.needsYou
        }
        if let target = idle, let terminal = terminals.views[target.id] {
            // Bracketed paste keeps the newlines in the prompt from submitting it early.
            terminal.send(source: terminal, data: ArraySlice(Array(("\u{1b}[200~" + prompt + "\u{1b}[201~").utf8)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                terminal.send(source: terminal, data: ArraySlice([13]))
            }
            updateSession(session.id) { $0.focusedPane = target.id }
        } else {
            let folder = ShellIntegration.supportDir.appendingPathComponent("prompts", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("failure-\(Int(Date().timeIntervalSince1970)).md")
            guard (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
            let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            split(.horizontal, from: paneID, command: "\(agent.rawValue) \"$(cat \(quoted))\"")
        }
        dismissFailure(paneID)
    }

    // MARK: Turn changes

    private func turnFinished(_ paneID: UUID, _ change: TurnChange?) {
        guard session(containing: paneID) != nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            turnChanges[paneID] = change
            if change != nil { expandedTurnCards.insert(paneID) }
        }
        guard change != nil else { return }
        // Fold the card into the header after a while; it's still one click away.
        let finishedAt = change!.finishedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.turnChanges[paneID]?.finishedAt == finishedAt else { return }
            _ = withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self.expandedTurnCards.remove(paneID) }
        }
    }

    func toggleTurnCard(_ paneID: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if expandedTurnCards.contains(paneID) { expandedTurnCards.remove(paneID) } else { expandedTurnCards.insert(paneID) }
        }
    }

    func dismissTurnChange(_ paneID: UUID) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            turnChanges[paneID] = nil
            expandedTurnCards.remove(paneID)
        }
    }

    func showDiff(_ file: FileChange, of paneID: UUID) {
        guard let change = turnChanges[paneID] else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { diffRequest = DiffRequest(file: file, change: change) }
    }

    // MARK: Git

    /// Events after which the working tree may have changed.
    static func touchesFiles(_ event: HookEvent) -> Bool {
        switch (event.source, event.event) {
        case ("shell", "end"), ("shell", "prompt"), ("claude", "PostToolUse"), ("claude", "Stop"),
             ("codex", "agent-turn-complete"):
            return true
        default:
            return false
        }
    }

    func refreshGitForSelection() {
        guard let session = selectedSession else { return }
        for pane in session.root.panes {
            git.refresh(pane.id, cwd: runtime(pane).cwd, delay: 0.05)
        }
    }

    private func setGit(_ status: GitStatus?, for paneID: UUID) {
        guard let pane = session(containing: paneID)?.root.panes.first(where: { $0.id == paneID }) else { return }
        var r = runtime(pane)
        guard r.git != status else { return }
        r.git = status
        runtimes[paneID] = r
    }

    // MARK: Themes

    var theme: TerminalTheme { themes.first { $0.id == themeID } ?? .kabuk }

    static var themesFolder: URL { ShellIntegration.supportDir.appendingPathComponent("themes", isDirectory: true) }

    func reloadThemes() {
        themes = TerminalTheme.builtIn + TerminalTheme.load(from: Self.themesFolder)
        terminals.theme = theme
    }

    /// Opens the folder for custom themes, seeding it with an editable copy of the current one.
    func openThemesFolder() {
        let folder = Self.themesFolder
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if !existing.contains(where: { $0.hasSuffix(".json") }) {
            var template = theme
            template.name = "My Theme"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(template).write(to: folder.appendingPathComponent("my-theme.json"))
            reloadThemes()
        }
        NSWorkspace.shared.open(folder)
    }

    func toggleThemeGallery() {
        if !themeGalleryVisible { reloadThemes() }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            themeGalleryVisible.toggle()
            paletteVisible = false
        }
    }

    // MARK: Find

    var findTerminal: KabukTerminalView? {
        findPane.flatMap { terminals.views[$0] }
    }

    func toggleFind() {
        if findPane != nil {
            closeFind()
        } else if let pane = selectedSession?.focusedPane {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { findPane = pane }
            updateFind()
        }
    }

    func closeFind() {
        findTerminal?.clearSearch()
        withAnimation(.easeOut(duration: 0.18)) { findPane = nil }
        findSummary = (0, 0)
    }

    /// Re-runs the search after the query changed.
    func updateFind() {
        guard let terminal = findTerminal else { return }
        terminal.clearSearch()
        guard !findQuery.isEmpty else {
            findSummary = (0, 0)
            return
        }
        _ = terminal.findNext(findQuery)
        findSummary = terminal.searchMatchSummary(findQuery)
    }

    func findStep(forward: Bool) {
        if findPane == nil {
            toggleFind()
            return
        }
        guard let terminal = findTerminal, !findQuery.isEmpty else { return }
        _ = forward ? terminal.findNext(findQuery) : terminal.findPrevious(findQuery)
        findSummary = terminal.searchMatchSummary(findQuery)
    }

    // MARK: Background

    var backdropMood: BackdropMood {
        guard let session = selectedSession else { return .calm }
        switch summary(of: session).status {
        case .agentNeedsYou: return .needsYou
        case .agentWorking(let agent, _): return agent == .claude ? .claude : .codex
        case .running: return .running
        default: return needsYouCount > 0 ? .needsYou : .calm
        }
    }

    // MARK: View

    func toggleSidebar() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { sidebarVisible.toggle() }
        scheduleSave()
    }

    func togglePalette() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            paletteVisible.toggle()
            themeGalleryVisible = false
            historyVisible = false
        }
    }

    func toggleHistory() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            historyVisible.toggle()
            paletteVisible = false
            themeGalleryVisible = false
        }
    }

    var focusedCwd: String? {
        selectedSession.flatMap { s in s.root.panes.first { $0.id == s.focusedPane } }.map { runtime($0).cwd }
    }

    /// Types text at the focused pane's prompt, optionally pressing return.
    func typeIntoFocusedPane(_ text: String, run: Bool) {
        guard let pane = selectedSession?.focusedPane, let terminal = terminals.views[pane] else { return }
        terminal.send(source: terminal, data: ArraySlice(Array((text + (run ? "\r" : "")).utf8)))
    }

    func toggleAnimatedBackground() {
        withAnimation(.easeInOut(duration: 0.4)) { animatedBackground.toggle() }
    }

    // MARK: Persistence

    var snapshot: WorkspaceSnapshot {
        var projects = projects
        for p in projects.indices {
            for s in projects[p].sessions.indices {
                for pane in projects[p].sessions[s].root.panes {
                    if let cwd = runtimes[pane.id]?.cwd {
                        projects[p].sessions[s].root = projects[p].sessions[s].root.updatingPane(pane.id) { $0.cwd = cwd }
                    }
                }
            }
        }
        return WorkspaceSnapshot(projects: projects, selectedSession: selectedSessionID,
                                 sidebarVisible: sidebarVisible, opacity: opacity, fontSize: fontSize,
                                 themeID: themeID, animatedBackground: animatedBackground)
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Persistence.save(self.snapshot)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        Persistence.save(snapshot)
    }
}

struct DiffRequest: Equatable {
    var file: FileChange
    var change: TurnChange
}

struct CommandFailure: Equatable {
    var command: String
    var cwd: String
    var code: Int32
    var output: String

    /// What the agent is asked.
    var prompt: String {
        var text = "This command failed in \(cwd) with exit code \(code):\n\n$ \(command)\n"
        if !output.isEmpty { text += "\nOutput:\n```\n\(output)\n```\n" }
        return text + "\nHelp me understand what went wrong and fix it."
    }
}
