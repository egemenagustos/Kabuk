import Foundation

/// What the app writes back to a `kabuk-hook` that waits on its connection: a permission
/// decision, or the worktree a spawned agent was given.
public struct HookReply: Codable, Equatable, Sendable {
    public var decision: PermissionDecision?
    public var worktree: String?
    public var branch: String?
    public var error: String?

    public init(decision: PermissionDecision? = nil, worktree: String? = nil, branch: String? = nil, error: String? = nil) {
        self.decision = decision
        self.worktree = worktree
        self.branch = branch
        self.error = error
    }

    public static func permission(_ decision: PermissionDecision) -> HookReply {
        HookReply(decision: decision)
    }

    public func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data()
        data.append(UInt8(ascii: "\n"))
        return data
    }

    public static func parse(_ data: Data) -> HookReply? {
        let line = data.split(separator: UInt8(ascii: "\n")).first.map { Data($0) } ?? data
        return try? JSONDecoder().decode(HookReply.self, from: line)
    }
}
