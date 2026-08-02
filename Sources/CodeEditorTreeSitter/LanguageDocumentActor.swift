import CodeEditorLanguageSupport
import Foundation
import SwiftTreeSitter

/// Per-document Tree-sitter engine isolated off the main actor (TS-001 / §12.2).
///
/// Holds parser, tree, and queries. Publishes generation-tagged highlight results;
/// callers must discard results whose generation is older than the latest accepted.
public actor LanguageDocumentActor {
    public struct HighlightPublication: Sendable {
        public var generation: UInt64
        public var highlights: [HighlightRange]
        public var sourceLengthUTF16: Int
    }

    public enum EngineError: Error, Sendable, Equatable {
        case notConfigured
        case queryMissing(String)
        case cancelled
    }

    private var parser = Parser()
    private var tree: MutableTree?
    private var configuration: LanguageConfiguration?
    private var source: String = ""
    private var documentLength: Int = 0
    private var generation: UInt64 = 0
    public private(set) var lastPublishedGeneration: UInt64 = 0

    public init() {}

    public var currentGeneration: UInt64 { generation }

    /// Install language configuration (query compile may be expensive — already off-main).
    public func configure(_ config: LanguageConfiguration) throws {
        try parser.setLanguage(config.language)
        configuration = config
        tree = nil
        source = ""
        documentLength = 0
        generation &+= 1
    }

    public func reset() {
        tree = nil
        source = ""
        documentLength = 0
        configuration = nil
        generation &+= 1
    }

    /// Full parse of document text. Returns generation of this parse.
    @discardableResult
    public func setText(_ text: String) throws -> UInt64 {
        guard configuration != nil else {
            source = text
            documentLength = (text as NSString).length
            tree = nil
            generation &+= 1
            return generation
        }
        source = text
        documentLength = (text as NSString).length
        tree = parser.parse(text)
        generation &+= 1
        return generation
    }

    /// Incremental edit. Returns invalidation index set + generation.
    public func applyEdit(
        range: NSRange,
        delta: Int,
        newText: String
    ) throws -> (invalid: IndexSet, generation: UInt64) {
        guard configuration != nil else {
            source = newText
            documentLength = (newText as NSString).length
            tree = nil
            generation &+= 1
            return (IndexSet(integersIn: 0..<max(0, documentLength)), generation)
        }
        guard let existingTree = tree else {
            source = newText
            documentLength = (newText as NSString).length
            tree = parser.parse(newText)
            generation &+= 1
            return (IndexSet(integersIn: 0..<max(0, documentLength)), generation)
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
        generation &+= 1
        return (invalid, generation)
    }

    /// Query highlights for a range. Tags result with current generation.
    public func queryHighlights(in range: NSRange) throws -> HighlightPublication {
        try Task.checkCancellation()
        guard let configuration else {
            throw EngineError.notConfigured
        }
        guard let highlightsQuery = configuration.queries[.highlights] else {
            throw EngineError.queryMissing("highlights")
        }
        guard let tree, range.length > 0, !source.isEmpty else {
            return HighlightPublication(
                generation: generation, highlights: [], sourceLengthUTF16: documentLength)
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
        lastPublishedGeneration = generation
        return HighlightPublication(
            generation: generation, highlights: results, sourceLengthUTF16: documentLength)
    }

    /// Accept a publication only if its generation is still current (TS-002).
    public func isCurrent(generation gen: UInt64) -> Bool {
        gen == generation
    }
}
