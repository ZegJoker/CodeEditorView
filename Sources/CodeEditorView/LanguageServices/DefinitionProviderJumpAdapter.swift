import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation

/// Bridges ``DefinitionProvider`` / host definitions into ``JumpToDefinitionDelegate``.
@MainActor
public final class DefinitionProviderJumpAdapter: JumpToDefinitionDelegate {
    public let host: LanguageServiceHost
    public var context: LanguageServiceContext
    public var onOpenRemoteURL: ((URL) -> Void)?

    public init(
        host: LanguageServiceHost,
        context: LanguageServiceContext = LanguageServiceContext(),
        onOpenRemoteURL: ((URL) -> Void)? = nil
    ) {
        self.host = host
        self.context = context
        self.onOpenRemoteURL = onOpenRemoteURL
    }

    public func queryLinks(
        forRange range: NSRange,
        textView: EditorController
    ) async -> [JumpToDefinitionLink]? {
        let snapshot = textView.textDocument.snapshot()
        var ctx = context
        if ctx.languageID == nil { ctx.languageID = textView.languageID }
        if ctx.uri == nil { ctx.uri = textView.textDocument.uri }

        let request = PositionRequest(
            document: snapshot,
            position: TextPosition(utf16Offset: range.location),
            context: ctx
        )
        do {
            let links = try await host.definitions(for: request) { snapshot.version }
            guard textView.textDocument.version == snapshot.version else { return nil }
            guard !links.isEmpty else { return [] }

            return links.map { link in
                Self.makeJumpLink(from: link, fallbackDocument: snapshot.text)
            }
        } catch {
            return nil
        }
    }

    public func openLink(link: JumpToDefinitionLink) {
        if let url = link.url {
            onOpenRemoteURL?(url)
        }
    }

    public static func makeJumpLink(
        from link: LocationLink,
        fallbackDocument: String
    ) -> JumpToDefinitionLink {
        let nsRange = link.targetSelectionRange?.nsRange ?? link.targetRange.nsRange
        let cursor = LanguageServiceTextGeometry.cursorPosition(for: nsRange, in: fallbackDocument)
        let url: URL?
        if let file = link.targetURI.fileURL {
            url = file
        } else if link.targetURI.isInMemory {
            url = nil
        } else {
            url = URL(string: link.targetURI.rawValue)
        }
        let label =
            url?.lastPathComponent
            ?? "L\(cursor.line + 1):\(cursor.column + 1)"
        return JumpToDefinitionLink(
            url: url,
            targetRange: cursor,
            label: label,
            detail: link.targetURI.rawValue
        )
    }
}

/// Line/column geometry helpers shared by language-service adapters (nonisolated).
public enum LanguageServiceTextGeometry {
    public static func cursorPosition(for range: NSRange, in text: String) -> CursorPosition {
        let ns = text as NSString
        let loc = min(max(0, range.location), ns.length)
        var line = 0
        var lineStart = 0
        var i = 0
        while i < loc {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {  // \n
                line += 1
                lineStart = i
            } else if ch == 0x0D {  // \r
                if i < ns.length, ns.character(at: i) == 0x0A {
                    i += 1
                }
                line += 1
                lineStart = i
            }
        }
        return CursorPosition(
            range: NSRange(location: loc, length: max(0, range.length)),
            line: line,
            column: max(0, loc - lineStart)
        )
    }
}
