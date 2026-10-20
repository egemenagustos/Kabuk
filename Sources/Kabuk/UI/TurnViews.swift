import KabukCore
import SwiftUI

/// "This turn · 3 files · +40 −12" with the file list; slides in when an agent finishes.
struct TurnCard: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let change: TurnChange

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.claude)
                Text("This turn").font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(change.files.count) file\(change.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                DiffCounts(added: change.added, removed: change.removed)
                Spacer()
                IconButton(symbol: "chevron.down", size: 9, help: "Fold") { state.toggleTurnCard(paneID) }
                IconButton(symbol: "xmark", size: 9, help: "Dismiss") { state.dismissTurnChange(paneID) }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(height: 34)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(change.files) { file in
                        FileRow(file: file) { state.showDiff(file, of: paneID) }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 180)
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.08).opacity(0.8)))
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: .black.opacity(0.3))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

private struct FileRow: View {
    let file: FileChange
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: file.isNew ? "doc.badge.plus" : "doc.text")
                    .font(.system(size: 10.5))
                    .foregroundStyle(file.isNew ? Theme.success : .white.opacity(0.5))
                    .frame(width: 14)
                Text(file.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if let added = file.added, let removed = file.removed {
                    DiffCounts(added: added, removed: removed)
                } else {
                    Text(file.added == nil && file.removed == nil && !file.isNew ? "changed" : "binary")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(added)").foregroundStyle(Theme.success)
            Text(verbatim: "−\(removed)").foregroundStyle(Theme.failure)
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
    }
}

/// The folded form of the turn card, shown in the pane header.
struct TurnChip: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let change: TurnChange

    var body: some View {
        Button { state.toggleTurnCard(paneID) } label: {
            HStack(spacing: 4) {
                Text(verbatim: "Δ \(change.files.count)").foregroundStyle(.white.opacity(0.75))
                DiffCounts(added: change.added, removed: change.removed)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Files changed in the agent's last turn")
    }
}

/// A file's diff against the start of the turn, colored like `git diff`.
struct DiffSheet: View {
    @EnvironmentObject var state: AppState
    let request: DiffRequest
    @State private var lines: [DiffLine]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.white.opacity(0.5))
                Text(request.file.path).font(.system(size: 13, weight: .semibold, design: .monospaced)).lineLimit(1)
                if let added = request.file.added, let removed = request.file.removed {
                    DiffCounts(added: added, removed: removed)
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(14)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if let lines {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .padding(.horizontal, 12)
                                // Full-width bands even inside the horizontal scroll view.
                                .frame(minWidth: 800, minHeight: 18, alignment: .leading)
                                .background(background(line.kind))
                        }
                    }
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 820, height: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .task(id: request) {
            let request = request
            lines = await Task.detached { TurnTracker.diff(request.file, in: request.change) }.value
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { state.diffRequest = nil }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.success
        case .remove: return Theme.failure
        case .hunk: return Theme.running
        case .header: return .white.opacity(0.4)
        case .context: return .white.opacity(0.75)
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .add: return Theme.success.opacity(0.1)
        case .remove: return Theme.failure.opacity(0.1)
        case .hunk: return Theme.running.opacity(0.08)
        default: return .clear
        }
    }
}
