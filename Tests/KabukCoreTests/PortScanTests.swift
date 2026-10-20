import XCTest
@testable import KabukCore

final class PortScanTests: XCTestCase {
    func testParseLsof() {
        let lsof = "p501\nf12\nn*:5173\nf13\nn[::1]:5173\np777\nn127.0.0.1:8765\np900\nnlocalhost:3000\n"
        XCTAssertEqual(PortScan.parseLsof(lsof), [501: [5173], 777: [8765], 900: [3000]])
    }

    func testPortsOfProcessTree() {
        // zsh 100 → npm 200 → node 300 (listens), and an unrelated 400.
        let parents = PortScan.parsePs("  100     1\n  200   100\n  300   200\n  400     1\n")
        XCTAssertEqual(parents[300], 200)
        XCTAssertEqual(PortScan.tree(of: 100, parents: parents), [100, 200, 300])
        let listening: [Int32: Set<Int>] = [300: [5173, 24678], 400: [8080]]
        XCTAssertEqual(PortScan.ports(root: 100, listening: listening, parents: parents), [5173, 24678])
        XCTAssertEqual(PortScan.ports(root: 400, listening: listening, parents: parents), [8080])
        XCTAssertEqual(PortScan.ports(root: 999, listening: listening, parents: parents), [])
    }
}
