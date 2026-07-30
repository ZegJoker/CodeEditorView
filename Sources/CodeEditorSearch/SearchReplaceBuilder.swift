import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace

public struct SearchReplacePlan: Sendable {
    public var query: SearchQuery
    public var replacement: String
    public var matches: [SearchMatch]

    public init(query: SearchQuery, replacement: String, matches: [SearchMatch]) {
        self.query = query
        self.replacement = replacement
        self.matches = matches
    }
}

public enum SearchReplaceBuilder {
    /// Builds a ``WorkspaceEdit`` grouping matches by URI with high→low ranges.
    ///
    /// - Parameters:
    ///   - documentTexts: Optional full text per URI for accurate match extraction / preserve-case.
    ///   - preserveCase: When true, adapt replacement casing to each original match (Xcode AB).
    public static func makeWorkspaceEdit(
        plan: SearchReplacePlan,
        openDocumentVersions: [DocumentURI: DocumentVersion] = [:],
        documentTexts: [DocumentURI: String] = [:],
        preserveCase: Bool = false
    ) throws -> WorkspaceEdit {
        let byURI = Dictionary(grouping: plan.matches, by: \.uri)
        var documentChanges: [DocumentChange] = []

        for (uri, matches) in byURI {
            // Apply high→low so earlier ranges stay valid against pre-edit text.
            let ordered = matches.sorted {
                $0.range.location > $1.range.location
            }
            let fullText = documentTexts[uri]
            var textChanges: [TextChange] = []
            for match in ordered {
                let newText = try replacementText(
                    for: match,
                    template: plan.replacement,
                    query: plan.query,
                    fullText: fullText,
                    preserveCase: preserveCase
                )
                textChanges.append(
                    TextChange(
                        replacedRange: match.range,
                        replacement: newText
                    )
                )
            }
            guard !textChanges.isEmpty else { continue }
            documentChanges.append(
                DocumentChange(
                    uri: uri,
                    expectedVersion: openDocumentVersions[uri],
                    transaction: EditTransaction(changes: textChanges, origin: .programmatic)
                )
            )
        }
        return WorkspaceEdit(documentChanges: documentChanges)
    }

    /// Computes the replacement string for a single match (preview UI + apply).
    public static func replacementText(
        for match: SearchMatch,
        template: String,
        query: SearchQuery,
        fullText: String? = nil,
        preserveCase: Bool = false
    ) throws -> String {
        let matched: String
        if let fullText {
            let ns = fullText as NSString
            let r = match.range.nsRange
            if r.location >= 0, r.location + r.length <= ns.length {
                matched = ns.substring(with: r)
            } else {
                matched = match.preview
            }
        } else {
            matched = matchedSlice(inPreview: match.preview, pattern: query.pattern, query: query)
                ?? match.preview
        }

        var newText: String
        if query.isRegex || query.matchMode == .regularExpression {
            newText = try regexReplace(matched: matched, template: template)
        } else {
            newText = template
        }
        if preserveCase {
            newText = applyPreserveCase(matched: matched, replacement: newText)
        }
        return newText
    }

    /// Xcode-style preserve case: mirror ALL CAPS / Title / lower of the original match.
    public static func applyPreserveCase(matched: String, replacement: String) -> String {
        guard !matched.isEmpty, !replacement.isEmpty else { return replacement }
        let letters = matched.filter(\.isLetter)
        guard !letters.isEmpty else { return replacement }

        if letters.allSatisfy(\.isUppercase) {
            return replacement.uppercased()
        }
        if letters.allSatisfy(\.isLowercase) {
            return replacement.lowercased()
        }
        // Title-ish: first letter upper, rest mixed/lower → capitalize first of replacement.
        if let first = matched.first, first.isUppercase {
            let rest = replacement.dropFirst()
            return String(replacement.prefix(1)).uppercased() + rest.lowercased()
        }
        return replacement
    }

    private static func matchedSlice(
        inPreview preview: String,
        pattern: String,
        query: SearchQuery
    ) -> String? {
        var options: String.CompareOptions = []
        if !query.caseSensitive { options.insert(.caseInsensitive) }
        if query.isRegex || query.matchMode == .regularExpression {
            options.insert(.regularExpression)
        }
        guard let range = preview.range(of: pattern, options: options) else { return nil }
        return String(preview[range])
    }

    private static func regexReplace(
        matched: String,
        template: String
    ) throws -> String {
        if template.contains("$") {
            return template.replacingOccurrences(of: "$0", with: matched)
        }
        return template
    }
}
