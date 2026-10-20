import Foundation
import KabukCore

enum Persistence {
    static var url: URL { ShellIntegration.supportDir.appendingPathComponent("state.json") }

    static func load() -> WorkspaceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    static func save(_ snapshot: WorkspaceSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: ShellIntegration.supportDir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
