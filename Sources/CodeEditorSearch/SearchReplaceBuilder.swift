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
    public static func makeWorkspaceEdit(
        plan: SearchReplacePlan,
        openDocumentVersions: [DocumentURI: DocumentVersion] = [:]
    ) throws -> WorkspaceEdit {
        let byURI = Dictionary(grouping: plan.matches, by: \.uri)
        var documentChanges: [DocumentChange] = []

        for (uri, matches) in byURI {
            // Apply high→low so earlier ranges stay valid against pre-edit text.
            let ordered = matches.sorted {
                $0.range.location > $1.range.location
            }
            var textChanges: [TextChange] = []
            for match in ordered {
                let newText: String
                if plan.query.isRegex {
                    newText = try regexReplace(
                        match: match,
                        template: plan.replacement,
                        query: plan.query
                    )
                } else {
                    newText = plan.replacement
                }
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

    private static func regexReplace(
        match: SearchMatch,
        template: String,
        query: SearchQuery
    ) throws -> String {
        // Without original full text, simple template with no backrefs is identity.
        // Hosts that need group substitution should pass expanded text; support $0 as match preview slice.
        if template.contains("$") {
            // Limited: only replace $0 with matched preview substring if present in preview.
            return template.replacingOccurrences(of: "$0", with: match.preview)
        }
        return template
    }
}
