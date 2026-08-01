import CodeEditorDocuments
import CodeEditorLanguageServices
import Foundation

// MARK: - Optional language services install

extension EditorController {
    /// Strong retain for weak completion / jump delegates installed via language services.
    final class LanguageServicesRetainBox {
        var completionAdapter: CompletionProviderDelegateAdapter?
        var definitionAdapter: DefinitionProviderJumpAdapter?
        var host: LanguageServiceHost?
    }

    /// Installs language-service adapters as completion and jump-to-definition delegates.
    ///
    /// Existing delegates are replaced. The host is retained by the controller for the lifetime
    /// of the install (or until ``clearLanguageServices()``).
    public func installLanguageServices(
        _ host: LanguageServiceHost,
        context: LanguageServiceContext? = nil
    ) {
        var ctx = context ?? LanguageServiceContext()
        if ctx.languageID == nil { ctx.languageID = languageID }
        if ctx.uri == nil { ctx.uri = textDocument.uri }

        let completion = CompletionProviderDelegateAdapter(host: host, context: ctx)
        let definition = DefinitionProviderJumpAdapter(host: host, context: ctx)

        let box = LanguageServicesRetainBox()
        box.host = host
        box.completionAdapter = completion
        box.definitionAdapter = definition
        languageServicesRetain = box

        completionDelegate = completion
        jumpToDefinitionDelegate = definition
    }

    /// Clears adapters installed by ``installLanguageServices(_:context:)``.
    public func clearLanguageServices() {
        let box = languageServicesRetain as? LanguageServicesRetainBox
        if let box, completionDelegate === box.completionAdapter {
            completionDelegate = nil
        }
        if let box, jumpToDefinitionDelegate === box.definitionAdapter {
            jumpToDefinitionDelegate = nil
        }
        languageServicesRetain = nil
    }

    /// Maps diagnostics into line annotations (host still owns when to fetch).
    public func applyLanguageDiagnostics(
        _ diagnostics: [LanguageDiagnostic]
    ) {
        let annotations = DiagnosticsAnnotationMapper.annotations(
            from: diagnostics,
            documentText: text
        )
        setAnnotations(annotations)
    }
}
