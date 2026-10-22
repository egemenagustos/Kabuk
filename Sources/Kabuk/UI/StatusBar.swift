import KabukCore
import SwiftUI

/// Bottom of the sidebar: plan limits and today's cost, then the palette shortcut and live counters.
/// Two rows, because the sidebar is too narrow for all of it on one: a row wider than the sidebar
/// widens the whole sidebar column, which then spills over both of its edges.
struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            UsageRow(ledger: state.usage)
            HStack(spacing: 8) {
                IconButton(symbol: "magnifyingglass", size: 12, help: "Command palette (⌘K)") { state.togglePalette() }
                IconButton(symbol: "folder.badge.plus", size: 12, help: "Open project (⌘O)") { state.chooseProject() }
                IconButton(symbol: "paintpalette", size: 12, help: "Themes (⇧⌘T)") { state.toggleThemeGallery() }
                Spacer()
                counter(.agentNeedsYou(.claude, message: nil), state.needsYouCount, Theme.needsYou)
                counter(.running(command: "", startedAt: .now), state.busyCount, Theme.running)
                counter(.succeeded(finishedAt: .distantPast), state.unseenCount, .white)
            }
            .frame(height: 38)
        }
        .padding(.horizontal, 12)
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

/// The agents' plan limits and today's cost, once there is either.
private struct UsageRow: View {
    @ObservedObject var ledger: UsageLedger

    var body: some View {
        if !ledger.limits.isEmpty || ledger.today > 0 {
            HStack(spacing: 8) {
                PlanLimitsChip(ledger: ledger)
                Spacer(minLength: 0)
                TodayCost(ledger: ledger)
            }
            .padding(.top, 10)
            .transition(.opacity)
        }
    }
}

/// Today's API-equivalent agent spend; hover or click for each agent's share and the last seven days.
private struct TodayCost: View {
    @ObservedObject var ledger: UsageLedger

    var body: some View {
        let today = ledger.today
        if today > 0 {
            HoverPopoverButton { showing in
                // Drops the label when the counters next to it need the room.
                ViewThatFits(in: .horizontal) {
                    chip("Today \(Pricing.format(today))", showing: showing)
                    chip(Pricing.format(today), showing: showing)
                }
            } details: {
                CostPopover(ledger: ledger)
            }
            .transition(.opacity)
        }
    }

    private func chip(_ text: String, showing: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(showing ? 0.13 : 0.07)))
            .contentShape(Capsule())
            .contentTransition(.numericText())
    }
}

/// Each agent's plan usage on the clock: five dots for the hours of the 5-hour window and seven
/// dashes for the days of the week, filled as far as the limit is used. The current hour breathes,
/// so filled dots past it mean the limit runs out before the reset.
/// Hovering or clicking opens the details above; a click keeps them open.
private struct PlanLimitsChip: View {
    @ObservedObject var ledger: UsageLedger

    var body: some View {
        let agents = AgentRegistry.agents.filter { ledger.limits[$0] != nil }
        if !agents.isEmpty {
            HoverPopoverButton { showing in
                // Once a minute, so the current hour moves on and a reset empties the dots while idle.
                TimelineView(.everyMinute) { context in
                    HStack(spacing: 8) {
                        ForEach(agents, id: \.self) { agent in
                            if let limits = ledger.limits[agent]?.current(at: context.date) {
                                LimitClock(agent: agent, limits: limits, now: context.date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(showing ? 0.13 : 0.06)))
                .contentShape(Capsule())
            } details: {
                PlanLimitsPopover(ledger: ledger)
            }
            .transition(.opacity)
        }
    }
}

/// A chip whose details open above it on hover or click; a click keeps them open.
private struct HoverPopoverButton<Label: View, Details: View>: View {
    @ViewBuilder var label: (_ showing: Bool) -> Label
    @ViewBuilder var details: () -> Details
    @State private var showing = false
    @State private var pinned = false
    @State private var overChip = false
    @State private var overDetails = false

    var body: some View {
        Button(action: click) { label(showing) }
            .buttonStyle(.plain)
            .onHover { inside in
                overChip = inside
                inside ? later(0.25) { if overChip { showing = true } } : closeLater()
            }
            .popover(isPresented: $showing, arrowEdge: .top) {
                details()
                    .onHover { inside in
                        overDetails = inside
                        if !inside { closeLater() }
                    }
            }
            .onChange(of: showing) { _, open in if !open { pinned = false } }
    }

    /// Opens and keeps the details; a second click closes them.
    private func click() {
        if showing && !pinned {
            pinned = true
        } else {
            showing.toggle()
            pinned = showing
        }
    }

    /// Moving from the chip into the details leaves one before entering the other; wait for both.
    private func closeLater() {
        later(0.25) { if !pinned && !overChip && !overDetails { showing = false } }
    }

    private func later(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }
}

/// One agent: its glyph, the five hours above, the seven days below.
private struct LimitClock: View {
    let agent: AgentKind
    let limits: PlanLimits
    let now: Date

    private static let dot: CGFloat = 4.5
    private static let dotGap: CGFloat = 2
    private static var width: CGFloat { 5 * dot + 4 * dotGap }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: agent.glyph)
                .font(.system(size: 7.5, weight: .heavy))
                .foregroundStyle(agent.tint)
                .frame(width: 9)
            VStack(spacing: 2.5) {
                hours
                days
            }
        }
    }

    private var hours: some View {
        let used = limits.fiveHour?.usedPercent ?? 0
        let current = limits.fiveHour.flatMap { $0.elapsed(of: $0.length ?? PlanLimits.fiveHourLength, at: now) }.map { min(Int($0 * 5), 4) }
        return HStack(spacing: Self.dotGap) {
            ForEach(0..<5, id: \.self) { hour in
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LimitLevel.color(used, normal: agent.tint))
                            .frame(width: Self.dot * Self.share(used, of: 5, at: hour))
                    }
                    .clipShape(Circle())
                    .frame(width: Self.dot, height: Self.dot)
                    .overlay {
                        if hour == current {
                            BreathingBorder(color: .white.opacity(0.9), cornerRadius: (Self.dot + 3) / 2, lineWidth: 1)
                                .frame(width: Self.dot + 3, height: Self.dot + 3)
                        }
                    }
            }
        }
    }

    private var days: some View {
        let used = limits.weekly?.usedPercent ?? 0
        let today = limits.weekly.flatMap { $0.elapsed(of: $0.length ?? PlanLimits.weeklyLength, at: now) }.map { min(Int($0 * 7), 6) }
        let gap: CGFloat = 1.5
        let dash = (Self.width - 6 * gap) / 7
        return HStack(spacing: gap) {
            ForEach(0..<7, id: \.self) { day in
                Capsule()
                    .fill(Color.white.opacity(day == today ? 0.4 : 0.14))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LimitLevel.color(used, normal: agent.tint.opacity(0.75)))
                            .frame(width: dash * Self.share(used, of: 7, at: day))
                    }
                    .clipShape(Capsule())
                    .frame(width: dash, height: 2)
            }
        }
    }

    /// How much of segment `index` out of `count` the used percentage covers, 0…1.
    static func share(_ percent: Double, of count: Int, at index: Int) -> CGFloat {
        CGFloat(min(max(percent / 100 * Double(count) - Double(index), 0), 1))
    }
}

private enum LimitLevel {
    static func color(_ percent: Double, normal: Color) -> Color {
        switch percent {
        case 90...: return Theme.failure
        case 70...: return Theme.needsYou
        default: return normal
        }
    }
}

/// Today's spend split by agent, the last seven days, and what the numbers mean.
private struct CostPopover: View {
    @ObservedObject var ledger: UsageLedger

    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    var body: some View {
        let days = ledger.days(7)
        let today = days.first?.byAgent ?? [:]
        let total = today.values.reduce(0, +)
        // Claude and Codex always; other agents once they've spent something this week.
        let agents = AgentRegistry.agents.filter { agent in
            agent == .claude || agent == .codex || days.contains { ($0.byAgent[agent] ?? 0) > 0 }
        }
        let peak = days.map { $0.byAgent.values.reduce(0, +) }.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Today").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(verbatim: Pricing.format(total))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                }
                ForEach(agents, id: \.self) { agent in
                    agentRow(agent, today[agent] ?? 0, share: total > 0 ? (today[agent] ?? 0) / total : 0)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 days").font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                ForEach(days, id: \.date) { day in
                    dayRow(day.date, day.byAgent, peak: peak)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("API-equivalent: what these tokens would cost at API list prices. On a Claude or ChatGPT plan you pay for the plan, not this; the plan limits are what you actually use up.")
                Text(verbatim: "Counts agent sessions run in Kabuk only. Prices as of \(Pricing.pricesAsOf); long-context and fast-mode surcharges aren't included. Override them in pricing.json.")
            }
            .font(.system(size: 10))
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 250)
    }

    private func agentRow(_ agent: AgentKind, _ cost: Double, share: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(agent.displayName).font(.system(size: 11)).foregroundStyle(agent.tint)
                Spacer()
                Text(verbatim: cost > 0 ? Pricing.format(cost) : "—")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(agent.tint).frame(width: proxy.size.width * share)
                }
            }
            .frame(height: 4)
        }
    }

    /// The day's spend as one bar, split by agent, scaled to the week's biggest day.
    private func dayRow(_ date: Date, _ byAgent: [AgentKind: Double], peak: Double) -> some View {
        let total = byAgent.values.reduce(0, +)
        return HStack(spacing: 8) {
            Text(verbatim: Self.dayFormat.string(from: date))
                .font(.system(size: 10)).foregroundStyle(Theme.dim)
                .frame(width: 72, alignment: .leading)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(AgentRegistry.agents.filter { (byAgent[$0] ?? 0) > 0 }, id: \.self) { agent in
                        Rectangle()
                            .fill(agent.tint)
                            .frame(width: peak > 0 ? proxy.size.width * (byAgent[agent] ?? 0) / peak : 0)
                    }
                }
                .clipShape(Capsule())
                .frame(maxHeight: .infinity)
            }
            .frame(height: 4)
            Text(verbatim: total > 0 ? Pricing.format(total) : "—")
                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private struct PlanLimitsPopover: View {
    @ObservedObject var ledger: UsageLedger

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AgentRegistry.agents, id: \.self) { agent in
                    if let limits = ledger.limits[agent] {
                        section(agent, limits.current(at: context.date), updated: limits.updatedAt, now: context.date)
                    }
                }
                HStack(spacing: 5) {
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: 1.5, height: 8)
                    Text("Even pace: past it, the limit runs out before the reset.")
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            }
            .padding(14)
            .frame(width: 250)
        }
    }

    private func section(_ agent: AgentKind, _ limits: PlanLimits, updated: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(agent.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(agent.tint)
                Spacer()
                Text(verbatim: "updated \(Self.ago(now.timeIntervalSince(updated)))")
                    .font(.system(size: 10)).foregroundStyle(Theme.dim)
            }
            row(limits.fiveHour, length: limits.fiveHour?.length ?? PlanLimits.fiveHourLength, tint: agent.tint, now: now)
            row(limits.weekly, length: limits.weekly?.length ?? PlanLimits.weeklyLength, tint: agent.tint, now: now)
        }
    }

    @ViewBuilder
    private func row(_ window: LimitWindow?, length: TimeInterval, tint: Color, now: Date) -> some View {
        if let window {
            let title = Self.title(length)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(verbatim: "\(Int(window.usedPercent.rounded()))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LimitLevel.color(window.usedPercent, normal: .white.opacity(0.85)))
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(LimitLevel.color(window.usedPercent, normal: tint))
                            .frame(width: proxy.size.width * min(max(window.usedPercent, 0), 100) / 100)
                        // Where usage would be at an even pace through the window.
                        if let elapsed = window.elapsed(of: length, at: now), elapsed > 0, elapsed < 1 {
                            Capsule()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: 1.5, height: 8)
                                .offset(x: proxy.size.width * elapsed - 0.75)
                        }
                    }
                    .frame(height: proxy.size.height)
                }
                .frame(height: 4)
                if let resetsAt = window.resetsAt {
                    Text(verbatim: "resets \(Self.reset(resetsAt, now: now)) · in \(Self.countdown(resetsAt.timeIntervalSince(now)))")
                        .font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    /// 5-hour, Weekly, 30-day.
    static func title(_ length: TimeInterval) -> String {
        let hours = Int((length / 3600).rounded())
        if hours < 24 { return "\(hours)-hour" }
        return hours == 168 ? "Weekly" : "\(hours / 24)-day"
    }

    /// "14:20" today, "Mon 09:00" later in the week.
    static func reset(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "jj:mm" : "EEE jj:mm")
        return formatter.string(from: date)
    }

    /// 42m, 2h 10m, 3d 4h.
    static func countdown(_ seconds: TimeInterval) -> String {
        let m = max(Int(seconds / 60), 0)
        if m < 60 { return "\(m)m" }
        if m < 1440 { return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m" }
        return m % 1440 / 60 == 0 ? "\(m / 1440)d" : "\(m / 1440)d \(m % 1440 / 60)h"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

private extension AgentKind {
    var tint: Color { Theme.color(for: self) }
    var glyph: String { profile.glyph }
}
