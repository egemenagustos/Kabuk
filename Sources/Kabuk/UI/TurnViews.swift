import KabukCore
import SwiftUI

/// "This turn · 3 files · +40 −12" with the file list; slides in when an agent finishes.
struct TurnCard: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let change: TurnChange

    var body: some View {
        let undone = state.undoneTurns[paneID] != nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: undone ? "arrow.uturn.backward" : "sparkles").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(undone ? .white.opacity(0.5) : Theme.claude)
                Text(undone ? "Turn undone" : "This turn").font(.system(size: 12, weight: .semibold))
                Text(verbatim: "\(change.files.count) file\(change.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                DiffCounts(added: change.added, removed: change.removed)
                    .opacity(undone ? 0.4 : 1)
                Spacer()
                if change.snapshot != nil {
                    UndoButton(undone: undone, busy: state.runtimes[paneID]?.status.isBusy ?? false) {
                        if undone { state.redoTurn(paneID) } else { state.undoTurn(paneID) }
                    }
                }
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
            if let notes = state.reviewComments[paneID], !notes.isEmpty {
                ReviewBar(paneID: paneID, count: notes.count, compact: true)
            }
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.08).opacity(0.8)))
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: .black.opacity(0.3))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

/// "Undo" while the turn's changes are in place, "Redo" once they're undone.
private struct UndoButton: View {
    let undone: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(undone ? "Redo" : "Undo", systemImage: undone ? "arrow.uturn.forward" : "arrow.uturn.backward")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white.opacity(busy ? 0.3 : hovering ? 0.95 : 0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(hovering && !busy ? 0.14 : 0.08)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(busy ? "Wait for the agent to finish" : undone ? "Put the turn's changes back" : "Put these files back as they were before the turn")
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

/// A file's diff against the start of the turn, colored like `git diff`. Hovering a line offers
/// a note for the agent; the notes go out together from the bar at the bottom.
struct DiffSheet: View {
    @EnvironmentObject var state: AppState
    let request: DiffRequest
    @State private var lines: [DiffLine]?
    @State private var drafting: Int?
    @State private var draft = ""

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
                            DiffRow(line: line, commentable: request.paneID != nil && line.oldLine ?? line.newLine != nil,
                                    onComment: { startDraft(line) })
                            ForEach(comments(on: line)) { comment in
                                NoteBubble(comment: comment) { state.removeComment(comment.id, for: request.paneID!) }
                            }
                            if drafting == line.id {
                                NoteField(text: $draft, submit: { submit(line) }, cancel: { drafting = nil })
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let paneID = request.paneID, let notes = state.reviewComments[paneID], !notes.isEmpty {
                ReviewBar(paneID: paneID, count: notes.count)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 820, height: 560)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.06).opacity(0.92)))
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        .task(id: request.file.path + request.change.base) {
            let request = request
            lines = await Task.detached { TurnTracker.diff(request.file, in: request.change) }.value
        }
    }

    private func comments(on line: DiffLine) -> [DiffComment] {
        guard let paneID = request.paneID, let number = line.newLine ?? line.oldLine else { return [] }
        return (state.reviewComments[paneID] ?? []).filter {
            $0.path == request.file.path && $0.line == number && $0.removed == (line.kind == .remove)
        }
    }

    private func startDraft(_ line: DiffLine) {
        draft = ""
        withAnimation(.easeOut(duration: 0.15)) { drafting = line.id }
    }

    private func submit(_ line: DiffLine) {
        let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paneID = request.paneID, !note.isEmpty {
            state.addComment(DiffComment(path: request.file.path, diffLine: line, note: note), for: paneID)
        }
        drafting = nil
        draft = ""
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { state.diffRequest = nil }
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let commentable: Bool
    let onComment: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
            ZStack {
                if commentable && hovering {
                    Button(action: onComment) {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.running)
                    }
                    .buttonStyle(.plain)
                    .help("Leave a note on this line for the agent")
                }
            }
            .frame(width: 24)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(color)
                .padding(.trailing, 12)
        }
        .font(.system(size: 10.5, design: .monospaced).monospacedDigit())
        .foregroundStyle(.white.opacity(0.25))
        // Full-width bands even inside the horizontal scroll view.
        .frame(minWidth: 800, minHeight: 18, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var color: Color {
        switch line.kind {
        case .add: return Theme.success
        case .remove: return Theme.failure
        case .hunk: return Theme.running
        case .header: return .white.opacity(0.4)
        case .context: return .white.opacity(0.75)
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: return Theme.success.opacity(0.1)
        case .remove: return Theme.failure.opacity(0.1)
        case .hunk: return Theme.running.opacity(0.08)
        default: return .clear
        }
    }
}

private struct NoteBubble: View {
    let comment: DiffComment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble.fill").font(.system(size: 11)).foregroundStyle(Theme.running)
            Text(comment.note).font(.system(size: 12)).foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton(symbol: "trash", size: 9, help: "Remove note", action: remove)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.running.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.running.opacity(0.25)))
        .padding(.leading, 92)
        .padding(.vertical, 4)
    }
}

private struct NoteField: View {
    @Binding var text: String
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Note for the agent, then Return", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand(perform: cancel)
            Button("Add", action: submit).controlSize(.small).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.running.opacity(0.5)))
        .padding(.leading, 92)
        .padding(.vertical, 4)
        .onAppear { focused = true }
    }
}

/// "3 notes · Send to Claude", shared by the diff sheet and the turn card.
struct ReviewBar: View {
    @EnvironmentObject var state: AppState
    let paneID: UUID
    let count: Int
    var compact = false

    var body: some View {
        let agent = state.reviewAgent(for: paneID)
        HStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.system(size: 11)).foregroundStyle(Theme.running)
            Text(verbatim: "\(count) note\(count == 1 ? "" : "s")").font(.system(size: compact ? 11 : 12, weight: .medium))
            if !compact {
                Text(state.runtimes[paneID]?.status.isBusy == true ? "sent when the turn ends" : "sent together as one prompt")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Button { state.sendComments(for: paneID) } label: {
                Text("Send to \(agent.displayName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.color(for: agent)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, compact ? 12 : 14)
        .frame(height: compact ? 32 : 42)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }
}
