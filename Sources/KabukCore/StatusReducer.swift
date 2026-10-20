import Foundation

/// The single place where hook events turn into pane state.
public enum StatusReducer {
    /// Exit code zsh reports when the user hits ctrl-c.
    static let interrupted: Int32 = 130

    public static func reduce(_ state: PaneRuntime, _ event: HookEvent, now: Date = Date()) -> PaneRuntime {
        var s = state
        if let cwd = event.cwd, !cwd.isEmpty { s.cwd = cwd }
        if let tokens = event.tokens { s.tokens = tokens }
        // Any further progress from Claude means a held permission request was answered elsewhere.
        if event.source == "claude", event.event != "PermissionRequest", event.event != "Notification" {
            s.permission = nil
        }

        switch (event.source, event.event) {
        case ("shell", "start"):
            let cmd = event.cmd ?? ""
            s.command = cmd
            s.tag = CommandInfo.tag(cmd)
            s.unseen = false
            if let agent = CommandInfo.agent(cmd) {
                s.agent = agent
                s.agentWorkTime = 0
                s.tokens = nil
                s.turnStartedAt = nil
                if agent == .codex && CommandInfo.codexStartsWithPrompt(cmd) {
                    s.status = .agentWorking(.codex, since: now)
                    s.turnStartedAt = now
                } else {
                    s.status = .agentReady(agent)
                }
            } else {
                s.agent = nil
                s.status = .running(command: cmd, startedAt: now)
            }

        case ("shell", "end"):
            let code = event.code ?? 0
            if case .running(_, let start) = s.status {
                s.lastDuration = now.timeIntervalSince(start)
            }
            endTurn(&s, now: now)
            s.permission = nil
            s.agent = nil
            s.tag = "zsh"
            if code == interrupted {
                s.status = .idle
            } else if code == 0 {
                s.status = .succeeded(finishedAt: now)
            } else {
                s.status = .failed(code: code, finishedAt: now)
            }

        case ("shell", "prompt"):
            break

        case ("claude", "UserPromptSubmit"):
            s.agent = .claude
            s.tag = "claude"
            s.unseen = false
            if let prompt = event.prompt, !prompt.isEmpty { s.lastPrompt = prompt }
            s.status = .agentWorking(.claude, since: now)
            if s.turnStartedAt == nil { s.turnStartedAt = now }

        case ("claude", "PreToolUse"), ("claude", "PostToolUse"):
            s.agent = .claude
            s.tag = "claude"
            if case .agentWorking = s.status {} else {
                s.status = .agentWorking(.claude, since: s.turnStartedAt ?? now)
            }
            if s.turnStartedAt == nil { s.turnStartedAt = now }

        case ("claude", "PermissionRequest"):
            s.agent = .claude
            s.tag = "claude"
            let tool = event.tool ?? "Tool"
            let detail = event.detail ?? ""
            if let id = event.request {
                s.permission = PermissionPrompt(id: id, tool: tool, detail: detail, canAlwaysAllow: event.canAlwaysAllow ?? false)
            }
            s.status = .agentNeedsYou(.claude, message: detail.isEmpty ? "Allow \(tool)?" : "Allow \(tool): \(detail)")

        case ("claude", "Notification"):
            // Claude repeats "waiting for your input" after a finished turn; the turn is
            // already shown as done, so only real requests (permissions) need the user.
            if isIdleReminder(event), case .succeeded = s.status { return s }
            s.agent = .claude
            s.tag = "claude"
            s.status = .agentNeedsYou(.claude, message: event.message)

        case ("claude", "Stop"), ("codex", "agent-turn-complete"):
            let agent: AgentKind = event.source == "codex" ? .codex : .claude
            if let start = s.turnStartedAt {
                s.lastDuration = now.timeIntervalSince(start)
            } else if case .agentWorking(_, let since) = s.status {
                s.lastDuration = now.timeIntervalSince(since)
            }
            endTurn(&s, now: now)
            s.agent = agent
            s.tag = agent.rawValue
            if let prompt = event.prompt, !prompt.isEmpty { s.lastPrompt = prompt }
            s.status = .succeeded(finishedAt: now)

        case ("codex", "approval-requested"):
            s.agent = .codex
            s.tag = "codex"
            s.status = .agentNeedsYou(.codex, message: event.message)

        default:
            return state
        }
        s.lastActivity = now
        return s
    }

    /// The user pressed return inside a pane. Codex has no "turn started" hook, so this is
    /// how a Codex pane learns it is working again.
    public static func submitted(_ state: PaneRuntime, now: Date = Date()) -> PaneRuntime {
        guard state.agent == .codex else { return state }
        switch state.status {
        case .agentReady, .agentNeedsYou, .succeeded, .failed:
            var s = state
            s.status = .agentWorking(.codex, since: now)
            s.turnStartedAt = now
            s.unseen = false
            s.lastActivity = now
            return s
        default:
            return state
        }
    }

    /// Folds the finished turn into the agent's total working time.
    static func endTurn(_ s: inout PaneRuntime, now: Date) {
        if let start = s.turnStartedAt {
            s.agentWorkTime += now.timeIntervalSince(start)
            s.turnStartedAt = nil
        }
    }

    static func isIdleReminder(_ event: HookEvent) -> Bool {
        if event.kind == "idle_prompt" { return true }
        return event.message?.localizedCaseInsensitiveContains("waiting for your input") ?? false
    }
}
