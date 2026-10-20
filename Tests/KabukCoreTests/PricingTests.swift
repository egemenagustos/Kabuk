import XCTest
@testable import KabukCore

final class PricingTests: XCTestCase {
    func testPriceLookup() {
        let pricing = Pricing()
        XCTAssertEqual(pricing.price(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(pricing.price(for: "claude-opus-5-5[1m]")?.input, 4)
        // "claude-opus-5" must not swallow "claude-opus-5-5", and vice versa.
        XCTAssertEqual(pricing.price(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(pricing.price(for: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(pricing.price(for: "claude-fable-5")?.cacheRead, 1)
        XCTAssertEqual(pricing.price(for: "claude-sonnet-4-6")?.cacheRead ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertNil(pricing.price(for: "gpt-6.1-sol"))
    }

    func testCost() {
        let price = ModelPrice(input: 4, output: 20, cacheRead: 0.2)
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000,
                                    cacheRead: 1_000_000, output: 1_000_000)
        // 4 + 5 + 8 + 0.2 + 20
        XCTAssertEqual(price.cost(tokens), 37.2, accuracy: 1e-9)

        let usage = TokenUsage(context: 0, output: 0, byModel: [
            "claude-sonnet-5-5": TokenBreakdown(output: 100_000),
            "unknown-model": TokenBreakdown(output: 100_000),
        ])
        XCTAssertEqual(Pricing().cost(usage) ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertNil(Pricing().cost(TokenUsage(context: 0, output: 0, byModel: ["x": TokenBreakdown(output: 5)])))
        XCTAssertEqual(Pricing.format(0.004), "<$0.01")
        XCTAssertEqual(Pricing.format(3.214), "$3.21")
    }

    func testOverrides() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try #"{"models":{"gpt-6.1":{"input":1.5,"output":6,"cacheRead":0.15},"claude-opus-5-5":{"input":1,"output":2}}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let pricing = Pricing.load(overrides: url)
        XCTAssertEqual(pricing.price(for: "gpt-6.1-sol")?.output, 6)
        XCTAssertEqual(pricing.price(for: "claude-opus-5-5")?.input, 1)
        XCTAssertEqual(pricing.price(for: "claude-sonnet-5-5")?.input, 2)
    }

    func testUsageBookCountsIncreasesOnly() {
        var book = UsageBook()
        XCTAssertEqual(book.record(session: "s1", agent: "claude", cumulative: 0.50, day: "2026-10-20")?.cost, 0.50)
        XCTAssertEqual(book.record(session: "s1", agent: "claude", cumulative: 0.80, day: "2026-10-20")?.cost ?? 0, 0.30, accuracy: 1e-9)
        XCTAssertNil(book.record(session: "s1", agent: "claude", cumulative: 0.80, day: "2026-10-20"))
        book.record(session: "c1", agent: "codex", cumulative: 0.25, day: "2026-10-21")
        XCTAssertEqual(book.total(on: "2026-10-20"), 0.80, accuracy: 1e-9)
        XCTAssertEqual(book.total(on: "2026-10-21", agent: "codex"), 0.25, accuracy: 1e-9)
        XCTAssertEqual(book.total(on: "2026-10-21", agent: "claude"), 0)

        let data = try! JSONEncoder().encode(book)
        XCTAssertEqual(try! JSONDecoder().decode(UsageBook.self, from: data), book)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(UsageBook.day(Date(timeIntervalSince1970: 0), calendar: calendar), "1970-01-01")
    }
}
