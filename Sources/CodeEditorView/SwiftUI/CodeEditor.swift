import SwiftUI

/// SwiftUI entry point for the multiplatform code editor.
public struct CodeEditor: View {
    @Binding private var text: String
    @Binding private var selection: NSRange
    private var configuration: EditorConfiguration

    public init(
        text: Binding<String>,
        selection: Binding<NSRange> = .constant(NSRange(location: 0, length: 0)),
        configuration: EditorConfiguration = EditorConfiguration()
    ) {
        self._text = text
        self._selection = selection
        self.configuration = configuration
    }

    public var body: some View {
        EditorRepresentable(
            text: $text,
            selection: $selection,
            configuration: configuration
        )
    }
}
