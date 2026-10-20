import KabukCore
import SwiftUI

/// The theme store: every built-in and custom theme as a live preview card.
struct ThemeGallery: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Themes").font(.system(size: 17, weight: .semibold))
                    Text("Click to apply. Drop your own .json themes into the themes folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button("Open Themes Folder") { state.openThemesFolder() }
                Button("Reload") { state.reloadThemes() }
                Button("Done") { state.toggleThemeGallery() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding(18)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(state.themes) { theme in
                        ThemeCard(theme: theme, selected: theme.id == state.themeID)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) { state.themeID = theme.id }
                            }
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 720)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.07).opacity(0.75)))
        .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: .black.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }
}

private struct ThemeCard: View {
    let theme: TerminalTheme
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            HStack {
                Text(theme.name).font(.system(size: 12.5, weight: .medium))
                if theme.id.hasPrefix("user:") {
                    Text("custom")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.1 : hovering ? 0.06 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Theme.color(theme.cursor).opacity(0.7) : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1))
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// A tiny fake session rendered in the theme's own colors.
    private var preview: some View {
        let c = { (i: Int) in Theme.color(theme.ansi[i]) }
        let fg = Theme.color(theme.foreground)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text("~/snake ").foregroundStyle(c(4))
                Text("main ").foregroundStyle(c(5))
                Text("❯ ").foregroundStyle(c(2))
                Text("git diff --stat").foregroundStyle(fg)
            }
            HStack(spacing: 0) {
                Text(" snake.mjs | 16 ").foregroundStyle(fg.opacity(0.8))
                Text("+++++++").foregroundStyle(c(2))
                Text("--").foregroundStyle(c(1))
            }
            HStack(spacing: 0) {
                Text("✻ ").foregroundStyle(c(3))
                Text("Reviewing ").foregroundStyle(fg)
                Text("--size").foregroundStyle(c(6))
                Text(" flag…").foregroundStyle(fg.opacity(0.6))
            }
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(c(i)).frame(width: 14, height: 6)
                }
                Rectangle().fill(Theme.color(theme.cursor)).frame(width: 6, height: 10).padding(.leading, 4)
            }
            .padding(.top, 3)
        }
        .font(.system(size: 9.5, design: .monospaced))
        .lineLimit(1)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.color(theme.background)))
    }
}
