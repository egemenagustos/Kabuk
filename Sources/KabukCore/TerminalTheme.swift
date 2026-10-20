import Foundation

/// A terminal color scheme. Built-ins ship with Kabuk; more can be dropped into the
/// themes folder as JSON files with the same fields.
public struct TerminalTheme: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Card tint behind the terminal text; the window's transparency setting scales its alpha.
    public var background: String
    public var foreground: String
    public var cursor: String
    /// The 16 ANSI colors, as "#rrggbb".
    public var ansi: [String]

    public init(id: String, name: String, background: String, foreground: String, cursor: String, ansi: [String]) {
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }

    public var isValid: Bool {
        ansi.count == 16 && ([background, foreground, cursor] + ansi).allSatisfy { Self.rgb($0) != nil }
    }

    /// "#rrggbb" or "rrggbb" → components in 0...1.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }

    public static let kabuk = TerminalTheme(
        id: "kabuk", name: "Kabuk", background: "#0f0f14", foreground: "#dcdee8", cursor: "#fa9e5c",
        ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#bac2de",
               "#585b70", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8"])

    public static let builtIn: [TerminalTheme] = [
        kabuk,
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night", background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5",
            ansi: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
                   "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),
        TerminalTheme(
            id: "dracula", name: "Dracula", background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2",
            ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                   "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        TerminalTheme(
            id: "nord", name: "Nord", background: "#2e3440", foreground: "#d8dee9", cursor: "#d8dee9",
            ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                   "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        TerminalTheme(
            id: "gruvbox", name: "Gruvbox", background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2",
            ansi: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984",
                   "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalTheme(
            id: "rose-pine", name: "Rosé Pine", background: "#191724", foreground: "#e0def4", cursor: "#ebbcba",
            ansi: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4",
                   "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"]),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark", background: "#002b36", foreground: "#93a1a1", cursor: "#93a1a1",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#586e75", "#cb4b16", "#859900", "#b58900", "#268bd2", "#6c71c4", "#2aa198", "#fdf6e3"]),
    ]

    /// Loads every valid `*.json` theme in a folder. Broken files are skipped.
    public static func load(from folder: URL) -> [TerminalTheme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      var theme = try? JSONDecoder().decode(TerminalTheme.self, from: data), theme.isValid else { return nil }
                theme.id = "user:" + url.deletingPathExtension().lastPathComponent
                return theme
            }
    }
}
