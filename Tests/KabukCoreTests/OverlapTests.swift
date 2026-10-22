import XCTest
@testable import KabukCore

final class OverlapTests: XCTestCase {
    func testConflictedPathsFollowTheTreeID() {
        XCTAssertEqual(Overlaps.conflictedPaths(mergeTree: "e8750f9fc877\0f.txt\0Sources/a b.swift\0"),
                       ["f.txt", "Sources/a b.swift"])
        XCTAssertEqual(Overlaps.conflictedPaths(mergeTree: "e8750f9fc877\0"), [])
        XCTAssertEqual(Overlaps.conflictedPaths(mergeTree: ""), [])
    }

    func testHunksUseOldSideLines() {
        let diff = """
        diff --git f.txt f.txt
        index 71ac1b5..356d544 100644
        --- f.txt
        +++ f.txt
        @@ -2 +2 @@ a
        -b
        +B
        @@ -8,0 +9,2 @@ h
        +x
        +y
        @@ -40,21 +42,3 @@ func run()
        diff --git gone.swift gone.swift
        deleted file mode 100644
        --- gone.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        diff --git new.md new.md
        new file mode 100644
        --- /dev/null
        +++ new.md
        @@ -0,0 +1,2 @@
        diff --git logo.png logo.png
        Binary files logo.png and logo.png differ
        """
        let hunks = Overlaps.hunks(diff: diff)
        XCTAssertEqual(hunks["f.txt"], [LineRange(start: 2, count: 1), LineRange(start: 8, count: 0), LineRange(start: 40, count: 21)])
        XCTAssertEqual(hunks["gone.swift"], [LineRange(start: 1, count: 3)])
        XCTAssertEqual(hunks["new.md"], [LineRange(start: 0, count: 0)])
        XCTAssertNil(hunks["logo.png"])
    }

    /// Lines whose text starts with "-- " or "++ " look like file headers once diffed; a name
    /// with a space in it ends with a tab.
    func testHunkBodiesAndSpacedNames() {
        let diff = "diff --git a b.sql a b.sql\nindex 6e9d980..80115cb 100644\n--- a b.sql\t\n+++ a b.sql\t\n"
            + "@@ -2 +2 @@ x\n--- old comment\n+++ new\n@@ -9,2 +9 @@\n-x\n-y\n+z\n"
        XCTAssertEqual(Overlaps.hunks(diff: diff), ["a b.sql": [LineRange(start: 2, count: 1), LineRange(start: 9, count: 2)]])
    }

    func testFilesAreTheIntersectionWithConflictsFirst() {
        let files = Overlaps.files(mine: ["b.txt", "a.txt", "mine-only.txt"], theirs: ["a.txt", "b.txt", "theirs-only.txt"],
                                   theirHunks: ["b.txt": [LineRange(start: 4, count: 2)]], conflicted: ["b.txt"])
        XCTAssertEqual(files, [OverlapFile(path: "b.txt", conflict: true, theirLines: [LineRange(start: 4, count: 2)]),
                               OverlapFile(path: "a.txt", conflict: false)])
        XCTAssertEqual(Overlaps.files(mine: ["a"], theirs: ["b"], theirHunks: [:], conflicted: []), [])
    }

    func testDescribe() {
        XCTAssertEqual(Overlaps.describe([LineRange(start: 2, count: 1)]), "changes line 2")
        XCTAssertEqual(Overlaps.describe([LineRange(start: 2, count: 1), LineRange(start: 40, count: 21)]), "changes lines 2, 40–60")
        XCTAssertEqual(Overlaps.describe([LineRange(start: 40, count: 3), LineRange(start: 8, count: 0)]),
                       "changes lines 40–42 and adds lines after line 8")
        XCTAssertEqual(Overlaps.describe([LineRange(start: 0, count: 0)]), "adds lines at the top")
        XCTAssertEqual(Overlaps.describe([LineRange(start: 1, count: 0), LineRange(start: 6, count: 0), LineRange(start: 9, count: 1)]),
                       "changes line 9 and adds lines after lines 1, 6")
        XCTAssertEqual(Overlaps.describe([LineRange(start: 0, count: 0), LineRange(start: 6, count: 0)]),
                       "adds lines at the top and after line 6")
        XCTAssertEqual(Overlaps.describe([]), "")
        let many = (1...8).map { LineRange(start: $0 * 10, count: 1) }
        XCTAssertEqual(Overlaps.describe(many), "changes lines 10, 20, 30, 40, 50, 60 (2 more places)")
    }

    func testPromptListsConflictsThenTheRest() {
        let overlap = Overlap(other: "/wt/codex-b7", otherBranch: "kabuk/codex-b7", files: [
            OverlapFile(path: "Auth.swift", conflict: true, theirLines: [LineRange(start: 40, count: 21)]),
            OverlapFile(path: "README.md", conflict: false),
        ])
        let prompt = OverlapPrompt.build(overlap, otherName: "Codex", otherFolder: "~/.kabuk/worktrees/app/codex-b7")
        XCTAssertTrue(prompt.hasPrefix("Heads-up from Kabuk: you and Codex are changing the same files in parallel. It works on branch kabuk/codex-b7, in ~/.kabuk/worktrees/app/codex-b7."))
        XCTAssertTrue(prompt.contains("Merging both branches would conflict in:\n- Auth.swift, where it changes lines 40–60"))
        XCTAssertTrue(prompt.contains("Both of you also change, without conflicting yet:\n- README.md\n"))

        let quiet = Overlap(other: "/r", otherBranch: "main", files: [OverlapFile(path: "a.txt", conflict: false)])
        let text = OverlapPrompt.build(quiet, otherName: "whoever works in the main checkout", otherFolder: "~/src/app")
        XCTAssertTrue(text.contains("The changes don't conflict yet, in:\n- a.txt"))
        XCTAssertFalse(text.contains("would conflict"))
    }
}
