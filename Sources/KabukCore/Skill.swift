import Foundation

/// A skill an agent can load: a SKILL.md in one of the folders Claude Code or Codex reads.
public struct Skill: Equatable, Identifiable, Sendable {
    public enum Scope: Equatable, Sendable {
        case user
        case project
        case plugin(String)
        /// Synced from claude.ai.
        case synced
        /// Shipped with the agent.
        case builtIn

        /// Where the agent looks first; a name found earlier hides the same name found later.
        var rank: Int {
            switch self {
            case .user: return 0
            case .project: return 1
            case .plugin: return 2
            case .synced: return 3
            case .builtIn: return 4
            }
        }
    }

    public var agent: AgentKind
    public var name: String
    public var description: String
    /// What follows "/" or "$": the name, or "plugin:name" for a plugin's skill.
    public var invocation: String
    public var scope: Scope
    /// The SKILL.md file.
    public var path: String

    public init(agent: AgentKind, name: String, description: String, invocation: String, scope: Scope, path: String) {
        self.agent = agent
        self.name = name
        self.description = description
        self.invocation = invocation
        self.scope = scope
        self.path = path
    }

    public var id: String { "\(agent.rawValue):\(invocation)" }

    /// Typed at the agent's prompt. Claude runs skills as slash commands; Codex mentions them with "$".
    public var insertion: String {
        switch agent {
        case .claude: return "/\(invocation) "
        case .codex: return "$\(invocation) "
        }
    }

    /// How well a search matches. The name decides; the description only finds a skill whose name
    /// doesn't match, by the words typed, ranked after every name match. Fuzzy matching a long
    /// description would match nearly anything, and its length penalty would sink the very skill
    /// being typed.
    public func matchScore(_ query: String) -> Int? {
        if let score = FuzzyMatcher.score(query, in: invocation) { return score }
        let words = query.trimmingCharacters(in: .whitespaces)
        return !words.isEmpty && description.localizedCaseInsensitiveContains(words) ? -1000 : nil
    }

    public var scopeLabel: String {
        switch scope {
        case .user: return "user"
        case .project: return "project"
        case .plugin(let name): return name
        case .synced: return "claude.ai"
        case .builtIn: return "built-in"
        }
    }
}

/// The few SKILL.md frontmatter fields Kabuk shows. Not a YAML parser: `key: value` lines,
/// quoted values, and values folded over indented lines (`>`, `|` or plain).
public enum SkillFrontmatter {
    public struct Fields: Equatable, Sendable {
        public var name: String?
        public var description: String?
        public var userInvocable = true
    }

    public static func parse(_ text: String) -> Fields? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var values: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if line.first == " " || line.first == "\t" {
                // A continuation of the value above.
                guard let key else { continue }
                let part = line.trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { values[key] = [values[key] ?? "", part].filter { !$0.isEmpty }.joined(separator: " ") }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { key = nil; continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-", ">+", "|+"].contains(value) { value = "" }
            key = name
            values[name] = value
        }

        var fields = Fields()
        fields.name = values["name"].map(unquote).flatMap { $0.isEmpty ? nil : $0 }
        fields.description = values["description"].map(unquote).flatMap { $0.isEmpty ? nil : $0 }
        fields.userInvocable = values["user-invocable"].map(unquote)?.lowercased() != "false"
        return fields
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        return first == "\"" ? inner.replacingOccurrences(of: "\\\"", with: "\"") : inner.replacingOccurrences(of: "''", with: "'")
    }
}

/// Finds the skills an agent would load in a folder, the way Claude Code and Codex look for them.
public enum SkillCatalog {
    public static func scan(agent: AgentKind, cwd: String,
                            home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                            fileManager: FileManager = .default) -> [Skill] {
        let project = projectFolders(from: URL(fileURLWithPath: cwd), fileManager: fileManager)
        var found: [Skill] = []
        switch agent {
        case .claude:
            let claude = home.appendingPathComponent(".claude")
            found += skills(in: claude.appendingPathComponent("skills"), agent: agent, scope: .user, fileManager: fileManager)
            for folder in project {
                found += skills(in: folder.appendingPathComponent(".claude/skills"), agent: agent, scope: .project, fileManager: fileManager)
            }
            for plugin in enabledPlugins(claude: claude, project: project) {
                found += skills(in: URL(fileURLWithPath: plugin.path).appendingPathComponent("skills"), agent: agent,
                                scope: .plugin(plugin.name), prefix: plugin.name, fileManager: fileManager)
            }
            let synced = claude.appendingPathComponent("skills/synced")
            for folder in subfolders(of: synced, fileManager: fileManager) {
                found += skills(in: folder, agent: agent, scope: .synced, prefix: "anthropic-skills", fileManager: fileManager)
            }
        case .codex:
            let codex = home.appendingPathComponent(".codex")
            found += skills(in: home.appendingPathComponent(".agents/skills"), agent: agent, scope: .user, fileManager: fileManager)
            found += skills(in: codex.appendingPathComponent("skills"), agent: agent, scope: .user, fileManager: fileManager)
            for folder in project {
                found += skills(in: folder.appendingPathComponent(".agents/skills"), agent: agent, scope: .project, fileManager: fileManager)
                found += skills(in: folder.appendingPathComponent(".codex/skills"), agent: agent, scope: .project, fileManager: fileManager)
            }
            found += skills(in: codex.appendingPathComponent("skills/.system"), agent: agent, scope: .builtIn, fileManager: fileManager)
        }

        var seen: Set<String> = []
        return found
            .filter { seen.insert($0.invocation).inserted }
            .sorted { ($0.scope.rank, $0.invocation.lowercased()) < ($1.scope.rank, $1.invocation.lowercased()) }
    }

    /// The folder and its parents up to the git root, nearest first. Outside a repository, only the folder.
    static func projectFolders(from cwd: URL, fileManager: FileManager) -> [URL] {
        var folders: [URL] = []
        var folder = cwd.standardizedFileURL
        while true {
            folders.append(folder)
            // A worktree has a .git file instead of a folder; both mark the root.
            if fileManager.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folders }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return [cwd.standardizedFileURL] }
            folder = parent
        }
    }

    /// Every folder in `root` that holds a SKILL.md. Hidden folders are skipped, like Codex's `.system`,
    /// which is read on its own.
    static func skills(in root: URL, agent: AgentKind, scope: Skill.Scope, prefix: String? = nil,
                       fileManager: FileManager) -> [Skill] {
        subfolders(of: root, fileManager: fileManager).compactMap { folder in
            let file = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let fields = SkillFrontmatter.parse(text) ?? .init()
            guard fields.userInvocable else { return nil }
            let name = fields.name ?? folder.lastPathComponent
            return Skill(agent: agent, name: name, description: fields.description ?? "",
                         invocation: prefix.map { "\($0):\(name)" } ?? name, scope: scope, path: file.path)
        }
    }

    private static func subfolders(of root: URL, fileManager: FileManager) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { root.appendingPathComponent($0) }
    }

    private struct InstalledPlugins: Decodable {
        struct Install: Decodable {
            var installPath: String
            var scope: String?
            var projectPath: String?
        }
        var plugins: [String: [Install]]
    }

    /// Installed plugins that settings.json turns on. A plugin installed for one project only
    /// counts in that project.
    static func enabledPlugins(claude: URL, project: [URL]) -> [(name: String, path: String)] {
        guard let data = try? Data(contentsOf: claude.appendingPathComponent("plugins/installed_plugins.json")),
              let installed = try? JSONDecoder().decode(InstalledPlugins.self, from: data),
              let settings = try? Data(contentsOf: claude.appendingPathComponent("settings.json")),
              let json = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let enabled = json["enabledPlugins"] as? [String: Any]
        else { return [] }
        let projectPaths = Set(project.map(\.path))
        return installed.plugins.keys.sorted().compactMap { key in
            guard enabled[key] as? Bool == true else { return nil }
            let install = installed.plugins[key]?.first { install in
                guard let path = install.projectPath, install.scope == "project" || install.scope == "local" else { return true }
                return projectPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
            guard let install else { return nil }
            let name = key.split(separator: "@").first.map(String.init) ?? key
            return (name, install.installPath)
        }
    }
}
