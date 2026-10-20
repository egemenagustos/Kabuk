import AppKit
import SwiftUI

/// Hosts a pane's long-lived terminal view inside SwiftUI.
struct TerminalPaneView: NSViewRepresentable {
    let paneID: UUID
    let cwd: String
    let isFocused: Bool
    @EnvironmentObject var state: AppState

    func makeNSView(context: Context) -> PaneHostView {
        let host = PaneHostView()
        host.wantsLayer = true
        host.claim(paneID)
        update(host)
        return host
    }

    func updateNSView(_ host: PaneHostView, context: Context) {
        update(host)
    }

    private func update(_ host: PaneHostView) {
        host.wantsFocus = isFocused
        guard host.owns(paneID), let terminal = state.terminals.view(for: paneID, cwd: cwd) else { return }
        host.host(terminal)
        host.focusIfNeeded()
    }
}

/// When the split layout changes SwiftUI builds a new container for a pane while the old one
/// is still animating out, and both get updates. The newest container owns the terminal; an
/// old one never takes it back or moves focus to it.
final class PaneHostView: NSView {
    private static var owners: [UUID: Weak] = [:]
    private struct Weak { weak var host: PaneHostView? }

    var wantsFocus = false
    private weak var terminal: NSView?

    func claim(_ paneID: UUID) {
        Self.owners[paneID] = Weak(host: self)
    }

    /// True for the newest container, or for any container once that one is gone.
    func owns(_ paneID: UUID) -> Bool {
        guard let owner = Self.owners[paneID]?.host else {
            claim(paneID)
            return true
        }
        return owner === self
    }

    func host(_ view: NSView) {
        terminal = view
        guard view.superview !== self else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard wantsFocus else { return }
        // A terminal created a moment ago may not accept focus on the first try, and a new
        // session's container is still joining the window, so check again shortly after.
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.wantsFocus, let terminal = self.terminal, terminal.superview === self,
                      let window = self.window, window.firstResponder !== terminal else { return }
                window.makeFirstResponder(terminal)
            }
        }
    }
}
