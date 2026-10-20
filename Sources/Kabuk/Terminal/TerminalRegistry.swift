import AppKit
import KabukCore
import SwiftTerm

/// A terminal view that tells Kabuk when the user presses return.
final class KabukTerminalView: LocalProcessTerminalView {
    let paneID: UUID
    var onSubmit: ((UUID) -> Void)?

    init(paneID: UUID) {
        self.paneID = paneID
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Draw with SwiftTerm's Metal renderer: glyphs come from a GPU atlas and frames are
    /// prepared off the main thread, where Core Graphics re-typesets every dirty row on it.
    /// SwiftTerm needs a window before it can bind the Metal surface; if Metal can't start,
    /// the view keeps drawing with Core Graphics.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isUsingMetalRenderer {
            try? setUseMetal(true)
        }
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if data.contains(13) { onSubmit?(paneID) }
        super.send(source: source, data: data)
    }
}

/// Owns every pane's terminal view so shells keep running while their session is off screen.
@MainActor
final class TerminalRegistry: NSObject, LocalProcessTerminalViewDelegate {
    private(set) var views: [UUID: KabukTerminalView] = [:]
    /// Panes that were closed. SwiftUI may still update their views while the close animation
    /// runs, and that must not start a fresh shell.
    private var closed: Set<UUID> = []
    var onSubmit: ((UUID) -> Void)?
    var onExit: ((UUID) -> Void)?
    var onCommandStart: ((UUID) -> Void)?
    var onFailure: ((UUID, CapturedFailure) -> Void)?
    private var captures: [UUID: OutputCapture] = [:]
    /// SwiftTerm keeps 500 lines by default; a terminal you live in needs more.
    static let scrollback = 10_000
    var fontSize: CGFloat = 13 {
        didSet { views.values.forEach { $0.font = Theme.terminalFont(size: fontSize) } }
    }
    var theme: TerminalTheme = .kabuk {
        didSet { views.values.forEach { Theme.apply(theme, to: $0) } }
    }

    func view(for paneID: UUID, cwd: String) -> KabukTerminalView? {
        if let existing = views[paneID] { return existing }
        guard !closed.contains(paneID) else { return nil }
        let view = KabukTerminalView(paneID: paneID)
        view.font = Theme.terminalFont(size: fontSize)
        Theme.apply(theme, to: view)
        view.optionAsMetaKey = false
        view.processDelegate = self
        view.onSubmit = { [weak self] in self?.onSubmit?($0) }
        views[paneID] = view
        view.changeScrollback(Self.scrollback)
        captures[paneID] = OutputCapture(view: view, onStart: { [weak self] in
            self?.onCommandStart?(paneID)
        }, onFailure: { [weak self] failure in
            self?.onFailure?(paneID, failure)
        })

        let shell = ShellIntegration.userShell
        let directory = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        view.startProcess(executable: shell, args: ["-l"],
                          environment: ShellIntegration.environment(paneID: paneID),
                          execName: "-" + (shell as NSString).lastPathComponent,
                          currentDirectory: directory)
        return view
    }

    /// Each running pane's shell process id.
    var shellPIDs: [UUID: Int32] {
        views.compactMapValues { view in
            let pid = view.process?.shellPid ?? 0
            return pid > 0 ? pid : nil
        }
    }

    func close(_ paneID: UUID) {
        closed.insert(paneID)
        captures[paneID] = nil
        guard let view = views.removeValue(forKey: paneID) else { return }
        view.processDelegate = nil
        view.terminate()
        view.removeFromSuperview()
    }

    func closeAll() {
        views.keys.forEach(close)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let view = source as? KabukTerminalView else { return }
        let id = view.paneID
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(id)
        }
    }
}
