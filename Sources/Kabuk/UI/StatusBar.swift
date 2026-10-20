import KabukCore
import SwiftUI

/// Bottom of the sidebar: palette shortcut and live counters.
struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "magnifyingglass", size: 12, help: "Command palette (⌘K)") { state.togglePalette() }
            IconButton(symbol: "folder.badge.plus", size: 12, help: "Open project (⌘O)") { state.chooseProject() }
            IconButton(symbol: "paintpalette", size: 12, help: "Themes (⇧⌘T)") { state.toggleThemeGallery() }
            Spacer()
            TodayCost(ledger: state.usage)
            counter(.agentNeedsYou(.claude, message: nil), state.needsYouCount, Theme.needsYou)
            counter(.running(command: "", startedAt: .now), state.busyCount, Theme.running)
            counter(.succeeded(finishedAt: .distantPast), state.unseenCount, .white)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: [state.needsYouCount, state.busyCount, state.unseenCount])
    }

    @ViewBuilder
    private func counter(_ status: PaneStatus, _ count: Int, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                StatusIcon(status: status, size: 11)
                Text(verbatim: "\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(color.opacity(0.85))
                    .contentTransition(.numericText())
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// Today's API-equivalent agent spend; hover for the last seven days.
private struct TodayCost: View {
    @ObservedObject var ledger: UsageLedger

    var body: some View {
        let today = ledger.today
        if today > 0 {
            // Drops the label when the counters next to it need the room.
            ViewThatFits(in: .horizontal) {
                chip("Today \(Pricing.format(today))")
                chip(Pricing.format(today))
            }
            .help(ledger.summary)
            .transition(.opacity)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .contentTransition(.numericText())
    }
}
