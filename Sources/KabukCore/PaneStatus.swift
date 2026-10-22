import Foundation

public enum PaneStatus: Equatable, Sendable {
    case idle
    case running(command: String, startedAt: Date)
    case agentReady(AgentKind)
    case agentWorking(AgentKind, since: Date)
    case agentNeedsYou(AgentKind, message: String?)
    case succeeded(finishedAt: Date)
    case failed(code: Int32, finishedAt: Date)

    /// Higher wins when a session summarizes several panes.
    public var priority: Int {
        switch self {
        case .agentNeedsYou: return 6
        case .failed: return 5
        case .agentWorking: return 4
        case .running: return 3
        case .succeeded: return 2
        case .agentReady: return 1
        case .idle: return 0
        }
    }

    public var isBusy: Bool {
        switch self {
        case .running, .agentWorking: return true
        default: return false
        }
    }

    public var needsYou: Bool {
        if case .agentNeedsYou = self { return true }
        return false
    }
}

/// Everything the UI knows about one live pane. Not persisted.
public struct PaneRuntime: Equatable, Sendable {
    public var status: PaneStatus = .idle
    public var tag: String = "zsh"
    public var agent: AgentKind?
    /// The agent's hooks have reported since it started, so Kabuk stops guessing its turns.
    public var hooked = false
    public var command: String?
    public var cwd: String
    public var lastPrompt: String?
    public var lastDuration: TimeInterval?
    /// Finished while the user was looking elsewhere.
    public var unseen = false
    public var lastActivity: Date
    /// When the agent's current turn began; nil between turns.
    public var turnStartedAt: Date?
    /// Agent working time over finished turns since the agent was started.
    public var agentWorkTime: TimeInterval = 0
    public var tokens: TokenUsage?
    public var git: GitStatus?
    /// A permission request Kabuk is holding open for the user to answer.
    public var permission: PermissionPrompt?
    /// TCP ports that processes started in this pane listen on.
    public var ports: [Int] = []
    /// The main agent's subagents in this turn, plus background ones still running.
    public var subagents: [Subagent] = []
    /// Agent tool calls whose subagent hasn't announced itself yet.
    public var launches: [SubagentLaunch] = []

    public init(cwd: String, now: Date = Date()) {
        self.cwd = cwd
        self.lastActivity = now
    }

    /// Total agent working time, including the turn in progress.
    public func agentTime(now: Date = Date()) -> TimeInterval {
        agentWorkTime + (turnStartedAt.map { now.timeIntervalSince($0) } ?? 0)
    }
}
