import Foundation

/// Finds the TCP ports a pane's processes listen on, from `lsof` and `ps` output.
public enum PortScan {
    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpn`: "p<pid>" lines followed by "n<address>:<port>".
    public static func parseLsof(_ text: String) -> [Int32: Set<Int>] {
        var result: [Int32: Set<Int>] = [:]
        var pid: Int32?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") {
                pid = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid, let colon = line.lastIndex(of: ":"),
                      let port = Int(line[line.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result
    }

    /// Parses `ps -axo pid=,ppid=` into child → parent.
    public static func parsePs(_ text: String) -> [Int32: Int32] {
        var result: [Int32: Int32] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { continue }
            result[pid] = ppid
        }
        return result
    }

    /// The root and every process below it.
    public static func tree(of root: Int32, parents: [Int32: Int32]) -> Set<Int32> {
        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in parents { children[ppid, default: []].append(pid) }
        var result: Set<Int32> = [root]
        var stack = [root]
        while let pid = stack.popLast() {
            for child in children[pid] ?? [] where result.insert(child).inserted {
                stack.append(child)
            }
        }
        return result
    }

    public static func ports(root: Int32, listening: [Int32: Set<Int>], parents: [Int32: Int32]) -> [Int] {
        let pids = tree(of: root, parents: parents)
        return Array(Set(pids.flatMap { listening[$0] ?? [] })).sorted()
    }
}
