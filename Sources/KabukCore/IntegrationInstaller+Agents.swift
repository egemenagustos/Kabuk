import Foundation

/// Kabuk's entries for Gemini CLI, Copilot CLI, Antigravity CLI and OpenCode. Like Claude's,
/// each runs `$KABUK_HOOK`, which only Kabuk panes set, and does nothing anywhere else.
extension IntegrationInstaller {
    public static var geminiSettings = home(".gemini/settings.json")
    public static var copilotHooks: URL = {
        if let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"] {
            return URL(fileURLWithPath: custom).appendingPathComponent("hooks/kabuk.json")
        }
        return home(".copilot/hooks/kabuk.json")
    }()
    public static var antigravityHooks = home(".gemini/config/hooks.json")
    /// Antigravity may run a hook's command without a shell, so its hooks call this script.
    public static var antigravityScript = home(".gemini/config/kabuk-hook.sh")
    public static var opencodePlugin = home(".config/opencode/plugins/kabuk.js")

    private static func home(_ path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    /// The agents besides Claude and Codex that Kabuk can install hooks for.
    public static let hookedAgents: [AgentKind] = [.opencode, .gemini, .antigravity, .copilot]

    public static func install(_ agent: AgentKind) throws {
        switch agent {
        case .claude: try installClaude()
        case .codex: try installCodex()
        case .gemini: try installGemini()
        case .copilot: try installCopilot()
        case .antigravity: try installAntigravity()
        case .opencode: try installOpenCode()
        default: break
        }
    }

    public static func uninstall(_ agent: AgentKind) throws {
        switch agent {
        case .claude: try uninstallClaude()
        case .codex: try uninstallCodex()
        case .gemini: try uninstallGemini()
        case .copilot: try removeKabukFile(copilotHooks)
        case .antigravity: try uninstallAntigravity()
        case .opencode: try removeKabukFile(opencodePlugin)
        default: break
        }
    }

    public static func installed(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return claudeInstalled()
        case .codex: return codexInstalled()
        case .gemini: return (try? readJSON(geminiSettings, name: "~/.gemini/settings.json"))
            .flatMap { $0["hooks"] as? [String: Any] }.map(hasKabuk) ?? false
        case .copilot: return isKabukFile(copilotHooks)
        case .antigravity: return ((try? readJSON(antigravityHooks, name: "hooks.json"))?[antigravityGroup]) != nil
        case .opencode: return isKabukFile(opencodePlugin)
        default: return false
        }
    }

    /// Installed by an older Kabuk, with other hooks than this one writes.
    public static func outdated(_ agent: AgentKind) -> Bool {
        guard installed(agent) else { return false }
        switch agent {
        case .claude: return claudeOutdated()
        case .gemini:
            let hooks = (try? readJSON(geminiSettings, name: ""))?["hooks"] as? [String: Any] ?? [:]
            return geminiEvents.contains { event in !(hooks[event] as? [[String: Any]] ?? []).contains(where: isKabukGroup) }
        case .copilot: return (try? String(contentsOf: copilotHooks, encoding: .utf8)) != copilotFile
        case .antigravity:
            return (try? String(contentsOf: antigravityScript, encoding: .utf8)) != antigravityScriptText
                || !NSDictionary(dictionary: (try? readJSON(antigravityHooks, name: ""))?[antigravityGroup] as? [String: Any] ?? [:])
                    .isEqual(to: antigravityEntry)
        case .opencode: return (try? String(contentsOf: opencodePlugin, encoding: .utf8)) != opencodePluginText
        default: return false
        }
    }

    /// Where each agent's entries go, for messages.
    public static func location(_ agent: AgentKind) -> String {
        let path: String
        switch agent {
        case .claude: path = claudeSettings.path
        case .codex: path = codexConfig.path
        case .gemini: path = geminiSettings.path
        case .copilot: path = copilotHooks.path
        case .antigravity: path = antigravityHooks.path
        case .opencode: path = opencodePlugin.path
        default: return ""
        }
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: Gemini CLI

    static var geminiEvents: [String] { AgentHooks.events[.gemini] ?? [] }

    /// Gemini reads a hook's output as JSON, so outside Kabuk it still prints an empty object.
    public static func geminiCommand(_ event: String) -> String {
        #"if [ -n "$KABUK_HOOK" ]; then "$KABUK_HOOK" gemini \#(event); else echo '{}'; fi"#
    }

    public static func installGemini() throws {
        var settings = try readJSON(geminiSettings, name: "~/.gemini/settings.json")
        backup(geminiSettings)
        var hooks = removingKabuk(from: settings["hooks"] as? [String: Any] ?? [:])
        for event in geminiEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Gemini's timeouts are in milliseconds.
            groups.append(["hooks": [["name": "kabuk", "type": "command", "command": geminiCommand(event), "timeout": 5000]]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try writeJSON(settings, to: geminiSettings)
    }

    public static func uninstallGemini() throws {
        var settings = try readJSON(geminiSettings, name: "~/.gemini/settings.json")
        guard let hooks = settings["hooks"] as? [String: Any] else { return }
        let cleaned = removingKabuk(from: hooks)
        settings["hooks"] = cleaned.isEmpty ? nil : cleaned
        try writeJSON(settings, to: geminiSettings)
    }

    // MARK: Copilot CLI

    /// Copilot reads every file in its hooks folder, so Kabuk's live in a file of their own.
    public static var copilotFile: String {
        var hooks: [String: Any] = [:]
        for event in AgentHooks.events[.copilot] ?? [] {
            // A permission request waits for the user's answer.
            let timeout = event == "permissionRequest" ? 600 : 5
            hooks[event] = [["type": "command", "bash": #"[ -n "$KABUK_HOOK" ] && "$KABUK_HOOK" copilot \#(event) || true"#,
                             "timeoutSec": timeout]]
        }
        let file: [String: Any] = ["version": 1, "hooks": hooks]
        let data = (try? JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func installCopilot() throws {
        try writeFile(copilotFile, to: copilotHooks)
    }

    // MARK: Antigravity CLI

    static let antigravityGroup = "kabuk"

    public static var antigravityScriptText: String {
        """
        #!/bin/sh
        # Written by Kabuk (KABUK_HOOK); removed with Kabuk's integration.
        # Antigravity reads a hook's output as JSON; outside Kabuk this prints what it expects.
        if [ -n "$KABUK_HOOK" ]; then exec "$KABUK_HOOK" antigravity "$1"; fi
        if [ "$1" = Stop ]; then echo '{"decision":"stop"}'; else echo '{}'; fi

        """
    }

    /// Each top-level key of hooks.json is a named set of hooks. Tool events take matchers;
    /// the others list their commands directly.
    static var antigravityEntry: [String: Any] {
        var entry: [String: Any] = [:]
        for event in AgentHooks.events[.antigravity] ?? [] {
            let command: [String: Any] = ["type": "command", "command": "/bin/sh \(antigravityScript.path) \(event)", "timeout": 5]
            entry[event] = event.hasSuffix("ToolUse") ? [["matcher": "*", "hooks": [command]]] : [command]
        }
        return entry
    }

    public static func installAntigravity() throws {
        var hooks = try readJSON(antigravityHooks, name: "~/.gemini/config/hooks.json")
        backup(antigravityHooks)
        try writeFile(antigravityScriptText, to: antigravityScript)
        hooks[antigravityGroup] = antigravityEntry
        try writeJSON(hooks, to: antigravityHooks)
    }

    public static func uninstallAntigravity() throws {
        try removeKabukFile(antigravityScript)
        var hooks = try readJSON(antigravityHooks, name: "~/.gemini/config/hooks.json")
        guard hooks[antigravityGroup] != nil else { return }
        hooks[antigravityGroup] = nil
        try writeJSON(hooks, to: antigravityHooks)
    }

    // MARK: OpenCode

    /// A plugin for OpenCode 2. It runs in OpenCode's server, which in Kabuk is a private one per
    /// pane (`--standalone`, see the zsh integration), so it sees the pane's environment.
    public static let opencodePluginText = #"""
    // Written by Kabuk (KABUK_HOOK); removed with Kabuk's integration.
    // Tells Kabuk when OpenCode works, waits for permission and finishes. It only does something
    // in a Kabuk pane, where KABUK_HOOK is set.
    export default {
      id: "kabuk",
      setup(ctx) {
        const hook = process.env.KABUK_HOOK
        if (!hook || !process.env.KABUK_PANE_ID) return () => {}

        const send = async (event, data) => {
          const child = Bun.spawn([hook, "opencode", event], {
            stdin: new Blob([JSON.stringify(data ?? {})]),
            stdout: "pipe",
            stderr: "ignore",
          })
          return new Response(child.stdout).text()
        }
        const ignore = (promise) => promise.catch(() => {})

        // Subagents run as sessions of their own; the turn lasts until the last one is done.
        const running = new Set()
        const controller = new AbortController()
        ;(async () => {
          for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
            const data = event.data ?? {}
            const session = data.sessionID
            switch (event.type) {
              case "session.execution.started":
                if (running.size === 0) ignore(send("turn-start", { session }))
                running.add(session)
                break
              case "session.execution.succeeded":
              case "session.execution.failed":
              case "session.execution.interrupted":
                running.delete(session)
                if (running.size === 0) ignore(send("turn-end", { session }))
                break
              case "session.tool.called":
                ignore(send("tool", { session, tool: data.tool ?? data.name }))
                break
              case "permission.asked":
                ignore(ask(data))
                break
              case "permission.replied":
                ignore(send("tool", { session }))
                break
            }
          }
        })().catch(() => {})

        // Kabuk holds the request in its sidebar; an answer there is passed on as OpenCode's reply.
        async function ask(request) {
          const detail = [request.message, ...(request.resources ?? [])].filter(Boolean).join(" ")
          const answer = (await send("permission", { session: request.sessionID, tool: request.action, detail })).trim()
          if (!["once", "always", "reject"].includes(answer)) return
          await ctx.permission.reply({ sessionID: request.sessionID, requestID: request.id, decision: answer })
        }

        return () => controller.abort()
      },
    }

    """#

    public static func installOpenCode() throws {
        try writeFile(opencodePluginText, to: opencodePlugin)
    }

    // MARK: Files

    static func readJSON(_ url: URL, name: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.unreadable(name)
        }
        return json
    }

    static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func isKabukFile(_ url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("KABUK_HOOK")
    }

    /// Only a file Kabuk wrote; a user's own file at that path stays.
    static func removeKabukFile(_ url: URL) throws {
        guard isKabukFile(url) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
