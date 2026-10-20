import XCTest
@testable import KabukCore

final class TurnChangeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 100)
    let t1 = Date(timeIntervalSince1970: 200)

    func testNumstat() {
        let files = TurnDiff.parseNumstat("12\t3\tsrc/snake.mjs\n-\t-\tlogo.png\n0\t7\tdocs/a b.md\n")
        XCTAssertEqual(files, [
            FileChange(path: "src/snake.mjs", added: 12, removed: 3),
            FileChange(path: "logo.png", added: nil, removed: nil),
            FileChange(path: "docs/a b.md", added: 0, removed: 7),
        ])
    }

    func testUntrackedFilesNewAndChanged() {
        let before = TurnBaseline(base: "abc", top: "/repo", untracked: ["notes.md": t0, "scratch.txt": t0])
        let after = ["notes.md": t0, "scratch.txt": t1, "scores.json": t1]
        let change = TurnDiff.change(numstat: "4\t1\tsnake.mjs\n", before: before, untrackedAfter: after,
                                     lineCount: { $0 == "scores.json" ? 20 : nil }, now: t1)
        XCTAssertEqual(change.files.map(\.path), ["snake.mjs", "scores.json", "scratch.txt"])
        XCTAssertEqual(change.files[1], FileChange(path: "scores.json", added: 20, removed: 0, isNew: true))
        XCTAssertEqual(change.files[2], FileChange(path: "scratch.txt", added: nil, removed: nil))
        XCTAssertEqual(change.added, 24)
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(change.base, "abc")
    }

    func testDiffClassification() {
        let diff = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1,2 +1,2 @@
         same
        -old
        +new
        """
        XCTAssertEqual(DiffLine.classify(diff).map(\.kind), [.header, .header, .header, .header, .hunk, .context, .remove, .add])
        XCTAssertEqual(DiffLine.allAdded("a\nb").map(\.text), ["+a", "+b"])
    }
}
