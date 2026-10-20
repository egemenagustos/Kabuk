import Foundation

/// Dollars per million tokens for one model.
public struct ModelPrice: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Defaults to 1.25× input (5-minute cache writes).
    public var cacheWrite5m: Double?
    /// Defaults to 2× input (1-hour cache writes).
    public var cacheWrite1h: Double?

    public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead ?? input * 0.1
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// `cacheRead` may be left out of pricing.json; it then defaults to 0.1× input.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(input: try c.decode(Double.self, forKey: .input),
                  output: try c.decode(Double.self, forKey: .output),
                  cacheRead: try c.decodeIfPresent(Double.self, forKey: .cacheRead),
                  cacheWrite5m: try c.decodeIfPresent(Double.self, forKey: .cacheWrite5m),
                  cacheWrite1h: try c.decodeIfPresent(Double.self, forKey: .cacheWrite1h))
    }

    public func cost(_ t: TokenBreakdown) -> Double {
        let dollars = Double(t.input) * input
            + Double(t.cacheWrite5m) * (cacheWrite5m ?? input * 1.25)
            + Double(t.cacheWrite1h) * (cacheWrite1h ?? input * 2)
            + Double(t.cacheRead) * cacheRead
            + Double(t.output) * output
        return dollars / 1_000_000
    }
}

/// API list prices, with optional overrides from `pricing.json`. Costs shown in Kabuk are the
/// API-equivalent value; on a subscription the user isn't billed per token.
public struct Pricing: Sendable {
    public var models: [String: ModelPrice]

    /// Anthropic first-party API prices (cached 2026-10-06). Ids match by prefix.
    public static let anthropic: [String: ModelPrice] = [
        "claude-fable-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-mythos-5-1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        "claude-mythos-5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": ModelPrice(input: 5, output: 25),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25),
        "claude-opus-4-7": ModelPrice(input: 5, output: 25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15),
        "claude-haiku-5-5": ModelPrice(input: 0.10, output: 0.50),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5),
    ]

    public init(models: [String: ModelPrice] = Pricing.anthropic) {
        self.models = models
    }

    /// Built-in prices with a user file's `{"models": {"id": {...}}}` layered on top.
    public static func load(overrides url: URL) -> Pricing {
        var pricing = Pricing()
        struct File: Decodable { var models: [String: ModelPrice] }
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            pricing.models.merge(file.models) { _, user in user }
        }
        return pricing
    }

    /// The longest matching id prefix, ignoring suffixes such as "[1m]".
    public func price(for model: String) -> ModelPrice? {
        let id = model.split(separator: "[").first.map(String.init) ?? model
        if let exact = models[id] { return exact }
        return models.filter { id.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
    }

    /// The session's cost, or nil when none of its models has a known price.
    public func cost(_ usage: TokenUsage) -> Double? {
        let priced = usage.byModel.compactMap { model, tokens in price(for: model).map { $0.cost(tokens) } }
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    public static func format(_ dollars: Double) -> String {
        dollars < 0.01 && dollars > 0 ? "<$0.01" : String(format: "$%.2f", dollars)
    }
}

/// Day-by-day spending. Agents report their session's running cost; the book records only
/// the increase since it last heard from that session, so restarts never count twice.
public struct UsageBook: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var day: String
        public var agent: String
        public var session: String
        public var cost: Double
    }

    public var lastCost: [String: Double] = [:]
    public var entries: [Entry] = []

    public init() {}

    @discardableResult
    public mutating func record(session: String, agent: String, cumulative: Double, day: String) -> Entry? {
        let delta = cumulative - (lastCost[session] ?? 0)
        lastCost[session] = max(cumulative, lastCost[session] ?? 0)
        guard delta > 0.000001 else { return nil }
        let entry = Entry(day: day, agent: agent, session: session, cost: delta)
        entries.append(entry)
        return entry
    }

    public func total(on day: String, agent: String? = nil) -> Double {
        entries.filter { $0.day == day && (agent == nil || $0.agent == agent) }.reduce(0) { $0 + $1.cost }
    }

    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
