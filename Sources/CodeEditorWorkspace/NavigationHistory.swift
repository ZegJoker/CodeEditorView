import CodeEditorCore
import CodeEditorDocuments
import CoreGraphics
import Foundation

public struct NavigationEntry: Codable, Sendable, Hashable {
    public var documentURI: DocumentURI
    public var documentID: DocumentID?
    public var sessionID: EditorSessionID?
    public var selection: CodeEditorCore.TextRange?
    public var scrollY: Double?

    public init(
        documentURI: DocumentURI,
        documentID: DocumentID? = nil,
        sessionID: EditorSessionID? = nil,
        selection: CodeEditorCore.TextRange? = nil,
        scrollY: Double? = nil
    ) {
        self.documentURI = documentURI
        self.documentID = documentID
        self.sessionID = sessionID
        self.selection = selection
        self.scrollY = scrollY
    }
}

@MainActor
public final class NavigationHistory {
    private var stack: [NavigationEntry] = []
    private var index: Int = -1
    public let capacity: Int

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index < stack.count - 1 }
    public var current: NavigationEntry? {
        guard index >= 0, index < stack.count else { return nil }
        return stack[index]
    }

    public func push(_ entry: NavigationEntry) {
        if index >= 0, index < stack.count - 1 {
            stack = Array(stack.prefix(index + 1))
        }
        if let last = stack.last, last == entry { return }
        stack.append(entry)
        if stack.count > capacity {
            stack.removeFirst(stack.count - capacity)
        }
        index = stack.count - 1
    }

    public func back() -> NavigationEntry? {
        guard canGoBack else { return nil }
        index -= 1
        return stack[index]
    }

    public func forward() -> NavigationEntry? {
        guard canGoForward else { return nil }
        index += 1
        return stack[index]
    }

    public func entries() -> [NavigationEntry] { stack }
    public func setEntries(_ entries: [NavigationEntry], index: Int) {
        stack = entries
        self.index = min(max(index, -1), stack.count - 1)
    }
}
