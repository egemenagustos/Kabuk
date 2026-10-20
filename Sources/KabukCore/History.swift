import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable {
    public var command: String
    /// Empty for entries imported from ~/.zsh_history, which doesn't record folders.
    public var cwd: String
    public var date: Date

    public init(command: String, cwd: String, date: Date) {
        self.command = command
        self.cwd = cwd
        self.date = date
    }

    /// Plain-format zsh history has no timestamps; such entries get tiny dates that only keep
    /// their order (see `ZshHistory.parse`).
    public var hasKnownDate: Bool { date.timeIntervalSince1970 > 1_000_000 }

    /// zsh's HIST_IGNORE_SPACE convention: a leading space keeps a command out of history.
    public static func shouldRecord(_ command: String) -> Bool {
        !command.hasPrefix(" ") && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ZshHistory {
    /// Parses ~/.zsh_history in both the plain and the extended (`: <time>:<duration>;cmd`)
    /// format. Lines ending in a backslash continue a multi-line command. Plain lines have no
    /// time, so they're dated by position (seconds since 1970), oldest first.
    public static func parse(_ data: Data) -> [HistoryEntry] {
        let text = String(decoding: unmetafy(data), as: UTF8.self)
        var entries: [HistoryEntry] = []
        var pending: (command: String, date: Date)?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(line)
            if var current = pending {
                current.command += "\n"
                line = finishLine(line, into: &current.command)
                pending = line.isEmpty ? current : nil
                if pending == nil { entries.append(HistoryEntry(command: current.command, cwd: "", date: current.date)) }
                continue
            }
            var date = Date(timeIntervalSince1970: TimeInterval(entries.count))
            if line.hasPrefix(": "), let semicolon = line.firstIndex(of: ";") {
                let stamp = line[line.index(line.startIndex, offsetBy: 2)..<semicolon].split(separator: ":").first
                date = stamp.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) } ?? date
                line = String(line[line.index(after: semicolon)...])
            }
            guard !line.isEmpty else { continue }
            var command = ""
            if finishLine(line, into: &command).isEmpty {
                pending = (command, date)
            } else {
                entries.append(HistoryEntry(command: command, cwd: "", date: date))
            }
        }
        return entries.compactMap { entry in
            let command = entry.command.trimmingCharacters(in: .whitespaces)
            return command.isEmpty ? nil : HistoryEntry(command: command, cwd: entry.cwd, date: entry.date)
        }
    }

    /// Appends `line` to `command`, dropping a trailing continuation backslash. Returns ""
    /// when the command continues on the next line.
    private static func finishLine(_ line: String, into command: inout String) -> String {
        if line.hasSuffix("\\") {
            command += String(line.dropLast())
            return ""
        }
        command += line
        return line.isEmpty ? " " : line
    }

    /// zsh stores some bytes as 0x83 followed by the byte XOR 0x20.
    static func unmetafy(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        var meta = false
        for byte in data {
            if meta {
                out.append(byte ^ 0x20)
                meta = false
            } else if byte == 0x83 {
                meta = true
            } else {
                out.append(byte)
            }
        }
        return out
    }
}

public enum HistorySearch {
    /// Unique commands, best match first. An empty query lists the most recent. With `cwd`,
    /// only commands run in that folder.
    public static func search(_ entries: [HistoryEntry], query: String, cwd: String? = nil, limit: Int = 50) -> [HistoryEntry] {
        var latest: [String: HistoryEntry] = [:]
        for entry in entries where cwd == nil || entry.cwd == cwd {
            if let seen = latest[entry.command], seen.date >= entry.date { continue }
            latest[entry.command] = entry
        }
        let byRecency = latest.values.sorted { $0.date > $1.date }
        guard !query.isEmpty else { return Array(byRecency.prefix(limit)) }
        // Recency breaks ties and nudges close matches: newer commands get up to 5 extra points.
        let scored = byRecency.enumerated().compactMap { rank, entry -> (HistoryEntry, Double)? in
            guard let score = FuzzyMatcher.score(query, in: entry.command) else { return nil }
            return (entry, Double(score) + 5 / Double(rank + 1))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }
}
