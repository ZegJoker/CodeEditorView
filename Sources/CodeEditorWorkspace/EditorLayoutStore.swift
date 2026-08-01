import Foundation
import Observation

public indirect enum EditorLayoutNode: Codable, Sendable, Equatable {
    case pane(EditorPaneID)
    case split(id: EditorSplitID, axis: EditorSplitAxis, children: [EditorLayoutNode], fractions: [Double])
}

/// Owns the recursive pane/split tree and keeps it normalized.
@MainActor
@Observable
public final class EditorLayoutStore {
    public private(set) var root: EditorLayoutNode

    public init(root: EditorLayoutNode) {
        self.root = root
        normalize()
    }

    public convenience init(singlePane id: EditorPaneID) {
        self.init(root: .pane(id))
    }

    public func allPaneIDs() -> [EditorPaneID] {
        collectPanes(root)
    }

    public func split(
        pane: EditorPaneID,
        axis: EditorSplitAxis,
        newPane: EditorPaneID,
        fraction: Double = 0.5
    ) {
        let frac = min(max(fraction, 0.05), 0.95)
        root =
            replacePane(pane, in: root) { _ in
                .split(
                    id: EditorSplitID(),
                    axis: axis,
                    children: [.pane(pane), .pane(newPane)],
                    fractions: [frac, 1 - frac]
                )
            } ?? root
        normalize()
    }

    public func close(pane: EditorPaneID) {
        // Never remove the last pane: leave a single empty pane placeholder id.
        let panes = allPaneIDs()
        if panes.count <= 1 {
            return
        }
        if let updated = removePane(pane, from: root) {
            root = updated
        }
        normalize()
        if allPaneIDs().isEmpty {
            root = .pane(EditorPaneID())
        }
    }

    public func setFractions(split id: EditorSplitID, fractions: [Double]) {
        root = mapSplits(root) { splitID, axis, children, oldFractions in
            guard splitID == id, fractions.count == children.count else {
                return .split(id: splitID, axis: axis, children: children, fractions: oldFractions)
            }
            return .split(id: splitID, axis: axis, children: children, fractions: Self.normalizedFractions(fractions))
        }
    }

    public func normalize() {
        root = normalized(root)
    }

    public func replaceRoot(_ node: EditorLayoutNode) {
        root = node
        normalize()
    }

    // MARK: - Normalize

    private func normalized(_ node: EditorLayoutNode) -> EditorLayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let id, let axis, let children, let fractions):
            let kids = children.map { normalized($0) }.filter { !isEmptySplit($0) }
            if kids.isEmpty {
                return .pane(EditorPaneID())
            }
            if kids.count == 1 {
                return kids[0]
            }
            let fracs: [Double]
            if fractions.count == kids.count {
                fracs = Self.normalizedFractions(fractions)
            } else {
                fracs = Array(repeating: 1.0 / Double(kids.count), count: kids.count)
            }
            return .split(id: id, axis: axis, children: kids, fractions: fracs)
        }
    }

    private func isEmptySplit(_ node: EditorLayoutNode) -> Bool {
        if case .split(_, _, let children, _) = node, children.isEmpty { return true }
        return false
    }

    private static func normalizedFractions(_ fractions: [Double]) -> [Double] {
        let clamped = fractions.map { max($0, 0.01) }
        let sum = clamped.reduce(0, +)
        guard sum > 0 else {
            return Array(repeating: 1.0 / Double(max(fractions.count, 1)), count: fractions.count)
        }
        return clamped.map { $0 / sum }
    }

    // MARK: - Tree ops

    private func collectPanes(_ node: EditorLayoutNode) -> [EditorPaneID] {
        switch node {
        case .pane(let id):
            return [id]
        case .split(_, _, let children, _):
            return children.flatMap { collectPanes($0) }
        }
    }

    private func replacePane(
        _ target: EditorPaneID,
        in node: EditorLayoutNode,
        with replacement: (EditorPaneID) -> EditorLayoutNode
    ) -> EditorLayoutNode? {
        switch node {
        case .pane(let id):
            return id == target ? replacement(id) : nil
        case .split(let sid, let axis, let children, let fractions):
            var changed = false
            var newChildren: [EditorLayoutNode] = []
            for child in children {
                if let replaced = replacePane(target, in: child, with: replacement) {
                    newChildren.append(replaced)
                    changed = true
                } else {
                    newChildren.append(child)
                }
            }
            return changed
                ? .split(id: sid, axis: axis, children: newChildren, fractions: fractions)
                : nil
        }
    }

    private func removePane(_ target: EditorPaneID, from node: EditorLayoutNode) -> EditorLayoutNode? {
        switch node {
        case .pane(let id):
            return id == target ? nil : node
        case .split(let sid, let axis, let children, let fractions):
            var newChildren: [EditorLayoutNode] = []
            var newFractions: [Double] = []
            for (child, frac) in zip(children, fractions) {
                if case .pane(let id) = child, id == target {
                    continue
                }
                if let updated = removePane(target, from: child) {
                    newChildren.append(updated)
                    newFractions.append(frac)
                }
            }
            if newChildren.isEmpty { return nil }
            if newChildren.count == 1 { return newChildren[0] }
            return .split(
                id: sid,
                axis: axis,
                children: newChildren,
                fractions: Self.normalizedFractions(newFractions)
            )
        }
    }

    private func mapSplits(
        _ node: EditorLayoutNode,
        _ body: (EditorSplitID, EditorSplitAxis, [EditorLayoutNode], [Double]) -> EditorLayoutNode
    ) -> EditorLayoutNode {
        switch node {
        case .pane:
            return node
        case .split(let id, let axis, let children, let fractions):
            let mappedChildren = children.map { mapSplits($0, body) }
            return body(id, axis, mappedChildren, fractions)
        }
    }
}
