import XCTest
@testable import KabukCore

final class PlanLimitsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_180_000)

    func testClaudeStatusLine() throws {
        let json = """
        {"session_id":"s","model":{"id":"claude-opus-5-5"},
         "rate_limits":{"five_hour":{"used_percentage":68.4,"resets_at":1792189760},
                        "seven_day":{"used_percentage":21,"resets_at":1792758374}}}
        """
        let limits = try XCTUnwrap(PlanLimits.fromClaudeStatusLine(Data(json.utf8), now: now))
        XCTAssertEqual(limits.fiveHour, LimitWindow(usedPercent: 68.4, resetsAt: Date(timeIntervalSince1970: 1_792_189_760)))
        XCTAssertEqual(limits.weekly?.usedPercent, 21)
        XCTAssertEqual(limits.updatedAt, now)
    }

    func testClaudeStatusLineWithoutLimits() {
        XCTAssertNil(PlanLimits.fromClaudeStatusLine(Data(#"{"session_id":"s"}"#.utf8)))
        XCTAssertNil(PlanLimits.fromClaudeStatusLine(Data(#"{"rate_limits":{}}"#.utf8)))
        XCTAssertNil(PlanLimits.fromClaudeStatusLine(Data("not json".utf8)))
    }

    func testClaudeStatusLineWithOnlyOneWindow() throws {
        let json = #"{"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1792758374}}}"#
        let limits = try XCTUnwrap(PlanLimits.fromClaudeStatusLine(Data(json.utf8)))
        XCTAssertNil(limits.fiveHour)
        XCTAssertEqual(limits.weekly?.usedPercent, 5)
    }

    func testCodexRolloutTakesTheLastReport() throws {
        func line(_ fiveHour: Double, _ weekly: Double) -> String {
            // Windows matched by length, not by primary/secondary.
            """
            {"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex",\
            "primary":{"used_percent":\(weekly),"window_minutes":10080,"resets_at":1792758374},\
            "secondary":{"used_percent":\(fiveHour),"window_minutes":300,"resets_at":1792189760},"plan_type":"plus"}}}
            """
        }
        let rollout = [
            line(10, 4),
            line(17, 8),
            #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":null}}"#,
        ].joined(separator: "\n")
        let limits = try XCTUnwrap(PlanLimits.fromCodexRollout(Data(rollout.utf8), now: now))
        XCTAssertEqual(limits.fiveHour?.usedPercent, 17)
        XCTAssertEqual(limits.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_792_189_760))
        XCTAssertEqual(limits.weekly?.usedPercent, 8)
    }

    func testCodexFreePlanHasOneLongWindow() throws {
        let rollout = """
        {"type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex",\
        "primary":{"used_percent":3.0,"window_minutes":43200,"resets_at":1795099054},"secondary":null,"plan_type":"free"}}}
        """
        let limits = try XCTUnwrap(PlanLimits.fromCodexRollout(Data(rollout.utf8), now: now))
        XCTAssertNil(limits.fiveHour)
        XCTAssertEqual(limits.weekly, LimitWindow(usedPercent: 3, resetsAt: Date(timeIntervalSince1970: 1_795_099_054), length: 30 * 86400))
        XCTAssertEqual(limits.current(at: Date(timeIntervalSince1970: 1_795_100_000)).weekly?.length, 30 * 86400,
                       "a reset keeps the window's length")
    }

    func testCodexRolloutWithoutLimits() {
        let rollout = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{}}}}"#
        XCTAssertNil(PlanLimits.fromCodexRollout(Data(rollout.utf8)))
    }

    func testPassedResetEmptiesTheWindow() {
        let limits = PlanLimits(fiveHour: LimitWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(-1)),
                                weekly: LimitWindow(usedPercent: 40, resetsAt: now.addingTimeInterval(3600)), updatedAt: now)
        let current = limits.current(at: now)
        XCTAssertEqual(current.fiveHour?.usedPercent, 0)
        XCTAssertNil(current.fiveHour?.resetsAt)
        XCTAssertEqual(current.weekly, limits.weekly)
    }

    func testElapsedShowsThePace() {
        let window = LimitWindow(usedPercent: 54, resetsAt: now.addingTimeInterval(2 * 3600))
        XCTAssertEqual(window.elapsed(of: PlanLimits.fiveHourLength, at: now)!, 0.6, accuracy: 0.0001)
        XCTAssertEqual(window.elapsed(of: PlanLimits.fiveHourLength, at: now.addingTimeInterval(3 * 3600)), 1)
        XCTAssertEqual(window.elapsed(of: 3600, at: now), 0, "a reset further away than the window clamps to its start")
        XCTAssertNil(LimitWindow(usedPercent: 5).elapsed(of: PlanLimits.weeklyLength, at: now))
    }

    func testHookEventCarriesLimits() throws {
        let limits = PlanLimits(fiveHour: LimitWindow(usedPercent: 12, resetsAt: now), updatedAt: now)
        let event = HookEvent(pane: "p", source: "claude", event: "StatusLine", limits: limits)
        XCTAssertEqual(HookEvent.parse(event.encodedLine().dropLast()), event)
        XCTAssertNil(HookEvent.parse(Data(#"{"pane":"p","source":"shell","event":"end"}"#.utf8))?.limits)
    }
}
