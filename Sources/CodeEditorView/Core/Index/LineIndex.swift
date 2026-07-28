import CoreGraphics
import Foundation

/// Identity-bearing payload for a logical document line.
public protocol LinePayload: Identifiable, AnyObject {}

/// Lightweight line descriptor stored at each tree node.
public struct LineMetrics: Sendable, Equatable {
    public var utf16Length: Int
    public var height: CGFloat

    public init(utf16Length: Int, height: CGFloat) {
        self.utf16Length = utf16Length
        self.height = height
    }
}

/// Position of a line inside the document coordinate system.
public struct LinePosition<Payload: LinePayload>: @unchecked Sendable {
    public let index: Int
    public let utf16Offset: Int
    public let yOffset: CGFloat
    public let metrics: LineMetrics
    public let payload: Payload

    public var utf16Range: NSRange {
        NSRange(location: utf16Offset, length: metrics.utf16Length)
    }

    public var maxY: CGFloat { yOffset + metrics.height }
}

/// Order-statistic red-black tree indexing document lines by UTF-16 offset, line index, and y position.
///
/// Designed for code documents: O(log n) lookup/insert/remove with aggregated length and height metadata.
public final class LineIndex<Payload: LinePayload> {
    fileprivate final class Node {
        enum Color { case red, black }

        var payload: Payload
        var metrics: LineMetrics
        var color: Color = .red

        var left: Node?
        var right: Node?
        weak var parent: Node?

        /// Aggregate of left subtree.
        var leftCount: Int = 0
        var leftLength: Int = 0
        var leftHeight: CGFloat = 0

        init(payload: Payload, metrics: LineMetrics) {
            self.payload = payload
            self.metrics = metrics
        }

        var isRed: Bool { color == .red }
    }

    private var root: Node?

    /// Number of lines.
    public private(set) var count: Int = 0
    /// Total UTF-16 length of all lines.
    public private(set) var length: Int = 0
    /// Total laid-out height.
    public private(set) var height: CGFloat = 0

    public var isEmpty: Bool { count == 0 }

    public init() {}

    // MARK: - Build

    /// Rebuilds the index from ordered line metrics (bulk O(n)).
    public func rebuild(lines: [(Payload, LineMetrics)]) {
        root = nil
        count = 0
        length = 0
        height = 0
        guard !lines.isEmpty else { return }
        root = buildBalanced(lines: lines, start: 0, end: lines.count)
        paintBlack(root)
        recount(root)
        count = lines.count
        length = lines.reduce(0) { $0 + $1.1.utf16Length }
        height = lines.reduce(0) { $0 + $1.1.height }
    }

    public func removeAll() {
        root = nil
        count = 0
        length = 0
        height = 0
    }

    // MARK: - Query

    public func line(atIndex index: Int) -> LinePosition<Payload>? {
        guard index >= 0, index < count, let node = nodeAtIndex(index) else { return nil }
        return position(for: node)
    }

    public func line(atUTF16Offset offset: Int) -> LinePosition<Payload>? {
        guard count > 0 else { return nil }
        let clamped = min(max(0, offset), max(0, length - 1))
        guard let node = nodeAtUTF16Offset(clamped) else { return nil }
        return position(for: node)
    }

    public func line(atY y: CGFloat) -> LinePosition<Payload>? {
        guard count > 0 else { return nil }
        let clamped = min(max(0, y), max(0, height - 0.0001))
        guard let node = nodeAtY(clamped) else { return nil }
        return position(for: node)
    }

    public var first: LinePosition<Payload>? { line(atIndex: 0) }
    public var last: LinePosition<Payload>? { line(atIndex: count - 1) }

    /// Enumerates lines whose vertical span intersects `[minY, maxY)`.
    public func enumerateLines(inYRange minY: CGFloat, maxY: CGFloat, body: (LinePosition<Payload>) -> Void) {
        guard let root else { return }
        enumerate(node: root, yBase: 0, indexBase: 0, offsetBase: 0, minY: minY, maxY: maxY, body: body)
    }

    /// Enumerates all lines in document order.
    public func forEach(_ body: (LinePosition<Payload>) -> Void) {
        guard let root else { return }
        walkInOrder(node: root, yBase: 0, indexBase: 0, offsetBase: 0, body: body)
    }

    // MARK: - Mutation

    public func insert(payload: Payload, metrics: LineMetrics, atIndex index: Int) {
        precondition(index >= 0 && index <= count)
        let node = Node(payload: payload, metrics: metrics)
        if root == nil {
            root = node
            node.color = .black
            count = 1
            length = metrics.utf16Length
            height = metrics.height
            return
        }

        if index == count {
            // Append after last.
            var cursor = root!
            while let right = cursor.right { cursor = right }
            cursor.right = node
            node.parent = cursor
        } else {
            let successor = nodeAtIndex(index)!
            if successor.left == nil {
                successor.left = node
                node.parent = successor
            } else {
                var pred = successor.left!
                while let right = pred.right { pred = right }
                pred.right = node
                node.parent = pred
            }
        }

        count += 1
        length += metrics.utf16Length
        height += metrics.height
        fixupAggregates(from: node.parent)
        insertFixup(node)
    }

    public func remove(atIndex index: Int) {
        guard let node = nodeAtIndex(index) else { return }
        delete(node)
    }

    public func updateMetrics(atIndex index: Int, metrics: LineMetrics) {
        guard let node = nodeAtIndex(index) else { return }
        let deltaLength = metrics.utf16Length - node.metrics.utf16Length
        let deltaHeight = metrics.height - node.metrics.height
        node.metrics = metrics
        length += deltaLength
        height += deltaHeight
        fixupAggregates(from: node.parent)
    }

    public func updatePayload(atIndex index: Int, payload: Payload) {
        nodeAtIndex(index)?.payload = payload
    }
}

// MARK: - Tree internals

extension LineIndex {
    private func buildBalanced(lines: [(Payload, LineMetrics)], start: Int, end: Int) -> Node? {
        guard start < end else { return nil }
        let mid = (start + end) / 2
        let node = Node(payload: lines[mid].0, metrics: lines[mid].1)
        node.color = .black
        node.left = buildBalanced(lines: lines, start: start, end: mid)
        node.left?.parent = node
        node.right = buildBalanced(lines: lines, start: mid + 1, end: end)
        node.right?.parent = node
        return node
    }

    private func paintBlack(_ node: Node?) {
        guard let node else { return }
        node.color = .black
        paintBlack(node.left)
        paintBlack(node.right)
    }

    @discardableResult
    private func recount(_ node: Node?) -> (count: Int, length: Int, height: CGFloat) {
        guard let node else { return (0, 0, 0) }
        let left = recount(node.left)
        let right = recount(node.right)
        node.leftCount = left.count
        node.leftLength = left.length
        node.leftHeight = left.height
        return (
            left.count + 1 + right.count,
            left.length + node.metrics.utf16Length + right.length,
            left.height + node.metrics.height + right.height
        )
    }

    private func fixupAggregates(from node: Node?) {
        var current = node
        while let n = current {
            let left = subtreeStats(n.left)
            n.leftCount = left.count
            n.leftLength = left.length
            n.leftHeight = left.height
            current = n.parent
        }
    }

    private func subtreeStats(_ node: Node?) -> (count: Int, length: Int, height: CGFloat) {
        guard let node else { return (0, 0, 0) }
        let right = subtreeStats(node.right)
        return (
            node.leftCount + 1 + right.count,
            node.leftLength + node.metrics.utf16Length + right.length,
            node.leftHeight + node.metrics.height + right.height
        )
    }

    private func nodeAtIndex(_ index: Int) -> Node? {
        var node = root
        var remaining = index
        while let current = node {
            if remaining < current.leftCount {
                node = current.left
            } else if remaining == current.leftCount {
                return current
            } else {
                remaining -= current.leftCount + 1
                node = current.right
            }
        }
        return nil
    }

    private func nodeAtUTF16Offset(_ offset: Int) -> Node? {
        var node = root
        var remaining = offset
        while let current = node {
            if remaining < current.leftLength {
                node = current.left
            } else if current.metrics.utf16Length == 0 {
                // Zero-length (trailing empty) line sits at this offset — prefer it when remaining
                // lands exactly on the boundary so caret-after-final-newline resolves correctly.
                if remaining == current.leftLength {
                    return current
                }
                remaining -= current.leftLength
                node = current.right
            } else if remaining < current.leftLength + current.metrics.utf16Length {
                return current
            } else {
                remaining -= current.leftLength + current.metrics.utf16Length
                node = current.right
            }
        }
        // Offset at end-of-document maps to last line.
        return lastNode()
    }

    private func nodeAtY(_ y: CGFloat) -> Node? {
        var node = root
        var remaining = y
        while let current = node {
            if remaining < current.leftHeight {
                node = current.left
            } else if remaining < current.leftHeight + current.metrics.height {
                return current
            } else {
                remaining -= current.leftHeight + current.metrics.height
                node = current.right
            }
        }
        return lastNode()
    }

    private func lastNode() -> Node? {
        guard var node = root else { return nil }
        while let right = node.right { node = right }
        return node
    }

    private func position(for node: Node) -> LinePosition<Payload> {
        var index = node.leftCount
        var offset = node.leftLength
        var y = node.leftHeight
        var current = node
        while let parent = current.parent {
            if current === parent.right {
                index += parent.leftCount + 1
                offset += parent.leftLength + parent.metrics.utf16Length
                y += parent.leftHeight + parent.metrics.height
            }
            current = parent
        }
        return LinePosition(
            index: index,
            utf16Offset: offset,
            yOffset: y,
            metrics: node.metrics,
            payload: node.payload
        )
    }

    private func walkInOrder(
        node: Node,
        yBase: CGFloat,
        indexBase: Int,
        offsetBase: Int,
        body: (LinePosition<Payload>) -> Void
    ) {
        if let left = node.left {
            walkInOrder(node: left, yBase: yBase, indexBase: indexBase, offsetBase: offsetBase, body: body)
        }
        let index = indexBase + node.leftCount
        let offset = offsetBase + node.leftLength
        let y = yBase + node.leftHeight
        body(
            LinePosition(
                index: index,
                utf16Offset: offset,
                yOffset: y,
                metrics: node.metrics,
                payload: node.payload
            )
        )
        if let right = node.right {
            walkInOrder(
                node: right,
                yBase: y + node.metrics.height,
                indexBase: index + 1,
                offsetBase: offset + node.metrics.utf16Length,
                body: body
            )
        }
    }

    private func enumerate(
        node: Node,
        yBase: CGFloat,
        indexBase: Int,
        offsetBase: Int,
        minY: CGFloat,
        maxY: CGFloat,
        body: (LinePosition<Payload>) -> Void
    ) {
        let leftHeight = node.leftHeight
        let nodeY = yBase + leftHeight
        let nodeMaxY = nodeY + node.metrics.height
        let totalRightBase = nodeMaxY

        if let left = node.left, yBase + leftHeight > minY {
            enumerate(
                node: left,
                yBase: yBase,
                indexBase: indexBase,
                offsetBase: offsetBase,
                minY: minY,
                maxY: maxY,
                body: body
            )
        }

        if nodeMaxY > minY && nodeY < maxY {
            body(
                LinePosition(
                    index: indexBase + node.leftCount,
                    utf16Offset: offsetBase + node.leftLength,
                    yOffset: nodeY,
                    metrics: node.metrics,
                    payload: node.payload
                )
            )
        }

        if let right = node.right, totalRightBase < maxY {
            enumerate(
                node: right,
                yBase: totalRightBase,
                indexBase: indexBase + node.leftCount + 1,
                offsetBase: offsetBase + node.leftLength + node.metrics.utf16Length,
                minY: minY,
                maxY: maxY,
                body: body
            )
        }
    }
}

// MARK: - Rotations & RB fixup

extension LineIndex {
    private func rotateLeft(_ x: Node) {
        guard let y = x.right else { return }
        x.right = y.left
        y.left?.parent = x
        transplant(u: x, v: y)
        y.left = x
        x.parent = y
        fixupAggregates(from: x)
    }

    private func rotateRight(_ y: Node) {
        guard let x = y.left else { return }
        y.left = x.right
        x.right?.parent = y
        transplant(u: y, v: x)
        x.right = y
        y.parent = x
        fixupAggregates(from: y)
    }

    private func transplant(u: Node, v: Node?) {
        if u.parent == nil {
            root = v
        } else if u === u.parent?.left {
            u.parent?.left = v
        } else {
            u.parent?.right = v
        }
        v?.parent = u.parent
    }

    private func insertFixup(_ node: Node) {
        var z = node
        while let parent = z.parent, parent.isRed {
            let grand = parent.parent
            if parent === grand?.left {
                let uncle = grand?.right
                if let uncle, uncle.isRed {
                    parent.color = .black
                    uncle.color = .black
                    grand?.color = .red
                    z = grand!
                } else {
                    if z === parent.right {
                        z = parent
                        rotateLeft(z)
                    }
                    z.parent?.color = .black
                    z.parent?.parent?.color = .red
                    if let g = z.parent?.parent {
                        rotateRight(g)
                    }
                }
            } else {
                let uncle = grand?.left
                if let uncle, uncle.isRed {
                    parent.color = .black
                    uncle.color = .black
                    grand?.color = .red
                    z = grand!
                } else {
                    if z === parent.left {
                        z = parent
                        rotateRight(z)
                    }
                    z.parent?.color = .black
                    z.parent?.parent?.color = .red
                    if let g = z.parent?.parent {
                        rotateLeft(g)
                    }
                }
            }
        }
        root?.color = .black
        fixupAggregates(from: node)
    }

    private func delete(_ node: Node) {
        // Two children: copy successor line data into this node, then splice out the successor
        // (≤1 child). Never transplant the successor while overwriting its metrics with the
        // deleted line — that discarded the successor line and desynced `length` from the tree.
        if node.left != nil, node.right != nil {
            let succ = minimum(node.right!)
            node.payload = succ.payload
            node.metrics = succ.metrics
            spliceOutNodeWithAtMostOneChild(succ)
            recomputeTotals()
            return
        }

        spliceOutNodeWithAtMostOneChild(node)
        recomputeTotals()
    }

    /// Remove a node that has at most one child (RB-tree splice).
    private func spliceOutNodeWithAtMostOneChild(_ node: Node) {
        let yOriginalColor = node.color
        let x: Node?
        let xParent: Node?

        if node.left == nil {
            x = node.right
            xParent = node.parent
            transplant(u: node, v: node.right)
        } else {
            // node.right == nil (or both nil handled by left == nil first when both nil)
            x = node.left
            xParent = node.parent
            transplant(u: node, v: node.left)
        }

        fixupAggregates(from: xParent ?? root)
        if yOriginalColor == .black {
            deleteFixup(x, parent: xParent)
        }
        fixupAggregates(from: x ?? xParent ?? root)
    }

    /// Recompute count/length/height and left-* aggregates from the live tree (repairs drift).
    private func recomputeTotals() {
        let stats = recount(root)
        count = stats.count
        length = stats.length
        height = stats.height
    }

    private func minimum(_ node: Node) -> Node {
        var current = node
        while let left = current.left { current = left }
        return current
    }

    private func deleteFixup(_ node: Node?, parent: Node?) {
        var x = node
        var xParent = parent
        while x !== root, x?.isRed != true {
            if x === xParent?.left {
                var w = xParent?.right
                if w?.isRed == true {
                    w?.color = .black
                    xParent?.color = .red
                    if let p = xParent { rotateLeft(p) }
                    w = xParent?.right
                }
                if w?.left?.isRed != true, w?.right?.isRed != true {
                    w?.color = .red
                    x = xParent
                    xParent = x?.parent
                } else {
                    if w?.right?.isRed != true {
                        w?.left?.color = .black
                        w?.color = .red
                        if let uncle = w { rotateRight(uncle) }
                        w = xParent?.right
                    }
                    w?.color = xParent?.color ?? .black
                    xParent?.color = .black
                    w?.right?.color = .black
                    if let p = xParent { rotateLeft(p) }
                    x = root
                    xParent = nil
                }
            } else {
                var w = xParent?.left
                if w?.isRed == true {
                    w?.color = .black
                    xParent?.color = .red
                    if let p = xParent { rotateRight(p) }
                    w = xParent?.left
                }
                if w?.right?.isRed != true, w?.left?.isRed != true {
                    w?.color = .red
                    x = xParent
                    xParent = x?.parent
                } else {
                    if w?.left?.isRed != true {
                        w?.right?.color = .black
                        w?.color = .red
                        if let uncle = w { rotateLeft(uncle) }
                        w = xParent?.left
                    }
                    w?.color = xParent?.color ?? .black
                    xParent?.color = .black
                    w?.left?.color = .black
                    if let p = xParent { rotateRight(p) }
                    x = root
                    xParent = nil
                }
            }
        }
        x?.color = .black
    }
}
