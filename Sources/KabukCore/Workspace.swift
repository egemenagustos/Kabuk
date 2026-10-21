import Foundation

public struct Session: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    /// False once the user renames the session; until then the title follows the last command.
    public var autoTitle: Bool
    public var root: PaneNode
    public var focusedPane: UUID
    /// Set when the session works in its own git worktree.
    public var worktree: WorktreeInfo?
    /// The session this one was started from; the sidebar shows it underneath.
    public var parent: UUID?
    /// The pane in the parent session it came from, where its chip shows.
    public var parentPane: UUID?

    public init(id: UUID = UUID(), title: String = "zsh", autoTitle: Bool = true, cwd: String,
                worktree: WorktreeInfo? = nil, parent: UUID? = nil, parentPane: UUID? = nil) {
        let pane = Pane(cwd: cwd)
        self.id = id
        self.title = title
        self.autoTitle = autoTitle
        self.root = .leaf(pane)
        self.focusedPane = pane.id
        self.worktree = worktree
        self.parent = parent
        self.parentPane = parentPane
    }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var sessions: [Session]

    public init(id: UUID = UUID(), name: String, path: String, sessions: [Session] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

/// What Kabuk writes to disk between launches.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var selectedSession: UUID?
    public var sidebarVisible: Bool
    public var opacity: Double
    public var fontSize: Double
    public var themeID: String
    public var animatedBackground: Bool
    /// Claude's editing subagents get their own git worktree.
    public var subagentWorktrees: Bool

    /// Pane card tint levels. Glass matches the sidebar: the blurred window shows through.
    public static let glass = 0.08
    public static let transparencyLevels: [(name: String, value: Double)] = [("Glass", glass), ("Tinted", 0.4), ("Solid", 0.75)]
    /// The default before Glass existed; state saved with it moves to Glass.
    static let previousDefault = 0.5

    public init(projects: [Project], selectedSession: UUID?, sidebarVisible: Bool = true,
                opacity: Double = WorkspaceSnapshot.glass, fontSize: Double = 13, themeID: String = TerminalTheme.kabuk.id,
                animatedBackground: Bool = true, subagentWorktrees: Bool = true) {
        self.projects = projects
        self.selectedSession = selectedSession
        self.sidebarVisible = sidebarVisible
        self.opacity = opacity
        self.fontSize = fontSize
        self.themeID = themeID
        self.animatedBackground = animatedBackground
        self.subagentWorktrees = subagentWorktrees
    }

    /// Fields added in later versions fall back to defaults, so older state files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decode([Project].self, forKey: .projects)
        selectedSession = try c.decodeIfPresent(UUID.self, forKey: .selectedSession)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        let saved = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.glass
        opacity = saved == Self.previousDefault ? Self.glass : saved
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? TerminalTheme.kabuk.id
        animatedBackground = try c.decodeIfPresent(Bool.self, forKey: .animatedBackground) ?? true
        subagentWorktrees = try c.decodeIfPresent(Bool.self, forKey: .subagentWorktrees) ?? true
    }
}
