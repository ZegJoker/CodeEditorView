import SwiftUI
import CodeEditorLanguages

/// SwiftUI entry point for the multiplatform code editor.
public struct CodeEditor: View {
    @Binding private var text: String
    @Binding private var selection: NSRange
    @Binding private var editorState: EditorState
    private var configuration: EditorConfiguration
    private var coordinators: [any EditorCoordinator]
    private var highlightProviders: [any HighlightProviding]
    private var language: CodeLanguage?

    public init(
        text: Binding<String>,
        selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        editorState: Binding<EditorState> = .constant(.empty),
        configuration: EditorConfiguration = EditorConfiguration(),
        language: CodeLanguage? = nil,
        languageID: String? = nil,
        highlightProviders: [any HighlightProviding] = [],
        coordinators: [any EditorCoordinator] = []
    ) {
        self._text = text
        self._selection = selection
        self._editorState = editorState
        self.configuration = configuration
        self.language = language ?? languageID.flatMap { CodeLanguages.language(id: $0) }
        self.highlightProviders = highlightProviders
        self.coordinators = coordinators
    }

    public var body: some View {
        EditorRepresentable(
            text: $text,
            selection: $selection,
            editorState: $editorState,
            configuration: configuration,
            language: language,
            highlightProviders: highlightProviders,
            coordinators: coordinators
        )
    }
}
