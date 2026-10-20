import XCTest
@testable import KabukCore

final class PaneNodeTests: XCTestCase {
    let a = Pane(cwd: "/a"), b = Pane(cwd: "/b"), c = Pane(cwd: "/c")

    func testSplitAndRemove() {
        var root = PaneNode.leaf(a)
        root = root.splitting(a.id, axis: .horizontal, newPane: b)
        XCTAssertEqual(root.paneIDs, [a.id, b.id])

        // Same-axis split stays flat.
        root = root.splitting(b.id, axis: .horizontal, newPane: c)
        guard case .split(_, _, let children, let fractions) = root else { return XCTFail() }
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(fractions, [0.5, 0.25, 0.25])

        let removed = root.removing(a.id)!
        guard case .split(_, _, _, let rest) = removed else { return XCTFail() }
        XCTAssertEqual(rest, [0.5, 0.5])
        XCTAssertEqual(removed.removing(b.id), .leaf(c))
        XCTAssertNil(PaneNode.leaf(a).removing(a.id))
    }

    func testNestedSplitAndNeighbors() {
        // a | (b over c)
        var root = PaneNode.leaf(a).splitting(a.id, axis: .horizontal, newPane: b)
        root = root.splitting(b.id, axis: .vertical, newPane: c)
        XCTAssertEqual(root.neighbor(of: a.id, .right), b.id)
        XCTAssertEqual(root.neighbor(of: b.id, .down), c.id)
        XCTAssertEqual(root.neighbor(of: c.id, .up), b.id)
        XCTAssertEqual(root.neighbor(of: c.id, .left), a.id)
        XCTAssertNil(root.neighbor(of: a.id, .left))
    }

    func testCodableRoundTrip() throws {
        let root = PaneNode.leaf(a).splitting(a.id, axis: .vertical, newPane: b)
        let data = try JSONEncoder().encode(root)
        XCTAssertEqual(try JSONDecoder().decode(PaneNode.self, from: data), root)
    }
}
