import AppKit
import KabukCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var state: AppState!
    private var server: SocketServer?
    private var focusObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try? ShellIntegration.install()

        state = AppState(snapshot: Persistence.load())
        // The demo copy shouldn't post into the user's notification center.
        if AppState.isDemo { state.notifier.muted = true } else { state.notifier.requestAuthorization() }

        let server = SocketServer(path: ShellIntegration.socketPath) { [weak self] event, reply in
            DispatchQueue.main.async {
                guard let state = self?.state else {
                    reply?(.permission(.ask))
                    return
                }
                state.handle(event, reply: reply)
            }
        }
        do {
            try server.start()
        } catch {
            NSLog("Kabuk: socket could not start: \(error)")
        }
        self.server = server

        buildWindow()
        NSApp.mainMenu = MainMenu.build(target: self)
        DebugHooks.install(window: window, target: self, state: state)
        // A debug run is driven from scripts; don't pull focus away from whatever the user is doing.
        // The demo is the exception: it's recorded, so it has to be in front.
        if ProcessInfo.processInfo.environment["KABUK_DEBUG_DIR"] == nil || AppState.isDemo {
            NSApp.activate(ignoringOtherApps: true)
        }
        if ProcessInfo.processInfo.environment["KABUK_DEBUG_DIR"] == nil && !AppState.isDemo {
            DispatchQueue.main.async { IntegrationUI.offerUpdateIfOutdated() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        state.saveNow()
        state.terminals.closeAll()
        server?.stop()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        if AppState.isDemo {
            // A fixed size, so every recording frames the same.
            window.setContentSize(NSSize(width: 1440, height: 880))
            window.center()
        } else {
            window.setFrameAutosaveName("KabukMain")
            if !window.setFrameUsingName("KabukMain") { window.center() }
        }

        let root = MainView().environmentObject(state)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        window.contentView = hosting
        // Clicking into a terminal moves focus to its pane.
        focusObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            guard let terminal = window.firstResponder as? KabukTerminalView else { return }
            let id = terminal.paneID
            DispatchQueue.main.async { self?.state.paneFocused(id) }
        }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu actions

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleAnimatedBackground(_:)): item.state = state.animatedBackground ? .on : .off
        case #selector(toggleSidebar(_:)): item.state = state.sidebarVisible ? .on : .off
        case #selector(setOpacity(_:)): item.state = Int((state.opacity * 100).rounded()) == item.tag ? .on : .off
        default: break
        }
        return true
    }

    @objc func newSession(_ sender: Any?) { state.newSession() }
    @objc func openProject(_ sender: Any?) { state.chooseProject() }
    @objc func newClaudeWorktree(_ sender: Any?) { state.newWorktreeSession(agent: .claude) }
    @objc func newCodexWorktree(_ sender: Any?) { state.newWorktreeSession(agent: .codex) }
    @objc func newShellWorktree(_ sender: Any?) { state.newWorktreeSession(agent: nil) }
    @objc func splitRight(_ sender: Any?) { state.split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { state.split(.vertical) }
    @objc func closePane(_ sender: Any?) { state.closePane() }
    @objc func closeSession(_ sender: Any?) {
        if let id = state.selectedSessionID { state.closeSession(id) }
    }
    @objc func renameSession(_ sender: Any?) { state.renamingSession = state.selectedSessionID }
    @objc func toggleSidebar(_ sender: Any?) { state.toggleSidebar() }
    @objc func togglePalette(_ sender: Any?) { state.togglePalette() }
    @objc func nextSession(_ sender: Any?) { state.cycleSession(1) }
    @objc func previousSession(_ sender: Any?) { state.cycleSession(-1) }
    @objc func selectSessionByNumber(_ sender: NSMenuItem?) { state.selectSession(at: sender?.tag ?? 0) }
    @objc func focusLeft(_ sender: Any?) { state.focus(.left) }
    @objc func focusRight(_ sender: Any?) { state.focus(.right) }
    @objc func focusUp(_ sender: Any?) { state.focus(.up) }
    @objc func focusDown(_ sender: Any?) { state.focus(.down) }
    @objc func fontBigger(_ sender: Any?) { state.fontSize = min(state.fontSize + 1, 28) }
    @objc func fontSmaller(_ sender: Any?) { state.fontSize = max(state.fontSize - 1, 9) }
    @objc func fontReset(_ sender: Any?) { state.fontSize = 13 }
    @objc func setOpacity(_ sender: NSMenuItem) {
        withAnimation(.easeInOut(duration: 0.3)) { state.opacity = Double(sender.tag) / 100 }
    }
    @objc func toggleThemes(_ sender: Any?) { state.toggleThemeGallery() }
    @objc func toggleAnimatedBackground(_ sender: Any?) { state.toggleAnimatedBackground() }
    @objc func find(_ sender: Any?) { state.toggleFind() }
    @objc func toggleHistory(_ sender: Any?) { state.toggleHistory() }
    @objc func findNext(_ sender: Any?) { state.findStep(forward: true) }
    @objc func findPrevious(_ sender: Any?) { state.findStep(forward: false) }
    @objc func installIntegrations(_ sender: Any?) { IntegrationUI.install() }
    @objc func uninstallIntegrations(_ sender: Any?) { IntegrationUI.uninstall() }
}
