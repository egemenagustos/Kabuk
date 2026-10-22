import Foundation

/// The single place where hook events turn into pane state.
public enum StatusReducer {
    /// Exit code zsh reports when the user hits ctrl-c.
    static let interrupted: Int32 = 130

    public static func reduce(_ state: PaneRuntime, _ event: HookEvent, now: Date = Date()) -> PaneRuntime {
        var s = state
        // A subagent's folder may be its own worktree; the pane stays where it is.
        if let cwd = event.cwd, !cwd.isEmpty, event.agent == nil { s.cwd = cwd }
        if let tokens = event.tokens { s.tokens = tokens }
        // Further progress from whoever asked means a held permission request was answered
        // elsewhere. Subagents run side by side, so another one's progress says nothing.
        if event.source == "claude", event.event != "PermissionRequest", event.event != "Notification",
           !subagentLifecycle(event), s.permission?.agent == event.agent {
            s.permission = nil
        }
        if event.source != "claude", AgentEvent.progress.contains(event.event) { s.permission = nil }
        if AgentKind(rawValue: event.source) != nil, AgentEvent.fromHooks(event.event) { s.hooked = true }

        switch (event.source, event.event) {
        case ("shell", "start"):
            let cmd = event.cmd ?? ""
            s.command = cmd
            s.tag = CommandInfo.tag(cmd)
            s.unseen = false
            s.hooked = false
            if let agent = CommandInfo.agent(cmd) {
                s.agent = agent
                s.agentWorkTime = 0
                s.tokens = nil
                s.turnStartedAt = nil
                if CommandInfo.startsWithPrompt(cmd, agent: agent) {
                    s.status = .agentWorking(agent, since: now)
                    s.turnStartedAt = now
                } else {
                    s.status = .agentReady(agent)
                }
            } else {
                s.agent = nil
                s.status = .running(command: cmd, startedAt: now)
            }
            s.subagents = []
            s.launches = []

        case ("shell", "end"):
            let code = event.code ?? 0
            if case .running(_, let start) = s.status {
                s.lastDuration = now.timeIntervalSince(start)
            }
            endTurn(&s, now: now)
            s.permission = nil
            s.agent = nil
            s.hooked = false
            s.tag = "zsh"
            s.subagents = []
            s.launches = []
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
            if let prompt = event.userPrompt { s.lastPrompt = prompt }
            s.status = .agentWorking(.claude, since: now)
            if s.turnStartedAt == nil { s.turnStartedAt = now }
            // A new turn starts with only the background subagents that are still at it.
            s.subagents.removeAll { $0.state == .done }
            s.launches = []

        case ("claude", "SubagentStart"):
            guard let id = event.agent else { return state }
            let type = event.agentType ?? "general-purpose"
            var description = event.detail ?? ""
            if let index = s.launches.firstIndex(where: { $0.type == type }) ?? s.launches.indices.first {
                if description.isEmpty { description = s.launches[index].description }
                s.launches.remove(at: index)
            }
            s.subagents.removeAll { $0.id == id }
            var subagent = Subagent(id: id, type: type, description: description, startedAt: now)
            subagent.transcript = event.transcript
            s.subagents.append(subagent)

        case ("claude", "SubagentStop"):
            guard let id = event.agent, let index = s.subagents.firstIndex(where: { $0.id == id }) else { return state }
            s.subagents[index].state = .done
            s.subagents[index].finishedAt = now
            if let summary = event.message { s.subagents[index].summary = summary }
            if let transcript = event.transcript { s.subagents[index].transcript = transcript }

        case ("claude", "PreToolUse"), ("claude", "PostToolUse"):
            // An Agent call: its subagent type travels in `kind`, its task in `detail`.
            if event.event == "PreToolUse", let tool = event.tool, SubagentIsolation.launchTools.contains(tool) {
                s.launches.append(SubagentLaunch(type: event.kind ?? "general-purpose", description: event.detail ?? ""))
            }
            if let id = event.agent {
                // A subagent's tool use. Background subagents outlive the main turn, so the
                // pane's own status is left alone.
                if let index = s.subagents.firstIndex(where: { $0.id == id }) {
                    if event.event == "PostToolUse" { s.subagents[index].toolCount += 1 }
                    if let tool = event.tool { s.subagents[index].lastTool = tool }
                    if let cwd = event.cwd, !cwd.isEmpty { s.subagents[index].cwd = cwd }
                }
                break
            }
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
                s.permission = PermissionPrompt(id: id, tool: tool, detail: detail, canAlwaysAllow: event.canAlwaysAllow ?? false,
                                                agent: event.agent)
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
            if let prompt = event.userPrompt { s.lastPrompt = prompt }
            s.status = .succeeded(finishedAt: now)

        case ("codex", "approval-requested"):
            s.agent = .codex
            s.tag = "codex"
            s.status = .agentNeedsYou(.codex, message: event.message)

        case (let source, let name) where AgentEvent.all.contains(name):
            guard let agent = AgentKind(rawValue: source) else { return state }
            return reduceAgent(s, event, agent: agent, now: now) ?? state

        default:
            return state
        }
        s.lastActivity = now
        return s
    }

    /// The events of agents other than Claude and Codex, as `kabuk-hook` translates their hooks,
    /// plus the guesses Kabuk makes for agents whose hooks don't report.
    static func reduceAgent(_ state: PaneRuntime, _ event: HookEvent, agent: AgentKind, now: Date) -> PaneRuntime? {
        var s = state
        // A guess only counts while no hook has spoken, and only for agents Kabuk guesses for.
        if AgentEvent.guesses.contains(event.event) {
            guard agent.profile.guessesTurns, !s.hooked, s.agent == agent else { return nil }
        }
        switch event.event {
        case AgentEvent.turnStart:
            s.agent = agent
            s.tag = agent.rawValue
            s.unseen = false
            if let prompt = event.userPrompt { s.lastPrompt = prompt }
            s.status = .agentWorking(agent, since: s.turnStartedAt ?? now)
            if s.turnStartedAt == nil { s.turnStartedAt = now }

        case AgentEvent.tool:
            s.agent = agent
            s.tag = agent.rawValue
            if case .agentWorking = s.status {} else {
                s.status = .agentWorking(agent, since: s.turnStartedAt ?? now)
            }
            if s.turnStartedAt == nil { s.turnStartedAt = now }

        case AgentEvent.permission:
            s.agent = agent
            s.tag = agent.rawValue
            let tool = event.tool ?? "Tool"
            let detail = event.detail ?? ""
            if let id = event.request {
                s.permission = PermissionPrompt(id: id, tool: tool, detail: detail, canAlwaysAllow: false)
            }
            s.status = .agentNeedsYou(agent, message: detail.isEmpty ? "Allow \(tool)?" : "Allow \(tool): \(detail)")

        case AgentEvent.needsYou:
            s.agent = agent
            s.tag = agent.rawValue
            s.status = .agentNeedsYou(agent, message: event.message)

        case AgentEvent.notification:
            // A terminal notification: a question for the user, or the agent saying it's done.
            if AgentEvent.asksForInput(event.message) {
                s.status = .agentNeedsYou(agent, message: event.message)
            } else {
                guard s.status.isBusy || s.status.needsYou || s.turnStartedAt != nil else { return nil }
                finishTurn(&s, agent: agent, prompt: nil, now: now)
            }

        case AgentEvent.quiet:
            guard case .agentWorking = s.status else { return nil }
            finishTurn(&s, agent: agent, prompt: nil, now: now)

        case AgentEvent.turnEnd:
            finishTurn(&s, agent: agent, prompt: event.userPrompt, now: now)

        default:
            return nil
        }
        s.lastActivity = now
        return s
    }

    static func finishTurn(_ s: inout PaneRuntime, agent: AgentKind, prompt: String?, now: Date) {
        if let start = s.turnStartedAt {
            s.lastDuration = now.timeIntervalSince(start)
        } else if case .agentWorking(_, let since) = s.status {
            s.lastDuration = now.timeIntervalSince(since)
        }
        endTurn(&s, now: now)
        s.agent = agent
        s.tag = agent.rawValue
        if let prompt { s.lastPrompt = prompt }
        s.status = .succeeded(finishedAt: now)
    }

    /// The user pressed return inside a pane. Codex has no "turn started" hook, so this is
    /// how a Codex pane learns it is working again; so do agents whose hooks haven't reported.
    public static func submitted(_ state: PaneRuntime, now: Date = Date()) -> PaneRuntime {
        guard let agent = state.agent else { return state }
        let profile = agent.profile
        guard !profile.reportsTurnStart || (profile.guessesTurns && !state.hooked) else { return state }
        switch state.status {
        case .agentReady, .agentNeedsYou, .succeeded, .failed:
            var s = state
            s.status = .agentWorking(agent, since: now)
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

    static func subagentLifecycle(_ event: HookEvent) -> Bool {
        event.event == "SubagentStart" || event.event == "SubagentStop"
    }

    static func isIdleReminder(_ event: HookEvent) -> Bool {
        if event.kind == "idle_prompt" { return true }
        return event.message?.localizedCaseInsensitiveContains("waiting for your input") ?? false
    }
}
