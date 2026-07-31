import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensionGuest
import CodeEditorLanguageServices
import CodeEditorCore
import CodeEditorDocuments

/// Representative Swift extension used for dual-run (in-process + native helper) conformance.
public struct ConformanceExtension: CodeEditorExtension {
    public init() {}

    public var manifest: ExtensionManifest {
        ExtensionManifest(
            id: "com.codeeditor.conformance",
            displayName: "Conformance Extension",
            version: SemanticVersion(major: 1, minor: 0, patch: 0),
            activationEvents: [.startup],
            requiredHostCapabilities: [.languageServices, .storage],
            requestedPermissions: [.readWorkspace]
        )
    }

    public func activate(in context: any ExtensionAuthorContext) async throws {
        context.info("conformance activated")
    }

    public func deactivate() async {}
}

@main
struct ConformanceExtensionGuestMain {
    static func main() async {
        let ext = ConformanceExtension()
        let transport = StdioWireTransport()
        let runtime = ExtensionGuestRuntime(extension: ext, transport: transport)
        await runtime.installDefaultLanguageHandlers()
        await runtime.run()
        // Park until host tears down the process (stdin EOF → transport close).
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}

extension ExtensionGuestRuntime {
    func installDefaultLanguageHandlers() {
        completionHandler = { _ in
            let list = CompletionList(items: [
                CompletionItem(label: "conformanceHello", kind: .function, insertText: "conformanceHello()"),
            ])
            return try JSONEncoder().encode(list)
        }
        hoverHandler = { _ in
            let hover = Hover(sections: [HoverSection(content: .markdown("**conformance** hover"))])
            return try JSONEncoder().encode(hover)
        }
        definitionHandler = { _ in
            let uri = DocumentURI(rawValue: "inmemory:conformance")
            let range = TextRange(location: 0, length: 1)
            let links = [LocationLink(targetURI: uri, targetRange: range, targetSelectionRange: range)]
            return try JSONEncoder().encode(links)
        }
    }
}
