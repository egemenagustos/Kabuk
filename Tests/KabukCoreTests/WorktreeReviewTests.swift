import XCTest
@testable import KabukCore

final class WorktreeReviewTests: XCTestCase {
    func testParseLog() {
        let commits = WorktreeReview.parseLog("a1b2c3d\tAdd scores\n9f8e7d6\tFix: tabs\tin subject\n\n")
        XCTAssertEqual(commits, [WorktreeCommit(hash: "a1b2c3d", subject: "Add scores"),
                                 WorktreeCommit(hash: "9f8e7d6", subject: "Fix: tabs\tin subject")])
    }

    func testSquashMessageListsOldestFirst() {
        let one = [WorktreeCommit(hash: "a", subject: "Add scores")]
        XCTAssertEqual(WorktreeReview.squashMessage(branch: "kabuk/claude-1a2b", commits: one), "Add scores")
        let two = [WorktreeCommit(hash: "b", subject: "Second"), WorktreeCommit(hash: "a", subject: "First")]
        XCTAssertEqual(WorktreeReview.squashMessage(branch: "kabuk/claude-1a2b", commits: two),
                       "Merge kabuk/claude-1a2b\n\n- First\n- Second")
    }

    func testMergeBlockers() {
        var summary = WorktreeSummary(target: "main", commits: [WorktreeCommit(hash: "a", subject: "x")], change: nil,
                                      dirty: false, targetDirty: false)
        XCTAssertNil(summary.mergeBlocker)
        summary.dirty = true
        XCTAssertNotNil(summary.mergeBlocker)
        summary.dirty = false
        summary.targetDirty = true
        XCTAssertTrue(summary.mergeBlocker!.hasPrefix("main has uncommitted"))
        summary.targetDirty = false
        summary.commits = []
        XCTAssertNotNil(summary.mergeBlocker)
    }

    func testDefaultCommitMessage() {
        XCTAssertEqual(WorktreeReview.defaultCommitMessage(nil), "Work in progress")
        let change = TurnChange(files: [FileChange(path: "a.swift", added: 1, removed: 0)], base: "b", top: "/t")
        XCTAssertEqual(WorktreeReview.defaultCommitMessage(change), "Update a.swift")
    }
}
