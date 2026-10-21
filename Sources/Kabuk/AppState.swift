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
    @Published var subagentWorktrees: Bool {
        didSet {
            Self.writeSubagentWorktreesFlag(subagentWorktrees)
            scheduleSave()
        }
    }
    /// Sessions whose children (subagents, child sessions) are folded away in the sidebar.
    @Published var collapsedSessions: Set<UUID> = []
    /// The subagent whose live view is open: its pane and id.
    @Published var subagentDetail: SubagentDetailRequest?
    private var branchLookups: Set<String> = []
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
    /// Turns the user undid, with what it takes to redo them.
    @Published private(set) var undoneTurns: [UUID: UndoneTurn] = [:]
    /// Panes whose turn summary card is open rather than folded into the header.
    @Published var expandedTurnCards: Set<UUID> = []
    /// The file whose turn diff is on screen.
    @Published var diffRequest: DiffRequest?
    /// The worktree whose review sheet is open.
    @Published var worktreeReview: WorktreeReviewRequest?
    /// Notes the user left on diff lines, per agent pane, until they're sent.
    @Published private(set) var reviewComments: [UUID: [DiffComment]] = [:]
    /// Prompts waiting for the pane's agent to finish its turn.
    @Published private(set) var pendingPrompts: [UUID: String] = [:]
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
        subagentWorktrees = snapshot.subagentWorktrees
        Self.writeSubagentWorktreesFlag(snapshot.subagentWorktrees)
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
        case .review:
            reviewWorktree(of: sessionID)
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

    private enum WorktreeCloseChoice { case remove(force: Bool), keep, review, cancel }

    private func confirmWorktreeClose(_ worktree: WorktreeInfo) -> WorktreeCloseChoice {
        let dirty = Worktrees.isDirty(worktree)
        let alert = NSAlert()
        alert.messageText = "Remove the worktree \(worktree.name)?"
        alert.informativeText = (dirty
            ? "It has uncommitted changes that will be lost if you remove it.\n\n"
            : "") + "\(PaneContainer.abbreviate(worktree.path))\nThe branch \(worktree.branch) is kept either way."
        alert.addButton(withTitle: dirty ? "Remove Anyway" : "Remove Worktree")
        alert.addButton(withTitle: "Keep Worktree")
        alert.addButton(withTitle: "Review & Merge…")
        alert.addButton(withTitle: "Cancel")
        if dirty { alert.alertStyle = .warning }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .remove(force: dirty)
        case .alertSecondButtonReturn: return .keep
        case .alertThirdButtonReturn: return .review
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
    /// The new session sits under the one it was started from.
    func newWorktreeSession(agent: AgentKind?) {
        let parent = selectedSession
        let cwd = parent.flatMap { s in s.root.panes.first { $0.id == s.focusedPane } }.map { runtime($0).cwd }
            ?? NSHomeDirectory()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Worktrees.create(from: cwd, agent: agent)
            DispatchQueue.main.async {
                switch result {
                case .failure(let failure):
                    Self.alert("Couldn't create a worktree", failure.localizedDescription)
                case .success(let info):
                    self?.addWorktreeSession(info, agent: agent, parent: parent?.id, parentPane: parent?.focusedPane)
                }
            }
        }
    }

    /// `kabuk-hook spawn`: an agent asked for another agent in its own worktree. The session
    /// appears under the caller's without taking the user away from what they're looking at.
    private func spawn(_ event: HookEvent, from paneID: UUID, in session: Session, reply: SocketServer.Reply?) {
        guard let agent = event.kind.flatMap(AgentKind.init(rawValue:)) else {
            reply?(HookReply(error: "Unknown agent \(event.kind ?? ""); use claude or codex."))
            return
        }
        let cwd = event.cwd ?? runtimes[paneID]?.cwd ?? NSHomeDirectory()
        let prompt = event.prompt ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Worktrees.create(from: cwd, agent: agent)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let failure):
                    reply?(HookReply(error: failure.localizedDescription))
                case .success(let info):
                    let command = prompt.isEmpty ? agent.rawValue : Self.agentCommand(agent, prompt: prompt, name: "spawn")
                    // Named after its task; the command line that starts it says nothing.
                    let task = prompt.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    let title = task.isEmpty ? nil : (task.count > 42 ? String(task.prefix(40)) + "…" : task)
                    self.addWorktreeSession(info, agent: agent, command: command, title: title, parent: session.id,
                                            parentPane: paneID, select: false)
                    reply?(HookReply(worktree: info.path, branch: info.branch))
                }
            }
        }
    }

    private func addWorktreeSession(_ info: WorktreeInfo, agent: AgentKind?, command: String? = nil, title: String? = nil,
                                    parent: UUID? = nil, parentPane: UUID? = nil, select: Bool = true) {
        // Compared with symlinks resolved: a project opened as /tmp/x is git's /private/tmp/x.
        let repo = URL(fileURLWithPath: info.repoRoot).resolvingSymlinksInPath().path
        let projectIndex = projects.firstIndex { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == repo } ?? {
            projects.append(Project(name: (info.repoRoot as NSString).lastPathComponent, path: info.repoRoot))
            return projects.count - 1
        }()
        let session = Session(title: title ?? info.name, autoTitle: title == nil, cwd: info.path, worktree: info, parent: parent,
                              parentPane: parentPane)
        if let command = command ?? agent?.rawValue { pendingCommands[session.focusedPane] = command }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            projects[projectIndex].sessions.append(session)
            if select { selectedSessionID = session.id }
        }
        // Off screen nothing would start its shell; start it now so the agent gets going.
        if !select { _ = terminals.view(for: session.focusedPane, cwd: info.path) }
        scheduleSave()
    }

    // MARK: Worktree review

    func reviewWorktree(of sessionID: UUID) {
        guard let loc = location(of: sessionID), let info = projects[loc.project].sessions[loc.session].worktree else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            worktreeReview = WorktreeReviewRequest(info: info, sessionID: sessionID)
            paletteVisible = false
        }
    }

    func closeWorktreeReview() {
        withAnimation(.easeOut(duration: 0.2)) { worktreeReview = nil }
    }

    /// The pane that review notes and PR commands for a worktree go to.
    func agentPane(of request: WorktreeReviewRequest) -> UUID? {
        guard let id = request.sessionID, let loc = location(of: id) else { return nil }
        let session = projects[loc.project].sessions[loc.session]
        return session.root.panes.first { runtime($0).agent != nil }?.id ?? session.focusedPane
    }

    /// Pushes the branch and opens a pull request, in a pane where any login prompt can be answered.
    func openPullRequest(_ request: WorktreeReviewRequest) {
        let branch = "'" + request.info.branch.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "git push -u origin \(branch) && gh pr create --fill --head \(branch)"
        closeWorktreeReview()
        if let pane = agentPane(of: request) {
            split(.vertical, from: pane, command: command)
        } else {
            newSession(cwd: request.info.path)
            if let pane = selectedSession?.focusedPane { pendingCommands[pane] = command }
        }
    }

    /// After a merge the worktree and its branch have done their job.
    func discardWorktree(_ request: WorktreeReviewRequest) {
        closeWorktreeReview()
        if let id = request.sessionID { removeSession(id) }
        let info = request.info
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = Worktrees.discard(info)
            DispatchQueue.main.async {
                if let failure { Self.alert("Couldn't remove the worktree", failure.localizedDescription) }
            }
        }
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
            reply?(.permission(.ask))
            return
        }
        if event.source == "kabuk", event.event == "spawn" {
            spawn(event, from: paneID, in: session, reply: reply)
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
                reply(.permission(.ask))
                new.permission = nil
            } else {
                permissionReplies[request] = reply
            }
        }
        if let stale = old.permission, new.permission?.id != stale.id {
            permissionReplies.removeValue(forKey: stale.id)?(.permission(.ask))
        }
        apply(new, to: paneID, old: old, session: session, event: event)
    }

    // MARK: Permissions

    /// Answers a held permission request from the sidebar or a notification.
    func answerPermission(_ requestID: String, _ decision: PermissionDecision) {
        permissionReplies.removeValue(forKey: requestID)?(.permission(decision))
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

        if case .succeeded = new.status, new.agent != nil, old.status.isBusy || old.status.needsYou,
           let prompt = pendingPrompts.removeValue(forKey: paneID) {
            // Give the agent's input a moment to come back before typing into it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.paste(prompt, into: paneID) }
        }
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
        lookUpSubagentBranches(paneID, new)
        // The agent quit; notes queued for it have nobody to go to.
        if old.agent != nil, new.agent == nil { pendingPrompts[paneID] = nil }
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

    // MARK: Subagents

    /// kabuk-hook reads this flag beside the socket; there's no round trip in the Agent call.
    private static func writeSubagentWorktreesFlag(_ enabled: Bool) {
        let flag = ShellIntegration.supportDir.appendingPathComponent("subagent-worktrees-off")
        if enabled {
            try? FileManager.default.removeItem(at: flag)
        } else {
            try? FileManager.default.createDirectory(at: ShellIntegration.supportDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: Data())
        }
    }

    /// A subagent working outside the pane's folder has a worktree; its branch is worth showing.
    private func lookUpSubagentBranches(_ paneID: UUID, _ runtime: PaneRuntime) {
        for subagent in runtime.subagents where subagent.branch == nil {
            guard let cwd = subagent.cwd, cwd != runtime.cwd, !branchLookups.contains(cwd) else { continue }
            branchLookups.insert(cwd)
            let id = subagent.id
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd)
                guard branch.ok else { return }
                let name = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    guard let self, let index = self.runtimes[paneID]?.subagents.firstIndex(where: { $0.id == id }) else { return }
                    self.runtimes[paneID]?.subagents[index].branch = name
                }
            }
        }
    }

    /// Sessions started from this pane, shown as chips under it.
    func childSessions(of paneID: UUID) -> [Session] {
        guard let session = session(containing: paneID) else { return [] }
        let first = session.root.paneIDs.first
        return allSessions.filter { child in
            child.parent == session.id && (child.parentPane.map { session.root.contains($0) } == true ? child.parentPane == paneID : paneID == first)
        }
    }

    /// Sessions started from this one, for the sidebar tree.
    func childSessions(ofSession sessionID: UUID) -> [Session] {
        allSessions.filter { $0.parent == sessionID }
    }

    /// A project's sessions that aren't shown under a parent session.
    func rootSessions(of project: Project) -> [Session] {
        project.sessions.filter { $0.parent.flatMap { location(of: $0) } == nil }
    }

    func toggleCollapsed(_ sessionID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if collapsedSessions.contains(sessionID) { collapsedSessions.remove(sessionID) } else { collapsedSessions.insert(sessionID) }
        }
    }

    func subagent(_ request: SubagentDetailRequest) -> Subagent? {
        runtimes[request.paneID]?.subagents.first { $0.id == request.subagentID }
    }

    func showSubagent(_ subagentID: String, in paneID: UUID) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            subagentDetail = SubagentDetailRequest(paneID: paneID, subagentID: subagentID)
        }
    }

    func closeSubagentDetail() {
        withAnimation(.easeOut(duration: 0.2)) { subagentDetail = nil }
    }

    /// Opens the review sheet for the worktree a subagent worked in.
    func reviewSubagentWorktree(_ subagent: Subagent) {
        guard let cwd = subagent.cwd else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let top = Shell.git(["rev-parse", "--show-toplevel"], in: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !top.isEmpty, !branch.isEmpty, let repo = Worktrees.repoRoot(cwd) else {
                DispatchQueue.main.async { Self.alert("No worktree to review", "\(cwd) is gone; Claude removes a subagent's worktree when it changed nothing.") }
                return
            }
            let info = WorktreeInfo(path: top, branch: branch, repoRoot: repo, baseRef: "")
            DispatchQueue.main.async {
                guard let self else { return }
                self.subagentDetail = nil
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    self.worktreeReview = WorktreeReviewRequest(info: info, sessionID: nil)
                }
            }
        }
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
        if let target = idle, paste(prompt, into: target.id) {
            updateSession(session.id) { $0.focusedPane = target.id }
        } else {
            guard let command = Self.agentCommand(agent, prompt: prompt, name: "failure") else { return }
            split(.horizontal, from: paneID, command: command)
        }
        dismissFailure(paneID)
    }

    /// Submits a prompt at an agent's input. Bracketed paste keeps the newlines in the prompt
    /// from submitting it early.
    @discardableResult
    func paste(_ prompt: String, into paneID: UUID) -> Bool {
        guard let terminal = terminals.views[paneID] else { return false }
        terminal.send(source: terminal, data: ArraySlice(Array(("\u{1b}[200~" + prompt + "\u{1b}[201~").utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            terminal.send(source: terminal, data: ArraySlice([13]))
        }
        return true
    }

    /// A shell command that starts the agent with a prompt. The prompt goes through a file, so
    /// no quoting of its contents is needed.
    static func agentCommand(_ agent: AgentKind, prompt: String, name: String) -> String? {
        let folder = ShellIntegration.supportDir.appendingPathComponent("prompts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970))-\(WorktreeNaming.randomSuffix()).md")
        guard (try? prompt.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
        let quoted = "'" + file.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(agent.rawValue) \"$(cat \(quoted))\""
    }

    // MARK: Turn changes

    private func turnFinished(_ paneID: UUID, _ change: TurnChange?) {
        guard session(containing: paneID) != nil else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            turnChanges[paneID] = change
            undoneTurns[paneID] = nil
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

    /// Puts back the files the agent's last turn changed, after asking.
    func undoTurn(_ paneID: UUID, confirm: Bool = true) {
        guard let change = turnChanges[paneID], undoneTurns[paneID] == nil else { return }
        guard confirm else {
            runUndo(paneID, change) { TurnTracker.undo(change).map { $0 } }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commits = TurnTracker.commitsSince(change)
            DispatchQueue.main.async {
                guard let self, self.turnChanges[paneID] == change else { return }
                let alert = NSAlert()
                alert.messageText = "Undo the last turn?"
                alert.informativeText = "These files go back to how they were before the turn:\n\n" + TurnUndo.summary(change, commits: commits)
                    + "\n\nYou can redo it from the same card."
                alert.addButton(withTitle: "Undo Turn")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                self.runUndo(paneID, change) { TurnTracker.undo(change).map { $0 } }
            }
        }
    }

    func redoTurn(_ paneID: UUID) {
        guard let change = turnChanges[paneID], let undone = undoneTurns[paneID] else { return }
        runUndo(paneID, change) {
            TurnTracker.redo(change, undone).map { .failure($0) } ?? .success(nil)
        }
    }

    /// Runs an undo (which yields what redo needs) or a redo (which yields nil) off the main thread.
    private func runUndo(_ paneID: UUID, _ change: TurnChange, _ work: @escaping @Sendable () -> Result<UndoneTurn?, TurnUndoFailure>) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = work()
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let failure):
                    Self.alert("Couldn't undo the turn", failure.localizedDescription)
                case .success(let undone):
                    guard self.turnChanges[paneID] == change else { return }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.undoneTurns[paneID] = undone }
                }
                if let pane = self.session(containing: paneID)?.root.panes.first(where: { $0.id == paneID }) {
                    self.git.refresh(paneID, cwd: self.runtime(pane).cwd, delay: 0.05)
                }
            }
        }
    }

    func showDiff(_ file: FileChange, of paneID: UUID) {
        guard let change = turnChanges[paneID] else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            diffRequest = DiffRequest(file: file, change: change, paneID: paneID)
        }
    }

    // MARK: Review notes

    func addComment(_ comment: DiffComment, for paneID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { reviewComments[paneID, default: []].append(comment) }
    }

    func removeComment(_ id: UUID, for paneID: UUID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            reviewComments[paneID]?.removeAll { $0.id == id }
            if reviewComments[paneID]?.isEmpty == true { reviewComments[paneID] = nil }
        }
    }

    /// Who receives the notes: the pane's agent, or Claude in a new pane when none runs there.
    func reviewAgent(for paneID: UUID) -> AgentKind {
        runtimes[paneID]?.agent ?? .claude
    }

    /// Sends the notes as one prompt: typed in now if the agent is idle, after its turn if it's
    /// working, or to a new agent in a split when the pane has none.
    func sendComments(for paneID: UUID) {
        guard let comments = reviewComments[paneID], !comments.isEmpty else { return }
        let prompt = ReviewPrompt.build(comments)
        let runtime = runtimes[paneID]
        if runtime?.agent != nil {
            if runtime?.status.isBusy == true {
                pendingPrompts[paneID] = [pendingPrompts[paneID], prompt].compactMap { $0 }.joined(separator: "\n\n")
            } else {
                paste(prompt, into: paneID)
            }
        } else if let command = Self.agentCommand(.claude, prompt: prompt, name: "review") {
            split(.horizontal, from: paneID, command: command)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            reviewComments[paneID] = nil
            diffRequest = nil
        }
        if let session = session(containing: paneID) { updateSession(session.id) { $0.focusedPane = paneID } }
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
                                 themeID: themeID, animatedBackground: animatedBackground,
                                 subagentWorktrees: subagentWorktrees)
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

struct SubagentDetailRequest: Equatable {
    var paneID: UUID
    var subagentID: String
}

struct WorktreeReviewRequest: Equatable {
    var info: WorktreeInfo
    /// The session working in the worktree, if Kabuk opened it.
    var sessionID: UUID?
}

struct DiffRequest: Equatable {
    var file: FileChange
    var change: TurnChange
    /// The agent pane that review notes on this diff go to.
    var paneID: UUID?
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
