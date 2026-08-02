import CodeEditorCommands
import CodeEditorExtensionAPI
import CodeEditorLanguageSupport
import Foundation

// Re-export contribution value types from the author API.
// Stores remain host-owned.

// MARK: - Panel store

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

// MARK: - Theme store

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

// MARK: - Snippet store

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

// MARK: - Icon theme store

public final class IconThemeContributionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: IconThemeContribution] = [:]

    public init() {}

    public func register(_ theme: IconThemeContribution) {
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

    public func all() -> [IconThemeContribution] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.values).sorted { $0.id < $1.id }
    }
}

// MARK: - Language DTO helpers

extension LanguageDefinitionDTO {
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
