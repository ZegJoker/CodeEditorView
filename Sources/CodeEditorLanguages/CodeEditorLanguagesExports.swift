/// Re-export language contracts and Tree-sitter lifecycle for umbrella clients.
@_exported import CodeEditorLanguageSupport
@_exported import CodeEditorTreeSitter

/// Ensures the first Tree-sitter highlight load can auto-bootstrap when this
/// product is linked. Safe to ignore; side effect is the only purpose.
public let codeEditorLanguagesModule: Void = {
    CodeEditorLanguages.installOnDemandBootstrapHook()
    return ()
}()
