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

    func testUndoRestoresWhatTheSnapshotHoldsAndDeletesTheRest() {
        let steps = TurnUndo.steps(paths: ["snake.mjs", "scores.json", "gone.txt"], inSnapshot: ["snake.mjs", "gone.txt"])
        XCTAssertEqual(steps, [.restore("snake.mjs"), .delete("scores.json"), .restore("gone.txt")])
    }

    func testUndoSummary() {
        let files = (1...10).map { FileChange(path: "f\($0).swift", added: 1, removed: 0) }
        let change = TurnChange(files: files, base: "b", top: "/r", snapshot: "s", head: "h")
        let text = TurnUndo.summary(change, commits: 2)
        XCTAssertTrue(text.hasPrefix("• f1.swift\n"))
        XCTAssertTrue(text.contains("and 2 more"))
        XCTAssertFalse(text.contains("f9.swift"))
        XCTAssertTrue(text.contains("2 commits"))
        XCTAssertFalse(TurnUndo.summary(change, commits: 0).contains("commit"))
    }

    func testBaselineCarriesItsSnapshot() {
        let before = TurnBaseline(base: "abc", top: "/repo", untracked: [:], snapshot: "snap", head: "head")
        let change = TurnDiff.change(numstat: "1\t0\ta\n", before: before, untrackedAfter: [:], lineCount: { _ in nil })
        XCTAssertEqual(change.snapshot, "snap")
        XCTAssertEqual(change.head, "head")
    }

    func testDiffLineNumbers() {
        let diff = """
        --- a/x
        +++ b/x
        @@ -10,3 +10,3 @@ func x() {
         same
        -old
        +new
         tail
        """
        let lines = DiffLine.classify(diff)
        XCTAssertEqual(lines[3].newLine, 10)
        XCTAssertEqual(lines[3].oldLine, 10)
        XCTAssertEqual(lines[4].oldLine, 11)
        XCTAssertNil(lines[4].newLine)
        XCTAssertEqual(lines[5].newLine, 11)
        XCTAssertEqual(lines[5].code, "new")
        XCTAssertEqual(lines[6].newLine, 12)
        XCTAssertEqual(DiffLine.allAdded("a\nb")[1].newLine, 2)
        XCTAssertEqual(DiffLine.classify("@@ -1 +1 @@\n-a\n+b\n").count, 3)
    }

    func testReviewPrompt() {
        let lines = DiffLine.classify("@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2")
        let prompt = ReviewPrompt.build([
            DiffComment(path: "a.swift", diffLine: lines[2], note: "Why 2? Use a constant."),
            DiffComment(path: "a.swift", diffLine: lines[1], note: "Keep this line."),
        ])
        XCTAssertTrue(prompt.contains("- a.swift:1\n  `let a = 2`\n  Why 2? Use a constant."))
        XCTAssertTrue(prompt.contains("- a.swift:1 (removed line)\n  `let a = 1`\n  Keep this line."))
        XCTAssertTrue(prompt.hasSuffix("Please address each note."))
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
