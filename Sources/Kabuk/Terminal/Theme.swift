import AppKit
import KabukCore
import SwiftTerm
import SwiftUI

/// Fixed UI colors plus conversions from a `TerminalTheme`.
enum Theme {
    static let claude = SwiftUI.Color(red: 0.93, green: 0.55, blue: 0.36)
    static let codex = SwiftUI.Color(red: 0.36, green: 0.82, blue: 0.78)
    static let needsYou = SwiftUI.Color(red: 0.98, green: 0.66, blue: 0.22)
    static let success = SwiftUI.Color(red: 0.45, green: 0.85, blue: 0.55)
    static let failure = SwiftUI.Color(red: 0.98, green: 0.38, blue: 0.42)
    static let running = SwiftUI.Color(red: 0.55, green: 0.70, blue: 1.0)
    static let dim = SwiftUI.Color.white.opacity(0.45)

    static func color(for agent: AgentKind) -> SwiftUI.Color {
        agent == .claude ? claude : codex
    }

    static func terminalFont(size: CGFloat) -> NSFont {
        NSFont(name: "SF Mono", size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func nsColor(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        guard let c = TerminalTheme.rgb(hex) else { return NSColor(white: 0.5, alpha: alpha) }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    static func color(_ hex: String) -> SwiftUI.Color {
        guard let c = TerminalTheme.rgb(hex) else { return .gray }
        return SwiftUI.Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    static func apply(_ theme: TerminalTheme, to view: TerminalView) {
        view.nativeForegroundColor = nsColor(theme.foreground)
        // Clear: the pane card behind the text carries the theme's background tint.
        view.nativeBackgroundColor = nsColor(theme.background, alpha: 0)
        view.caretColor = nsColor(theme.cursor)
        view.selectedTextBackgroundColor = NSColor.white.withAlphaComponent(0.22)
        view.installColors(theme.ansi.map { hex in
            let c = TerminalTheme.rgb(hex) ?? (0.5, 0.5, 0.5)
            return SwiftTerm.Color(red8: UInt16(c.r * 255), green8: UInt16(c.g * 255), blue8: UInt16(c.b * 255))
        })
    }
}
