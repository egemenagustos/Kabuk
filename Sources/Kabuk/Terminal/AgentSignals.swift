import Foundation
import KabukCore
import SwiftTerm

/// What a pane's terminal says about an agent without hooks: the notifications it sends
/// (OSC 9, 99 and 777) and when it last printed anything.
final class AgentSignals: @unchecked Sendable {
    static let codes: Set<Int> = [9, 99, 777]

    private var observation: TerminalOscObservation?
    private let lock = NSLock()
    private var lastOutput = Date()

    @MainActor
    init(view: LocalProcessTerminalView, onNotification: @escaping @MainActor (String) -> Void) {
        observation = view.observeOscEvents { event in
            guard Self.codes.contains(event.code),
                  let text = AgentEvent.notificationText(code: event.code, payload: String(decoding: event.payload, as: UTF8.self))
            else { return }
            DispatchQueue.main.async { onNotification(text) }
        }
        // Runs on the parse thread after every batch of output; only the time is kept.
        view.setProcessOutputHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastOutput = Date()
            self.lock.unlock()
        }
    }

    var quietSince: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastOutput
    }
}
