import Foundation
import SwiftTerm

/// A failed command's output as it appeared in the terminal.
struct CapturedFailure: Equatable {
    var code: Int32
    var output: String
}

/// Reads back what a command printed, using the OSC 6973 marks the zsh integration writes
/// around it: `C` when the command starts, `D;<code>` when it ends.
///
/// Each mark comes with the screen row of the cursor. Counting the buffer's lines turns that
/// into a row from the top of the scrollback. If the scrollback drops old lines while a
/// command runs, the start shifts down and only the beginning of the output is lost; the
/// end, where errors usually are, stays exact.
final class OutputCapture: @unchecked Sendable {
    static let oscCode = 6973
    /// Longer output keeps only its last lines.
    static let maxLines = 200

    private weak var view: LocalProcessTerminalView?
    private var observation: TerminalOscObservation?
    private let lock = NSLock()
    private var startRow: Int?

    @MainActor
    init(view: LocalProcessTerminalView, onFailure: @escaping @MainActor (CapturedFailure) -> Void) {
        self.view = view
        observation = view.observeOscEvents { [weak self] event in
            guard event.code == Self.oscCode, let self else { return }
            self.handle(String(decoding: event.payload, as: UTF8.self), cursorRow: event.cursor.row, onFailure: onFailure)
        }
    }

    private func handle(_ mark: String, cursorRow: Int, onFailure: @escaping @MainActor (CapturedFailure) -> Void) {
        guard let view else { return }
        let lines = Self.lines(view.getBufferAsData())
        let row = max(lines.count - view.terminalDimensions.rows + cursorRow, 0)
        if mark == "C" {
            lock.withLock { startRow = row }
            return
        }
        guard mark.hasPrefix("D") else { return }
        let start = lock.withLock { () -> Int? in
            defer { startRow = nil }
            return startRow
        }
        let code = Int32(mark.split(separator: ";").dropFirst().first ?? "") ?? 0
        // 130 is ctrl-c: the user stopped it, nothing to diagnose.
        guard let start, code != 0, code != 130 else { return }
        let output = Self.text(lines, from: start, to: row)
        DispatchQueue.main.async { onFailure(CapturedFailure(code: code, output: output)) }
    }

    static func lines(_ data: Data) -> [Substring] {
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func text(_ lines: [Substring], from start: Int, to end: Int) -> String {
        let end = min(end, lines.count)
        let first = max(start, end - maxLines, 0)
        guard end > first else { return "" }
        var kept = lines[first..<end].map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while kept.last?.isEmpty == true { kept.removeLast() }
        while kept.first?.isEmpty == true { kept.removeFirst() }
        return kept.joined(separator: "\n")
    }
}
