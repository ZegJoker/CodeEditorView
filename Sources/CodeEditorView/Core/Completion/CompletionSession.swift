import Foundation

/// Mutable completion popup state owned by ``EditorController``.
@MainActor
public final class CompletionSession {
    public private(set) var isVisible: Bool = false
    public private(set) var items: [any CodeSuggestionEntry] = []
    public var selectedIndex: Int = 0
    /// Cursor used to place the popup (from the last successful request).
    public var anchorPosition: CursorPosition?
    /// Bumped when UI should refresh (items/selection/visibility).
    public private(set) var revision: Int = 0

    public var selectedItem: (any CodeSuggestionEntry)? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    public init() {}

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible {
            items = []
            selectedIndex = 0
            anchorPosition = nil
        }
        bump()
    }

    public func setItems(_ newItems: [any CodeSuggestionEntry], anchor: CursorPosition?) {
        items = newItems
        selectedIndex = 0
        anchorPosition = anchor
        isVisible = !newItems.isEmpty
        if newItems.isEmpty {
            anchorPosition = nil
        }
        bump()
    }

    public func moveSelection(delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        bump()
    }

    public func selectIndex(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        bump()
    }

    private func bump() {
        revision &+= 1
    }
}
