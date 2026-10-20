import Foundation
import KabukCore

/// Polls listening TCP ports and maps them to panes through each shell's process tree.
/// One `lsof` and one `ps` per scan cover every pane.
@MainActor
final class PortMonitor {
    var onUpdate: (([UUID: [Int]]) -> Void)?
    /// Asked before each periodic scan; scanning is skipped when nothing could own a port.
    var shouldScan: (() -> Bool)?
    /// Each pane's shell process.
    var shells: (() -> [UUID: Int32])?
    private var timer: Timer?
    private var scanning = false
    private let queue = DispatchQueue(label: "kabuk.ports", qos: .utility)

    func start(interval: TimeInterval = 3) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shouldScan?() ?? false else { return }
                self.scan()
            }
        }
    }

    /// Scans soon, e.g. right after a server was started.
    func scan(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.scanning, let shells = self.shells?(), !shells.isEmpty else { return }
            self.scanning = true
            self.queue.async {
                let lsof = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
                let ps = Shell.run("/bin/ps", ["-axo", "pid=,ppid="])
                let listening = PortScan.parseLsof(lsof.stdout)
                let parents = PortScan.parsePs(ps.stdout)
                let result = shells.mapValues { PortScan.ports(root: $0, listening: listening, parents: parents) }
                DispatchQueue.main.async {
                    self.scanning = false
                    self.onUpdate?(result)
                }
            }
        }
    }
}
