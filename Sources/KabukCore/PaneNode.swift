import Foundation

public struct Pane: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var cwd: String

    public init(id: UUID = UUID(), cwd: String) {
        self.id = id
        self.cwd = cwd
    }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side.
    case horizontal
    /// Children stacked top to bottom.
    case vertical
}

public enum FocusDirection: Sendable {
    case left, right, up, down
}

public struct UnitRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// A session's split layout. Leaves are panes, inner nodes split their space by `fractions`.
public indirect enum PaneNode: Codable, Equatable, Sendable {
    case leaf(Pane)
    case split(id: UUID, axis: SplitAxis, children: [PaneNode], fractions: [Double])

    /// Stable identity for SwiftUI: the pane's id for leaves, the split's id otherwise.
    public var id: UUID {
        switch self {
        case .leaf(let pane): return pane.id
        case .split(let id, _, _, _): return id
        }
    }

    public var panes: [Pane] {
        switch self {
        case .leaf(let pane): return [pane]
        case .split(_, _, let children, _): return children.flatMap(\.panes)
        }
    }

    public var paneIDs: [UUID] { panes.map(\.id) }

    public func contains(_ paneID: UUID) -> Bool {
        paneIDs.contains(paneID)
    }

    /// Splits the pane, putting `newPane` right after it. Splitting along the parent's own
    /// axis adds a sibling instead of nesting, so three side-by-side panes stay flat.
    public func splitting(_ paneID: UUID, axis: SplitAxis, newPane: Pane) -> PaneNode {
        switch self {
        case .leaf(let pane):
            guard pane.id == paneID else { return self }
            return .split(id: UUID(), axis: axis, children: [self, .leaf(newPane)], fractions: [0.5, 0.5])

        case .split(let id, let ownAxis, let children, let fractions):
            if ownAxis == axis, let index = children.firstIndex(where: { $0.isLeaf(paneID) }) {
                var children = children
                var fractions = fractions
                let half = fractions[index] / 2
                fractions[index] = half
                children.insert(.leaf(newPane), at: index + 1)
                fractions.insert(half, at: index + 1)
                return .split(id: id, axis: ownAxis, children: children, fractions: fractions)
            }
            return .split(id: id, axis: ownAxis,
                          children: children.map { $0.splitting(paneID, axis: axis, newPane: newPane) },
                          fractions: fractions)
        }
    }

    /// Removes the pane. Returns nil when nothing is left; a split left with one child
    /// collapses into that child and its space is given to the neighbors.
    public func removing(_ paneID: UUID) -> PaneNode? {
        switch self {
        case .leaf(let pane):
            return pane.id == paneID ? nil : self

        case .split(let id, let axis, let children, let fractions):
            var newChildren: [PaneNode] = []
            var newFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let kept = child.removing(paneID) {
                    newChildren.append(kept)
                    newFractions.append(fraction)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            let total = newFractions.reduce(0, +)
            return .split(id: id, axis: axis, children: newChildren, fractions: newFractions.map { $0 / total })
        }
    }

    public func settingFractions(_ splitID: UUID, _ newFractions: [Double]) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let children, let fractions):
            if id == splitID, newFractions.count == children.count {
                return .split(id: id, axis: axis, children: children, fractions: newFractions)
            }
            return .split(id: id, axis: axis,
                          children: children.map { $0.settingFractions(splitID, newFractions) },
                          fractions: fractions)
        }
    }

    public func updatingPane(_ paneID: UUID, _ update: (inout Pane) -> Void) -> PaneNode {
        switch self {
        case .leaf(var pane):
            if pane.id == paneID { update(&pane) }
            return .leaf(pane)
        case .split(let id, let axis, let children, let fractions):
            return .split(id: id, axis: axis, children: children.map { $0.updatingPane(paneID, update) },
                          fractions: fractions)
        }
    }

    /// Each pane's rectangle inside the unit square.
    public func layout(in rect: UnitRect = UnitRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: UnitRect] {
        switch self {
        case .leaf(let pane):
            return [pane.id: rect]
        case .split(_, let axis, let children, let fractions):
            var result: [UUID: UnitRect] = [:]
            var offset = 0.0
            for (child, fraction) in zip(children, fractions) {
                let childRect: UnitRect
                if axis == .horizontal {
                    childRect = UnitRect(x: rect.x + offset * rect.width, y: rect.y,
                                         width: fraction * rect.width, height: rect.height)
                } else {
                    childRect = UnitRect(x: rect.x, y: rect.y + offset * rect.height,
                                         width: rect.width, height: fraction * rect.height)
                }
                result.merge(child.layout(in: childRect)) { a, _ in a }
                offset += fraction
            }
            return result
        }
    }

    /// The closest pane in the given direction, if any.
    public func neighbor(of paneID: UUID, _ direction: FocusDirection) -> UUID? {
        let rects = layout()
        guard let from = rects[paneID] else { return nil }
        let eps = 1e-9
        let candidates = rects.filter { id, r in
            guard id != paneID else { return false }
            switch direction {
            case .left: return r.maxX <= from.x + eps && overlapsVertically(r, from)
            case .right: return r.x >= from.maxX - eps && overlapsVertically(r, from)
            case .up: return r.maxY <= from.y + eps && overlapsHorizontally(r, from)
            case .down: return r.y >= from.maxY - eps && overlapsHorizontally(r, from)
            }
        }
        // Ties (two panes stacked beside a tall one) go to the top or left one.
        return candidates.min { a, b in
            let da = distance(a.value, from), db = distance(b.value, from)
            if abs(da - db) > eps { return da < db }
            return (a.value.y, a.value.x) < (b.value.y, b.value.x)
        }?.key
    }

    private func isLeaf(_ paneID: UUID) -> Bool {
        if case .leaf(let pane) = self { return pane.id == paneID }
        return false
    }
}

private func overlapsVertically(_ a: UnitRect, _ b: UnitRect) -> Bool {
    a.y < b.maxY && b.y < a.maxY
}

private func overlapsHorizontally(_ a: UnitRect, _ b: UnitRect) -> Bool {
    a.x < b.maxX && b.x < a.maxX
}

private func distance(_ a: UnitRect, _ b: UnitRect) -> Double {
    let dx = a.midX - b.midX
    let dy = a.midY - b.midY
    return dx * dx + dy * dy
}
