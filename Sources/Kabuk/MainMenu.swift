import AppKit
import KabukCore

/// The menu bar. Shortcuts live here so they work while a terminal has focus.
@MainActor
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let menu = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                  tag: Int = 0, toTarget: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.tag = tag
            if toTarget { item.target = target }
            return item
        }

        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            parent.submenu = sub
            menu.addItem(parent)
            return parent
        }

        func arrow(_ key: Int) -> String { String(UnicodeScalar(key)!) }

        submenu("Kabuk", [
            item("About Kabuk", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), toTarget: false),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))),
            item("What's New in Kabuk", #selector(AppDelegate.showWhatsNew(_:))),
            .separator(),
            item("Install Agent Integrations…", #selector(AppDelegate.installIntegrations(_:))),
            item("Remove Agent Integrations", #selector(AppDelegate.uninstallIntegrations(_:))),
            .separator(),
            item("Hide Kabuk", #selector(NSApplication.hide(_:)), "h", toTarget: false),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], toTarget: false),
            .separator(),
            item("Quit Kabuk", #selector(NSApplication.terminate(_:)), "q", toTarget: false),
        ])

        submenu("Session", [
            item("New Session", #selector(AppDelegate.newSession(_:)), "t"),
            item("Open Project…", #selector(AppDelegate.openProject(_:)), "o"),
            .separator(),
            item("New Claude Worktree Session", #selector(AppDelegate.newClaudeWorktree(_:)), "t", [.command, .option]),
            item("New Codex Worktree Session", #selector(AppDelegate.newCodexWorktree(_:))),
            item("New Worktree Shell", #selector(AppDelegate.newShellWorktree(_:))),
            .separator(),
            item("Split Right", #selector(AppDelegate.splitRight(_:)), "d"),
            item("Split Down", #selector(AppDelegate.splitDown(_:)), "d", [.command, .shift]),
            .separator(),
            item("Rename Session", #selector(AppDelegate.renameSession(_:)), "r", [.command, .shift]),
            item("Close Pane", #selector(AppDelegate.closePane(_:)), "w"),
            item("Close Session", #selector(AppDelegate.closeSession(_:)), "w", [.command, .shift]),
        ])

        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c", toTarget: false),
            item("Paste", #selector(NSText.paste(_:)), "v", toTarget: false),
            item("Select All", #selector(NSText.selectAll(_:)), "a", toTarget: false),
            .separator(),
            item("Search History…", #selector(AppDelegate.toggleHistory(_:)), "r"),
            item("Find…", #selector(AppDelegate.find(_:)), "f"),
            item("Find Next", #selector(AppDelegate.findNext(_:)), "g"),
            item("Find Previous", #selector(AppDelegate.findPrevious(_:)), "g", [.command, .shift]),
        ])

        let numbers = (1...9).map { n in
            item("Session \(n)", #selector(AppDelegate.selectSessionByNumber(_:)), "\(n)", tag: n - 1)
        }
        let opacityItem = NSMenuItem(title: "Transparency", action: nil, keyEquivalent: "")
        opacityItem.submenu = NSMenu(title: "Transparency")
        for level in WorkspaceSnapshot.transparencyLevels {
            opacityItem.submenu!.addItem(item(level.name, #selector(AppDelegate.setOpacity(_:)), tag: Int((level.value * 100).rounded())))
        }

        submenu("View", [
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "\\"),
            item("Command Palette", #selector(AppDelegate.togglePalette(_:)), "k"),
            item("Themes…", #selector(AppDelegate.toggleThemes(_:)), "t", [.command, .shift]),
            item("Animated Background", #selector(AppDelegate.toggleAnimatedBackground(_:))),
            opacityItem,
            .separator(),
            item("Next Session", #selector(AppDelegate.nextSession(_:)), "]", [.command, .shift]),
            item("Previous Session", #selector(AppDelegate.previousSession(_:)), "[", [.command, .shift]),
        ] + numbers + [
            .separator(),
            item("Focus Left Pane", #selector(AppDelegate.focusLeft(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            item("Focus Right Pane", #selector(AppDelegate.focusRight(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            item("Focus Pane Above", #selector(AppDelegate.focusUp(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Focus Pane Below", #selector(AppDelegate.focusDown(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
            .separator(),
            item("Bigger", #selector(AppDelegate.fontBigger(_:)), "+"),
            item("Smaller", #selector(AppDelegate.fontSmaller(_:)), "-"),
            item("Actual Size", #selector(AppDelegate.fontReset(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], toTarget: false),
        ])

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", toTarget: false),
            item("Zoom", #selector(NSWindow.performZoom(_:)), toTarget: false),
        ])
        NSApp.windowsMenu = window.submenu
        return menu
    }
}
