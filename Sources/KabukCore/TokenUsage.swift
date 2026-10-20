import Foundation

/// Token counts for one model, split the way the price list splits them.
public struct TokenBreakdown: Codable, Equatable, Sendable {
    /// Uncached input.
    public var input = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    public var output = 0

    public init(input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, cacheRead: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }

    public static func + (a: TokenBreakdown, b: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(input: a.input + b.input, cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                       cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h, cacheRead: a.cacheRead + b.cacheRead,
                       output: a.output + b.output)
    }
}

/// How much of the model's context an agent session uses, and how much it has written.
public struct TokenUsage: Codable, Equatable, Sendable {
    /// Tokens in the most recent request: the conversation as the model currently sees it.
    public var context: Int
    /// Output tokens summed over the whole session.
    public var output: Int
    /// Session totals per model id, for pricing.
    public var byModel: [String: TokenBreakdown]

    public init(context: Int, output: Int, byModel: [String: TokenBreakdown] = [:]) {
        self.context = context
        self.output = output
        self.byModel = byModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        context = try c.decode(Int.self, forKey: .context)
        output = try c.decode(Int.self, forKey: .output)
        byModel = try c.decodeIfPresent([String: TokenBreakdown].self, forKey: .byModel) ?? [:]
    }

    /// Reads a Claude Code transcript (JSONL). Streaming writes the same message several
    /// times, so usage is counted once per message id, from its last line.
    public static func fromClaudeTranscript(_ data: Data) -> TokenUsage? {
        var messages: [String: (model: String, usage: [String: Any], output: Int)] = [:]
        var order: [String] = []
        let marker = Data(#""usage""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let id = message["id"] as? String ?? UUID().uuidString
            let model = message["model"] as? String ?? "unknown"
            if messages[id] == nil { order.append(id) }
            messages[id] = (model, usage, max(messages[id]?.output ?? 0, int(usage["output_tokens"])))
        }
        guard let lastID = order.last, let last = messages[lastID]?.usage else { return nil }

        var byModel: [String: TokenBreakdown] = [:]
        for (model, usage, output) in messages.values {
            var b = TokenBreakdown(input: int(usage["input_tokens"]), cacheRead: int(usage["cache_read_input_tokens"]), output: output)
            if let creation = usage["cache_creation"] as? [String: Any] {
                b.cacheWrite5m = int(creation["ephemeral_5m_input_tokens"])
                b.cacheWrite1h = int(creation["ephemeral_1h_input_tokens"])
            } else {
                b.cacheWrite5m = int(usage["cache_creation_input_tokens"])
            }
            byModel[model] = (byModel[model] ?? TokenBreakdown()) + b
        }
        let context = int(last["input_tokens"]) + int(last["cache_read_input_tokens"])
            + int(last["cache_creation_input_tokens"]) + int(last["output_tokens"])
        return TokenUsage(context: context, output: byModel.values.reduce(0) { $0 + $1.output }, byModel: byModel)
    }

    /// Reads a Codex rollout (JSONL); the last `token_count` event has the running totals and
    /// the last `turn_context` names the model.
    public static func fromCodexRollout(_ data: Data) -> TokenUsage? {
        let countMarker = Data(#""token_count""#.utf8)
        let contextMarker = Data(#""turn_context""#.utf8)
        var usage: TokenUsage?
        var model: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            if usage == nil, line.range(of: countMarker) != nil,
               let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let payload = entry["payload"] as? [String: Any],
               let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                let lastUsage = info["last_token_usage"] as? [String: Any] ?? total
                // Codex counts cached input inside input_tokens.
                let cached = int(total["cached_input_tokens"])
                let breakdown = TokenBreakdown(input: max(int(total["input_tokens"]) - cached, 0), cacheRead: cached,
                                               output: int(total["output_tokens"]))
                usage = TokenUsage(context: int(lastUsage["input_tokens"]) + int(lastUsage["output_tokens"]),
                                   output: int(total["output_tokens"]), byModel: ["": breakdown])
            }
            if model == nil, line.range(of: contextMarker) != nil,
               let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               entry["type"] as? String == "turn_context",
               let payload = entry["payload"] as? [String: Any] {
                model = payload["model"] as? String
            }
            if usage != nil, model != nil { break }
        }
        guard var usage else { return nil }
        if let breakdown = usage.byModel[""] { usage.byModel = [model ?? "codex": breakdown] }
        return usage
    }

    private static func int(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    /// 950 → "950", 12_300 → "12.3k", 1_250_000 → "1.25M".
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<100_000: return String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return "\(n / 1_000)k"
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
}
