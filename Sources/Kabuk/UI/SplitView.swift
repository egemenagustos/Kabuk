import KabukCore
import SwiftUI

/// Lays out a session's pane tree with draggable dividers.
struct SplitView: View {
    @EnvironmentObject var state: AppState
    let session: Session
    let node: PaneNode

    static let gap: CGFloat = 8

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneContainer(pane: pane, isFocused: pane.id == session.focusedPane,
                          showsChrome: session.root.panes.count > 1, worktree: session.worktree)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        case .split(let id, let axis, let children, let fractions):
            GeometryReader { geo in
                let total = (axis == .horizontal ? geo.size.width : geo.size.height) - Self.gap * CGFloat(children.count - 1)
                let layout = AnyLayout(axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0)))
                layout {
                    ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                        let length = max(total * CGFloat(fractions[index]), 0)
                        SplitView(session: session, node: child)
                            .frame(width: axis == .horizontal ? length : nil, height: axis == .vertical ? length : nil)
                        if index < children.count - 1 {
                            Divider(axis: axis) { delta in
                                resize(split: id, fractions: fractions, at: index, by: delta / max(total, 1))
                            }
                        }
                    }
                }
            }
        }
    }

    private func resize(split: UUID, fractions: [Double], at index: Int, by delta: Double) {
        var f = fractions
        let minimum = 0.12
        let pair = f[index] + f[index + 1]
        f[index] = min(max(f[index] + delta, minimum), pair - minimum)
        f[index + 1] = pair - f[index]
        state.setFractions(session: session.id, split: split, f)
    }
}

private struct Divider: View {
    let axis: SplitAxis
    let onDrag: (Double) -> Void
    @State private var last: CGFloat = 0
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.white.opacity(hovering ? 0.35 : 0))
                .frame(width: axis == .horizontal ? 3 : 36, height: axis == .horizontal ? 36 : 3)
        }
        .frame(width: axis == .horizontal ? SplitView.gap : nil, height: axis == .vertical ? SplitView.gap : nil)
        .contentShape(Rectangle())
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hovering = h }
            if h { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { value in
                let current = axis == .horizontal ? value.translation.width : value.translation.height
                onDrag(Double(current - last))
                last = current
            }
            .onEnded { _ in last = 0 })
    }
}
