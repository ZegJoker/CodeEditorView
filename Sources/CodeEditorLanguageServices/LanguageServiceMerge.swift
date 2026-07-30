import Foundation
import CodeEditorCore

/// Explicit multi-provider merge strategies for language service results.
public enum MergePolicy: Sendable, Hashable {
    /// Concatenate all results, ordered by provider priority (then item sort keys).
    case mergeAllByPriority
    /// Use only the highest-priority provider that produces a non-empty / non-nil result.
    case highestPriorityOnly
    /// Merge hover sections, capped at `max`.
    case mergeHoverSections(max: Int)
    /// Concatenate semantic token spans (provider id tagging is caller's job).
    case mergeSemanticTokens
    /// First non-empty folding set by priority.
    case foldingWithFallback
}

// MARK: - Merge helpers

public enum LanguageServiceMerge {
    /// Dedupes completion items by `label` + primary edit text / insert text.
    public static func completions(
        from batches: [(priority: Int, list: CompletionList)]
    ) -> CompletionList {
        var incomplete = false
        var seen = Set<String>()
        var items: [CompletionItem] = []

        let ordered = batches.sorted { $0.priority > $1.priority }
        for batch in ordered {
            if batch.list.isIncomplete { incomplete = true }
            let sortedItems = batch.list.items.sorted { lhs, rhs in
                let ls = lhs.sortText ?? lhs.label
                let rs = rhs.sortText ?? rhs.label
                if ls != rs { return ls < rs }
                return lhs.label < rhs.label
            }
            for item in sortedItems {
                let key = completionDedupeKey(item)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                items.append(item)
            }
        }
        return CompletionList(isIncomplete: incomplete, items: items)
    }

    public static func diagnostics(_ batches: [[LanguageDiagnostic]]) -> [LanguageDiagnostic] {
        let merged = batches.flatMap { $0 }
        return merged.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length < rhs.range.length
            }
            return severityRank(lhs.severity) < severityRank(rhs.severity)
        }
    }

    public static func hoverSections(
        _ batches: [Hover],
        max: Int
    ) -> Hover? {
        var sections: [HoverSection] = []
        for hover in batches {
            for section in hover.sections {
                if sections.count >= max { break }
                sections.append(section)
            }
            if sections.count >= max { break }
        }
        return sections.isEmpty ? nil : Hover(sections: sections)
    }

    public static func locations(_ batches: [[Location]]) -> [Location] {
        var seen = Set<String>()
        var result: [Location] = []
        for batch in batches {
            for loc in batch {
                let key = "\(loc.uri.rawValue)@\(loc.range.location):\(loc.range.length)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(loc)
            }
        }
        return result
    }

    public static func locationLinks(_ batches: [[LocationLink]]) -> [LocationLink] {
        var seen = Set<String>()
        var result: [LocationLink] = []
        for batch in batches {
            for link in batch {
                let key = "\(link.targetURI.rawValue)@\(link.targetRange.location):\(link.targetRange.length)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(link)
            }
        }
        return result
    }

    public static func documentSymbols(_ batches: [[DocumentSymbol]]) -> [DocumentSymbol] {
        batches.flatMap { $0 }
    }

    public static func workspaceSymbols(_ batches: [[WorkspaceSymbol]]) -> [WorkspaceSymbol] {
        batches.flatMap { $0 }
    }

    public static func codeActions(_ batches: [[CodeAction]]) -> [CodeAction] {
        batches.flatMap { $0 }
    }

    public static func semanticTokens(_ batches: [[SemanticTokenSpan]]) -> [SemanticTokenSpan] {
        batches.flatMap { $0 }.sorted { $0.range.location < $1.range.location }
    }

    public static func inlayHints(_ batches: [[InlayHint]]) -> [InlayHint] {
        batches.flatMap { $0 }.sorted {
            $0.position.utf16Offset < $1.position.utf16Offset
        }
    }

    public static func documentLinks(_ batches: [[DocumentLink]]) -> [DocumentLink] {
        batches.flatMap { $0 }
    }

    public static func documentColors(_ batches: [[ColorInformation]]) -> [ColorInformation] {
        batches.flatMap { $0 }
    }

    public static func foldingRanges(_ batches: [[FoldingRange]]) -> [FoldingRange] {
        for batch in batches where !batch.isEmpty {
            return batch
        }
        return []
    }

    // MARK: - Private

    private static func completionDedupeKey(_ item: CompletionItem) -> String {
        let edit = item.textEdit.map { "\($0.range.location):\($0.range.length):\($0.newText)" }
            ?? item.insertText
            ?? item.label
        return "\(item.label)|\(edit)"
    }

    private static func severityRank(_ severity: LanguageDiagnosticSeverity) -> Int {
        switch severity {
        case .error: return 0
        case .warning: return 1
        case .information: return 2
        case .hint: return 3
        }
    }
}
