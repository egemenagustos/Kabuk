import Foundation
import KabukCore

/// Keeps the day-by-day spending book on disk and answers "how much today".
@MainActor
final class UsageLedger: ObservableObject {
    @Published private(set) var book: UsageBook
    @Published private(set) var pricing: Pricing

    static var bookURL: URL { ShellIntegration.supportDir.appendingPathComponent("usage.json") }
    static var pricingURL: URL { ShellIntegration.supportDir.appendingPathComponent("pricing.json") }

    init() {
        book = (try? Data(contentsOf: Self.bookURL)).flatMap { try? JSONDecoder().decode(UsageBook.self, from: $0) } ?? UsageBook()
        pricing = Pricing.load(overrides: Self.pricingURL)
    }

    func reloadPricing() {
        pricing = Pricing.load(overrides: Self.pricingURL)
    }

    /// Records the growth of an agent session's running cost.
    func record(_ event: HookEvent, agent: AgentKind) {
        guard let session = event.session, let tokens = event.tokens, let cost = pricing.cost(tokens) else { return }
        guard book.record(session: "\(agent.rawValue):\(session)", agent: agent.rawValue, cumulative: cost,
                          day: UsageBook.day(Date())) != nil else { return }
        let book = book, url = Self.bookURL, folder = ShellIntegration.supportDir
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(book).write(to: url, options: .atomic)
        }
    }

    func cost(of tokens: TokenUsage?) -> Double? {
        tokens.flatMap { pricing.cost($0) }
    }

    var today: Double { book.total(on: UsageBook.day(Date())) }

    /// "Mon $1.20" lines for the last seven days, newest first, plus per-agent totals for today.
    var summary: String {
        let calendar = Calendar.current
        var lines = ["API-equivalent cost of agent sessions in Kabuk.", ""]
        let todayKey = UsageBook.day(Date())
        for agent in AgentKind.allCases {
            let total = book.total(on: todayKey, agent: agent.rawValue)
            if total > 0 { lines.append("Today, \(agent.displayName): \(Pricing.format(total))") }
        }
        lines.append("")
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let total = book.total(on: UsageBook.day(date))
            lines.append("\(formatter.string(from: date)): \(Pricing.format(total))")
        }
        return lines.joined(separator: "\n")
    }
}
