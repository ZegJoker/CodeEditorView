import Foundation
import CodeEditorCommands
import CodeEditorLanguageSupport

// MARK: - Panel (UI-free descriptor)

public struct PanelContribution: Sendable, Hashable, Identifiable {
    public var id: String
    public var slot: String
    public var title: String
    public var priority: Int
    public var extensionID: ExtensionID

    public init(
        id: String,
        slot: String,
        title: String,
        priority: Int = 0,
        extensionID: ExtensionID
    ) {
        self.id = id
        self.slot = slot
        self.title = title
        self.priority = priority
        self.extensionID = extensionID
    }
}

public final class PanelContributionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: PanelContribution] = [:]

    public init() {}

    public func register(_ panel: PanelContribution) {
        lock.lock()
        items[panel.id] = panel
        lock.unlock()
    }

    public func unregister(id: String) {
        lock.lock()
        items.removeValue(forKey: id)
        lock.unlock()
    }

    public func unregister(extensionID: ExtensionID) {
        lock.lock()
        items = items.filter { $0.value.extensionID != extensionID }
        lock.unlock()
    }

    public func all() -> [PanelContribution] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.id < $1.id
        }
    }

    public func panels(slot: String) -> [PanelContribution] {
        all().filter { $0.slot == slot }
    }
}

// MARK: - Themes / snippets

public struct ThemeContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var displayName: String
    /// Simple token map (e.g. `"keyword"` → `"#FF00AA"`).
    public var tokens: [String: String]
    public var extensionID: ExtensionID?

    public init(
        id: String,
        displayName: String,
        tokens: [String: String] = [:],
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.tokens = tokens
        self.extensionID = extensionID
    }
}

public final class ThemeContributionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: ThemeContribution] = [:]

    public init() {}

    public func register(_ theme: ThemeContribution) {
        lock.lock()
        items[theme.id] = theme
        lock.unlock()
    }

    public func unregister(id: String) {
        lock.lock()
        items.removeValue(forKey: id)
        lock.unlock()
    }

    public func unregister(extensionID: ExtensionID) {
        lock.lock()
        items = items.filter { $0.value.extensionID != extensionID }
        lock.unlock()
    }

    public func all() -> [ThemeContribution] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values).sorted { $0.id < $1.id }
    }

    public func theme(id: String) -> ThemeContribution? {
        lock.lock()
        defer { lock.unlock() }
        return items[id]
    }
}

public struct SnippetContribution: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var prefix: String
    public var body: String
    public var languageID: String?
    public var description: String?
    public var extensionID: ExtensionID?

    public init(
        id: String,
        prefix: String,
        body: String,
        languageID: String? = nil,
        description: String? = nil,
        extensionID: ExtensionID? = nil
    ) {
        self.id = id
        self.prefix = prefix
        self.body = body
        self.languageID = languageID
        self.description = description
        self.extensionID = extensionID
    }
}

public final class SnippetContributionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SnippetContribution] = [:]

    public init() {}

    public func register(_ snippet: SnippetContribution) {
        lock.lock()
        items[snippet.id] = snippet
        lock.unlock()
    }

    public func unregister(id: String) {
        lock.lock()
        items.removeValue(forKey: id)
        lock.unlock()
    }

    public func unregister(extensionID: ExtensionID) {
        lock.lock()
        items = items.filter { $0.value.extensionID != extensionID }
        lock.unlock()
    }

    public func all() -> [SnippetContribution] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values).sorted { $0.id < $1.id }
    }

    public func snippets(languageID: String?) -> [SnippetContribution] {
        all().filter { snippet in
            guard let languageID else { return true }
            guard let lid = snippet.languageID else { return true }
            return lid.lowercased() == languageID.lowercased()
        }
    }
}

// MARK: - Codable language definition (data extensions)

public struct LanguageDefinitionDTO: Sendable, Hashable, Codable {
    public var id: String
    public var displayName: String
    public var tsName: String
    public var fileExtensions: [String]
    public var aliases: [String]
    public var lineComment: String
    public var blockCommentStart: String
    public var blockCommentEnd: String

    public init(
        id: String,
        displayName: String,
        tsName: String = "",
        fileExtensions: [String] = [],
        aliases: [String] = [],
        lineComment: String = "",
        blockCommentStart: String = "",
        blockCommentEnd: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.tsName = tsName.isEmpty ? id : tsName
        self.fileExtensions = fileExtensions
        self.aliases = aliases
        self.lineComment = lineComment
        self.blockCommentStart = blockCommentStart
        self.blockCommentEnd = blockCommentEnd
    }

    public func makeDefinition() -> LanguageDefinition {
        LanguageDefinition(
            id: LanguageID(rawValue: id),
            displayName: displayName,
            tsName: tsName,
            fileExtensions: Set(fileExtensions),
            aliases: Set(aliases),
            lineComment: lineComment,
            blockComment: (blockCommentStart, blockCommentEnd)
        )
    }
}
