import XCTest
@testable import KabukCore

final class HookEventTests: XCTestCase {
    func testParsesShellLine() {
        let line = #"{"pane":"abc","source":"shell","event":"end","code":2,"cwd":"/tmp/a b"}"#
        let event = HookEvent.parse(Data(line.utf8))
        XCTAssertEqual(event, HookEvent(pane: "abc", source: "shell", event: "end", code: 2, cwd: "/tmp/a b"))
    }

    func testParseAllSkipsGarbage() {
        let payload = """
        {"pane":"a","source":"shell","event":"start","cmd":"ls \\"x\\""}
        not json
        {"pane":"a","source":"shell","event":"end","code":0}

        """
        let events = HookEvent.parseAll(Data(payload.utf8))
        XCTAssertEqual(events.map(\.event), ["start", "end"])
        XCTAssertEqual(events.first?.cmd, #"ls "x""#)
    }

    func testRoundTrip() {
        let event = HookEvent(pane: "p", source: "claude", event: "Notification", message: "çalışıyor ✳")
        XCTAssertEqual(HookEvent.parseAll(event.encodedLine()), [event])
    }

    func testFuzzy() {
        XCTAssertNotNil(FuzzyMatcher.score("spr", in: "Split right"))
        XCTAssertNil(FuzzyMatcher.score("xyz", in: "New session"))
        let prefix = FuzzyMatcher.score("new", in: "New session")!
        let scattered = FuzzyMatcher.score("new", in: "Install agent hooks now, will")
        XCTAssertGreaterThan(prefix, scattered ?? Int.min)
    }
}
