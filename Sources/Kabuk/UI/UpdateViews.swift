import KabukCore
import SwiftUI

/// What's New after an update, or a newer release with its notes and the ways to install it.
struct UpdateSheetView: View {
    @EnvironmentObject var state: AppState
    let sheet: UpdateSheet
    @State private var integration: IntegrationState = IntegrationInstaller.claudeOutdated() ? .outdated : .current

    private enum IntegrationState: Equatable { case current, outdated, updated, failed(String) }

    private var notes: [ReleaseNote] {
        switch sheet {
        case .whatsNew(let notes): notes
        case .available: state.availableUpdate?.notes ?? []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .whatsNew = sheet, integration != .current {
                        integrationCallout
                    }
                    ReleaseNotesList(notes: notes, showVersions: notes.count > 1 || sheet == .available)
                }
                .padding(16)
            }
            footer
        }
        .frame(width: 580, height: 520)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: sheet == .available ? "arrow.down.circle.fill" : "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(sheet == .available ? Theme.running : Theme.claude)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if sheet == .available, let page = state.availableUpdate?.page {
                IconButton(symbol: "arrow.up.right.square", size: 12, help: "Open the release on GitHub") {
                    NSWorkspace.shared.open(page)
                }
            }
        }
        .padding(14)
    }

    private var title: String {
        switch sheet {
        case .available: "Kabuk \(state.availableUpdate?.version.description ?? "") is available"
        case .whatsNew(let notes): "What's new in Kabuk \(notes.first?.version.description ?? "")"
        }
    }

    private var subtitle: String {
        let current = Updater.currentVersion?.description ?? "?"
        switch sheet {
        case .available:
            let count = notes.count
            return "You have \(current)" + (count > 1 ? " · \(count) releases since then" : "")
        case .whatsNew(let notes):
            if notes.count > 1 { return "Everything from the \(notes.count) releases since you last opened Kabuk" }
            return notes.first?.date.map { "Released \($0)" } ?? ""
        }
    }

    // MARK: Integration

    private var integrationCallout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: integration == .updated ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                .font(.system(size: 15))
                .foregroundStyle(integration == .updated ? Theme.success : Theme.needsYou)
            VStack(alignment: .leading, spacing: 4) {
                switch integration {
                case .updated:
                    Text("Claude Code integration updated").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text("Restart running Claude sessions to pick up the new hooks.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                case .failed(let reason):
                    Text("Couldn't update the integration").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text(reason).font(.system(size: 11)).foregroundStyle(Theme.failure)
                default:
                    Text("Claude Code needs a few more hooks").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    Text("Subagents, their worktrees and handing work to Codex need new hooks in ~/.claude/settings.json and a skill in ~/.claude/skills.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if integration == .outdated {
                Button("Update Integration") {
                    do {
                        try IntegrationInstaller.installClaude()
                        withAnimation { integration = .updated }
                    } catch {
                        integration = .failed(error.localizedDescription)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.needsYou.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.needsYou.opacity(0.2)))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            switch sheet {
            case .whatsNew:
                Button("Full History") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)/blob/main/CHANGELOG.md")!)
                }
                .controlSize(.small)
                Spacer()
                Button("Continue") { state.closeUpdateSheet() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .available:
                availableFooter
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    @ViewBuilder
    private var availableFooter: some View {
        let downloading = state.updateProgress == .downloading
        if downloading {
            ProgressView().controlSize(.mini)
            Text("Downloading…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        } else if case .failed(let reason) = state.updateProgress {
            Text(reason).font(.system(size: 11)).foregroundStyle(Theme.failure).lineLimit(2).help(reason)
        } else if case .ready = state.updateProgress {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.success)
        } else if let problem = state.updateInstallProblem {
            Text(problem).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2).help(problem)
        } else {
            Button("Skip This Version") { state.skipUpdate() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.white.opacity(0.55))
        }
        Spacer(minLength: 8)
        Button("Later") { state.closeUpdateSheet() }
            .keyboardShortcut(.cancelAction)
            .controlSize(.small)
        if state.updateInstallProblem != nil {
            Button("Download") {
                if let page = state.availableUpdate?.page { NSWorkspace.shared.open(page) }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
        } else {
            Button("Install When I Quit") { state.installUpdate(restart: false) }
                .controlSize(.small)
                .disabled(downloading)
                .help("Download now and swap Kabuk out when you quit it, without stopping anything")
            Button("Install and Restart") { state.installUpdate(restart: true) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(downloading)
                .help("Download, quit, swap in the new Kabuk and open it again")
        }
    }
}

/// Release notes as headings and entries, one block per version.
struct ReleaseNotesList: View {
    let notes: [ReleaseNote]
    var showVersions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 8) {
                    if showVersions {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(note.version.description).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                            if let date = note.date {
                                Text(date).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }
                    ForEach(Array(note.lines.enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .heading(let text):
                            Text(text.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(color(of: text))
                                .padding(.top, 4)
                        case .entry(let text):
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(.white.opacity(0.35)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                                Text(Self.markdown(text))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(of heading: String) -> Color {
        switch heading.lowercased() {
        case "added": Theme.success
        case "fixed": Theme.running
        case "removed", "security": Theme.failure
        default: Theme.needsYou
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A line above the sidebar's status bar while a newer release is waiting.
struct UpdateChip: View {
    @EnvironmentObject var state: AppState
    let update: AvailableUpdate
    @State private var hovered = false

    var body: some View {
        Button { state.showUpdate() } label: {
            HStack(spacing: 8) {
                if state.updateProgress == .downloading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: ready ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ready ? Theme.success : Theme.running)
                }
                Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.running.opacity(hovered ? 0.16 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.running.opacity(0.22)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("See what's new and install it")
    }

    private var ready: Bool {
        if case .ready = state.updateProgress { return true }
        return false
    }

    private var text: String {
        if state.updateProgress == .downloading { return "Downloading Kabuk \(update.version)…" }
        return ready ? "Kabuk \(update.version) installs when you quit" : "Kabuk \(update.version) is available"
    }
}
