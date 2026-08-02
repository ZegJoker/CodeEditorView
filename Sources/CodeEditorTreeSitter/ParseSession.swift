import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Immutable syntax snapshot tagged with document + language generation (LANG-N03).
///
/// UI layers consume these values and discard any whose generations are stale.
public struct ParseSnapshot: Sendable, Hashable {
    public var documentVersion: UInt64
    public var languageGeneration: UInt64
    public var sourceUTF16Length: Int
    public var hasTree: Bool

    public init(
        documentVersion: UInt64,
        languageGeneration: UInt64,
        sourceUTF16Length: Int,
        hasTree: Bool
    ) {
        self.documentVersion = documentVersion
        self.languageGeneration = languageGeneration
        self.sourceUTF16Length = sourceUTF16Length
        self.hasTree = hasTree
    }
}

/// Immutable highlight publication tagged with document/language generation (LANG-N03).
public struct HighlightSnapshot: Sendable, Hashable {
    public var documentVersion: UInt64
    public var languageGeneration: UInt64
    public var highlights: [HighlightRange]
    public var sourceLengthUTF16: Int

    public init(
        documentVersion: UInt64,
        languageGeneration: UInt64,
        highlights: [HighlightRange],
        sourceLengthUTF16: Int
    ) {
        self.documentVersion = documentVersion
        self.languageGeneration = languageGeneration
        self.highlights = highlights
        self.sourceLengthUTF16 = sourceLengthUTF16
    }

    /// Compatibility alias for document version (historical ``HighlightPublication.generation``).
    public var generation: UInt64 { documentVersion }
}

/// Single actor-owned parse state per `(document, languageGeneration)` (LANG-N03).
///
/// Owns the only parser/tree for a document path. Callers must not maintain a
/// parallel main-actor tree; consume ``ParseSnapshot`` / ``HighlightSnapshot`` only.
public actor ParseSession {
    public enum EngineError: Error, Sendable, Equatable {
        case notConfigured
        case queryMissing(String)
        case cancelled
        case staleGeneration
    }

    /// Language pointer ownership retained for the session lifetime (LANG-N04).
    private var languageRef: TSLanguageRef?
    private var parser = Parser()
    private var tree: MutableTree?
    private var configuration: LanguageConfiguration?
    private var source: String = ""
    private var documentLength: Int = 0
    /// Document content generation (increments on setText / applyEdit).
    public private(set) var documentVersion: UInt64 = 0
    /// Language configuration generation (increments on configure / reset).
    public private(set) var languageGeneration: UInt64 = 0
    public private(set) var lastPublishedDocumentVersion: UInt64 = 0

    public init() {}

    /// Historical name for document version.
    public var currentGeneration: UInt64 { documentVersion }
    public var lastPublishedGeneration: UInt64 { lastPublishedDocumentVersion }

    /// Install language configuration. Query compile is the caller's responsibility
    /// (already off-main via ``TreeSitterConfigurationFactory``).
    public func configure(_ config: LanguageConfiguration, languageRef: TSLanguageRef? = nil) throws {
        try parser.setLanguage(config.language)
        configuration = config
        self.languageRef = languageRef
        tree = nil
        source = ""
        documentLength = 0
        languageGeneration &+= 1
        documentVersion &+= 1
    }

    public func reset() {
        tree = nil
        source = ""
        documentLength = 0
        configuration = nil
        languageRef = nil
        languageGeneration &+= 1
        documentVersion &+= 1
    }

    public func snapshot() -> ParseSnapshot {
        ParseSnapshot(
            documentVersion: documentVersion,
            languageGeneration: languageGeneration,
            sourceUTF16Length: documentLength,
            hasTree: tree != nil
        )
    }

    /// Full parse of document text. Returns the new document version.
    @discardableResult
    public func setText(_ text: String) throws -> UInt64 {
        source = text
        documentLength = (text as NSString).length
        if configuration != nil {
            tree = parser.parse(text)
        } else {
            tree = nil
        }
        documentVersion &+= 1
        return documentVersion
    }

    /// Incremental edit against the single owned tree.
    public func applyEdit(
        range: NSRange,
        delta: Int,
        newText: String
    ) throws -> (invalid: IndexSet, documentVersion: UInt64) {
        guard configuration != nil else {
            source = newText
            documentLength = (newText as NSString).length
            tree = nil
            documentVersion &+= 1
            return (IndexSet(integersIn: 0..<max(0, documentLength)), documentVersion)
        }
        guard let existingTree = tree else {
            source = newText
            documentLength = (newText as NSString).length
            tree = parser.parse(newText)
            documentVersion &+= 1
            return (IndexSet(integersIn: 0..<max(0, documentLength)), documentVersion)
        }
        let inputEdit = TreeSitterEdit.make(
            range: range,
            delta: delta,
            oldSource: source,
            newSource: newText
        )
        existingTree.edit(inputEdit)
        let oldTree = existingTree
        source = newText
        documentLength = (newText as NSString).length
        let newTree = parser.parse(tree: oldTree, string: newText)
        tree = newTree
        var invalid = IndexSet()
        if let newTree {
            let changed = oldTree.changedRanges(from: newTree)
            invalid.formUnion(TreeSitterEdit.indexSet(from: changed, documentLength: documentLength))
        }
        let editStart = max(0, range.location)
        let editEnd = min(documentLength, range.location + max(0, range.length + delta))
        if editEnd > editStart {
            invalid.insert(integersIn: editStart..<editEnd)
        }
        documentVersion &+= 1
        return (invalid, documentVersion)
    }

    /// Compatibility return shape used by older call sites.
    public func applyEditReturningGeneration(
        range: NSRange,
        delta: Int,
        newText: String
    ) throws -> (invalid: IndexSet, generation: UInt64) {
        let result = try applyEdit(range: range, delta: delta, newText: newText)
        return (result.invalid, result.documentVersion)
    }

    /// Query highlights for a range. Tags result with current document + language generation.
    public func queryHighlights(in range: NSRange) throws -> HighlightSnapshot {
        try Task.checkCancellation()
        guard let configuration else {
            throw EngineError.notConfigured
        }
        guard let highlightsQuery = configuration.queries[.highlights] else {
            throw EngineError.queryMissing("highlights")
        }
        guard let tree, range.length > 0, !source.isEmpty else {
            return HighlightSnapshot(
                documentVersion: documentVersion,
                languageGeneration: languageGeneration,
                highlights: [],
                sourceLengthUTF16: documentLength
            )
        }
        let cursor = highlightsQuery.execute(in: tree)
        cursor.setRange(range)
        let named =
            cursor
            .resolve(with: Predicate.Context(string: source))
            .highlights()
        var results: [HighlightRange] = []
        results.reserveCapacity(min(named.count, 256))
        for namedRange in named {
            try Task.checkCancellation()
            let intersection = NSIntersectionRange(namedRange.range, range)
            guard intersection.length > 0 else { continue }
            let capture = CaptureName.from(capture: namedRange.name)
            if capture == nil, namedRange.name == "none" || namedRange.name.hasPrefix("none") {
                continue
            }
            results.append(
                HighlightRange(range: intersection, capture: capture, rawCapture: namedRange.name)
            )
        }
        lastPublishedDocumentVersion = documentVersion
        return HighlightSnapshot(
            documentVersion: documentVersion,
            languageGeneration: languageGeneration,
            highlights: results,
            sourceLengthUTF16: documentLength
        )
    }

    /// Nearest identifier-like range at a UTF-16 offset (read from the single tree).
    public func identifierRange(atUTF16Offset location: Int) -> NSRange? {
        guard let root = tree?.rootNode else { return nil }
        let length = max(source.utf16.count, documentLength)
        guard length > 0 else { return nil }
        let clamped = min(max(0, location), length - 1)
        let byteStart = UInt32(clamped * 2)
        let byteEnd = UInt32((clamped + 1) * 2)
        guard let node = root.descendant(in: byteStart..<byteEnd) else { return nil }

        var current: Node? = node
        while let n = current {
            if let type = n.nodeType, type.localizedCaseInsensitiveContains("identifier") {
                return Self.clampedIdentifierRange(n.range, documentLength: length)
            }
            current = n.parent
        }
        if node.isNamed, node.range.length > 0, node.range.length <= 64 {
            return Self.clampedIdentifierRange(node.range, documentLength: length)
        }
        return nil
    }

    /// Accept a publication only if both generations still match (LANG-N03 / TS-002).
    public func isCurrent(documentVersion ver: UInt64, languageGeneration langGen: UInt64) -> Bool {
        ver == documentVersion && langGen == languageGeneration
    }

    /// Back-compat generation check (document version only).
    public func isCurrent(generation gen: UInt64) -> Bool {
        gen == documentVersion
    }

    /// Whether the session still holds a language ref (grammar outlives session work).
    public func retainedLanguageID() -> LanguageID? {
        languageRef?.languageID
    }

    /// Full ownership handle retained for the session lifetime (LANG-N04).
    public func retainedLanguageRef() -> TSLanguageRef? {
        languageRef
    }

    private static func clampedIdentifierRange(_ range: NSRange, documentLength: Int) -> NSRange? {
        guard range.location >= 0, range.location < documentLength else { return nil }
        let maxLen = 64
        let len = min(range.length, maxLen, documentLength - range.location)
        guard len > 0 else { return nil }
        return NSRange(location: range.location, length: len)
    }
}

// MARK: - LanguageDocumentActor (compatibility name)

/// Historical name for the off-main parse engine (LANG-N03).
///
/// Prefer ``ParseSession`` in new code. This is the same actor type.
public typealias LanguageDocumentActor = ParseSession

extension ParseSession {
    public typealias HighlightPublication = HighlightSnapshot
}
