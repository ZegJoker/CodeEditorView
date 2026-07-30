import SwiftUI
import CodeEditorLanguageSupport
import CodeEditorDocuments

/// SwiftUI editor driven by a shared ``TextDocument`` and ``EditorSession``.
///
/// Multiple views may share one document with independent sessions (selection, scroll, find).
public struct SharedCodeEditor: View {
    private var document: TextDocument
    private var session: EditorSession
    private var configuration: EditorConfiguration
    private var language: CodeLanguage?
    private var highlightProviders: [any HighlightProviding]
    private var coordinators: [any EditorCoordinator]
    private var completionDelegate: (any CodeSuggestionDelegate)?
    private var jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)?

    public init(
        document: TextDocument,
        session: EditorSession,
        configuration: EditorConfiguration = EditorConfiguration(),
        language: CodeLanguage? = nil,
        languageID: String? = nil,
        highlightProviders: [any HighlightProviding] = [],
        coordinators: [any EditorCoordinator] = [],
        completionDelegate: (any CodeSuggestionDelegate)? = nil,
        jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)? = nil
    ) {
        self.document = document
        self.session = session
        self.configuration = configuration
        self.language = language ?? languageID.flatMap { CodeLanguages.language(id: $0) }
        self.highlightProviders = highlightProviders
        self.coordinators = coordinators
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionDelegate = jumpToDefinitionDelegate
    }

    public var body: some View {
        SharedEditorRepresentable(
            document: document,
            session: session,
            configuration: configuration,
            language: language,
            highlightProviders: highlightProviders,
            coordinators: coordinators,
            completionDelegate: completionDelegate,
            jumpToDefinitionDelegate: jumpToDefinitionDelegate
        )
    }
}

public extension CodeEditor {
    /// Shared-document entry point (same parameters as ``SharedCodeEditor``).
    static func shared(
        document: TextDocument,
        session: EditorSession,
        configuration: EditorConfiguration = EditorConfiguration(),
        language: CodeLanguage? = nil,
        languageID: String? = nil,
        highlightProviders: [any HighlightProviding] = [],
        coordinators: [any EditorCoordinator] = [],
        completionDelegate: (any CodeSuggestionDelegate)? = nil,
        jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)? = nil
    ) -> SharedCodeEditor {
        SharedCodeEditor(
            document: document,
            session: session,
            configuration: configuration,
            language: language,
            languageID: languageID,
            highlightProviders: highlightProviders,
            coordinators: coordinators,
            completionDelegate: completionDelegate,
            jumpToDefinitionDelegate: jumpToDefinitionDelegate
        )
    }
}

// MARK: - Representable

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

struct SharedEditorRepresentable: NSViewRepresentable {
    var document: TextDocument
    var session: EditorSession
    var configuration: EditorConfiguration
    var language: CodeLanguage?
    var highlightProviders: [any HighlightProviding]
    var coordinators: [any EditorCoordinator]
    var completionDelegate: (any CodeSuggestionDelegate)?
    var jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EditorChromeView {
        let controller = EditorController(
            document: document,
            session: session,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language
        )
        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionDelegate = jumpToDefinitionDelegate
        context.coordinator.controller = controller

        let editor = AppKitEditorView(controller: controller)
        editor.onSelectionChange = { [weak controller, session] range in
            controller?.setSelectedRange(range)
            session.setSelectedNSRanges(controller?.selectedRanges ?? [range])
        }
        controller.onSelectionDidChange = { [session] range in
            session.setSelectedNSRanges([range])
        }
        let chrome = EditorChromeView(
            controller: controller,
            editorView: editor,
            wrapLines: configuration.wrapLines
        )
        context.coordinator.chromeView = chrome
        return chrome
    }

    func updateNSView(_ chrome: EditorChromeView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        if controller.configuration != configuration {
            controller.configuration = configuration
        }
        if controller.language != language {
            controller.language = language
        }
        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionDelegate = jumpToDefinitionDelegate
        if !highlightProviders.isEmpty {
            controller.setHighlightProviders(highlightProviders)
        }
    }

    final class Coordinator {
        var controller: EditorController?
        var chromeView: EditorChromeView?
    }
}

#elseif canImport(UIKit)
import UIKit

struct SharedEditorRepresentable: UIViewRepresentable {
    var document: TextDocument
    var session: EditorSession
    var configuration: EditorConfiguration
    var language: CodeLanguage?
    var highlightProviders: [any HighlightProviding]
    var coordinators: [any EditorCoordinator]
    var completionDelegate: (any CodeSuggestionDelegate)?
    var jumpToDefinitionDelegate: (any JumpToDefinitionDelegate)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EditorChromeView {
        let controller = EditorController(
            document: document,
            session: session,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language
        )
        controller.completionDelegate = completionDelegate
        controller.jumpToDefinitionDelegate = jumpToDefinitionDelegate
        context.coordinator.controller = controller
        let editor = UIKitEditorView(controller: controller)
        let chrome = EditorChromeView(
            controller: controller,
            editorView: editor,
            wrapLines: configuration.wrapLines
        )
        return chrome
    }

    func updateUIView(_ uiView: EditorChromeView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        if controller.configuration != configuration {
            controller.configuration = configuration
        }
        if controller.language != language {
            controller.language = language
        }
    }

    final class Coordinator {
        var controller: EditorController?
    }
}
#endif
