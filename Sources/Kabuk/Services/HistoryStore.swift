import Foundation
import KabukCore

/// Every command run in Kabuk (with its folder), plus ~/.zsh_history for older ones.
@MainActor
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let queue = DispatchQueue(label: "kabuk.history", qos: .utility)

    static var url: URL { ShellIntegration.supportDir.appendingPathComponent("history.jsonl") }
    nonisolated static let keep = 10_000
    nonisolated static let trimAt = 20_000

    init() {
        let url = Self.url
        // The demo is recorded: keep the user's own history out of it.
        let importZsh = !AppState.isDemo
        queue.async { [weak self] in
            let zshFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".zsh_history")
            let zsh = importZsh ? (try? Data(contentsOf: zshFile)).map { ZshHistory.parse($0) } ?? [] : []
            var own = Self.read(url)
            if own.count > Self.trimAt {
                own = Array(own.suffix(Self.keep))
                Self.write(own, to: url)
            }
            let all = zsh + own
            DispatchQueue.main.async { self?.entries = all + (self?.entries ?? []) }
        }
    }

    func record(_ command: String, cwd: String) {
        guard HistoryEntry.shouldRecord(command) else { return }
        let entry = HistoryEntry(command: command, cwd: cwd, date: Date())
        entries.append(entry)
        let url = Self.url
        queue.async {
            guard var line = try? JSONEncoder().encode(entry) else { return }
            line.append(UInt8(ascii: "\n"))
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? line.write(to: url)
            }
        }
    }

    nonisolated private static func read(_ url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(HistoryEntry.self, from: Data($0)) }
    }

    nonisolated private static func write(_ entries: [HistoryEntry], to url: URL) {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? data.write(to: url, options: .atomic)
    }
}
