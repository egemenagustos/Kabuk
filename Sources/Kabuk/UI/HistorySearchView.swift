import KabukCore
import SwiftUI

/// ⌘R: fuzzy search over every command run in Kabuk and in ~/.zsh_history.
struct HistorySearchView: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var selected = 0
    @State private var thisFolder = false
    @FocusState private var focused: Bool

    var body: some View {
        let cwd = state.focusedCwd
        let results = HistorySearch.search(state.history.entries, query: query, cwd: thisFolder ? cwd : nil, limit: 60)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.white.opacity(0.45))
                TextField("Search command history…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { insert(results, run: false) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        insert(results, run: true)
                        return .handled
                    }
                    .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                    .onKeyPress(.escape) { state.toggleHistory(); return .handled }
                    .onChange(of: query) { selected = 0 }
                Picker("", selection: $thisFolder) {
                    Text("All").tag(false)
                    Text("This Folder").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: thisFolder) { selected = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, entry in
                            row(entry, active: index == selected)
                                .id(index)
                                .onTapGesture { selected = index; insert(results, run: false) }
                                .onHover { if $0 { selected = index } }
                        }
                        if results.isEmpty {
                            Text(state.history.entries.isEmpty ? "No history yet" : "No matching commands")
                                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.4)).padding(20)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .onChange(of: selected) { _, new in proxy.scrollTo(new) }
            }

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            HStack(spacing: 14) {
                hint("↩", "Insert")
                hint("⌘↩", "Run")
                hint("esc", "Close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.07).opacity(0.7)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .focusOnAppear($focused)
    }

    private func row(_ entry: HistoryEntry, active: Bool) -> some View {
        HStack(spacing: 12) {
            Text(entry.command.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !entry.cwd.isEmpty {
                Text(PaneContainer.abbreviate(entry.cwd))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            Text(entry.hasKnownDate ? Self.ago(entry.date) : "")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.35))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(active ? 0.12 : 0)))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10.5, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.white.opacity(0.45))
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func insert(_ results: [HistoryEntry], run: Bool) {
        guard results.indices.contains(selected) else { return }
        let command = results[selected].command
        state.toggleHistory()
        DispatchQueue.main.async { state.typeIntoFocusedPane(command, run: run) }
    }

    static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 86400 * 365 { return "\(s / 86400)d" }
        return "\(s / (86400 * 365))y"
    }
}
