import CodeEditorCore
import CodeEditorDocuments
import CodeEditorWorkspace
import Foundation

/// Snapshot-bound multi-file search replace (SRCH-N09).
///
/// Preview **pins** document content states, versions, file identities, and text.
/// Commit applies a workspace transaction only when live documents still match those pins;
/// otherwise it fails closed (no partial multi-file mutation).
@MainActor
public enum SearchReplaceService {
    /// Immutable preview snapshot for a replace plan.
    public struct PinnedReplace: Sendable {
        public var plan: SearchReplacePlan
        public var documents: [DocumentURI: SearchReplacePinnedDocument]
        public var preserveCase: Bool

        public init(
            plan: SearchReplacePlan,
            documents: [DocumentURI: SearchReplacePinnedDocument],
            preserveCase: Bool = false
        ) {
            self.plan = plan
            self.documents = documents
            self.preserveCase = preserveCase
        }
    }

    /// Capture content-state / version / text pins for every document referenced by `matches`.
    public static func pin(
        matches: [SearchMatch],
        from workspace: Workspace,
        query: SearchQuery,
        replacement: String,
        preserveCase: Bool = false
    ) -> PinnedReplace {
        var docs: [DocumentURI: SearchReplacePinnedDocument] = [:]
        let uris = Set(matches.map(\.uri))
        for uri in uris {
            guard let doc = workspace.lifecycle.document(uri: uri)
                ?? workspace.documents.document(uri: uri)
            else { continue }
            docs[uri] = SearchReplacePinnedDocument(
                uri: uri,
                version: doc.version,
                contentState: doc.contentState,
                fileIdentity: doc.fileIdentity,
                text: doc.text
            )
        }
        var plan = SearchReplacePlan(
            query: query,
            replacement: replacement,
            matches: matches,
            pinnedDocuments: docs
        )
        plan.pinnedDocuments = docs
        return PinnedReplace(plan: plan, documents: docs, preserveCase: preserveCase)
    }

    /// Commit a previously pinned plan via transactional ``WorkspaceEditService``.
    ///
    /// Revalidates content state and version against live documents before prepare/commit.
    public static func commit(
        pinned: PinnedReplace,
        to workspace: Workspace
    ) async throws -> WorkspaceEditResult {
        // Fail closed if any pin is stale (SRCH-N09).
        for (uri, pin) in pinned.documents {
            guard let doc = workspace.lifecycle.document(uri: uri)
                ?? workspace.documents.document(uri: uri)
            else {
                throw SearchReplaceError.missingPinnedText(uri: uri.rawValue)
            }
            if doc.contentState != pin.contentState {
                throw SearchReplaceError.contentStateMismatch(uri: uri.rawValue)
            }
            if doc.version != pin.version {
                throw SearchReplaceError.versionMismatch(
                    uri: uri.rawValue,
                    expected: pin.version.rawValue,
                    actual: doc.version.rawValue
                )
            }
        }

        var versions: [DocumentURI: DocumentVersion] = [:]
        var texts: [DocumentURI: String] = [:]
        for (uri, pin) in pinned.documents {
            versions[uri] = pin.version
            texts[uri] = pin.text
        }
        let edit = try SearchReplaceBuilder.makeWorkspaceEdit(
            plan: pinned.plan,
            openDocumentVersions: versions,
            documentTexts: texts,
            preserveCase: pinned.preserveCase
        )
        let service = WorkspaceEditService(workspace: workspace)
        return try await service.apply(edit)
    }

    /// Convenience: pin-from-workspace then apply (legacy path; still snapshot-bound).
    public static func apply(
        plan: SearchReplacePlan,
        to workspace: Workspace,
        preserveCase: Bool = false
    ) async throws -> WorkspaceEditResult {
        let pinned = pin(
            matches: plan.matches,
            from: workspace,
            query: plan.query,
            replacement: plan.replacement,
            preserveCase: preserveCase
        )
        // Merge any caller-supplied pins with live pins (live wins on conflict).
        var merged = pinned
        if !plan.pinnedDocuments.isEmpty {
            var docs = plan.pinnedDocuments
            for (uri, live) in pinned.documents {
                docs[uri] = live
            }
            merged = PinnedReplace(
                plan: SearchReplacePlan(
                    query: plan.query,
                    replacement: plan.replacement,
                    matches: plan.matches,
                    pinnedDocuments: docs
                ),
                documents: docs,
                preserveCase: preserveCase
            )
        }
        return try await commit(pinned: merged, to: workspace)
    }
}
