import SwiftUI
import CodeEditorLanguages

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

struct EditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var editorState: EditorState
    var configuration: EditorConfiguration
    var language: CodeLanguage?
    var highlightProviders: [any HighlightProviding]
    var coordinators: [any EditorCoordinator]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, editorState: $editorState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = EditorController(
            text: text,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language
        )
        context.coordinator.controller = controller

        let editor = AppKitEditorView(controller: controller)
        editor.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.text.wrappedValue = newText
            coordinator?.pushStateFromControllerIfNeeded()
        }
        editor.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.selection.wrappedValue = range
            coordinator?.pushStateFromControllerIfNeeded()
        }
        context.coordinator.editorView = editor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = !configuration.wrapLines
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView = editor
        editor.autoresizingMask = configuration.wrapLines ? [.width] : []
        if configuration.appearance.useThemeBackground {
            scroll.backgroundColor = configuration.theme.background
            scroll.drawsBackground = true
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        let wrapChanged = controller.configuration.wrapLines != configuration.wrapLines
        if controller.configuration != configuration {
            controller.configuration = configuration
        }

        // Apply language + text + providers off the representable update stack so a heavy
        // language teardown (e.g. Zig → Plain Text) cannot re-enter SwiftUI and freeze.
        let languageChanged = controller.language != language
        let textChanged = controller.text != text
        let providers = highlightProviders
        let lang = language
        let newText = text
        let newSelection = selection

        if languageChanged || textChanged || context.coordinator.needsProviderSync(providers) {
            context.coordinator.scheduleModelApply { [weak coordinator = context.coordinator] in
                guard let coordinator, let controller = coordinator.controller else { return }
                if controller.language != lang {
                    controller.language = lang
                }
                coordinator.syncHighlightProviders(providers, language: lang, on: controller)
                if controller.text != newText {
                    controller.text = newText
                }
                if controller.selectedRange != newSelection {
                    controller.setSelectedRange(newSelection)
                }
                coordinator.editorView?.relayout()
                coordinator.pushStateFromControllerIfNeeded()
            }
        } else {
            context.coordinator.updateCoordinatorsIfNeeded(coordinators, on: controller)
            if controller.selectedRange != selection {
                controller.setSelectedRange(selection)
            }
            context.coordinator.applyInboundEditorState(editorState)
            context.coordinator.editorView?.relayout()
            context.coordinator.pushStateFromControllerIfNeeded()
        }

        context.coordinator.updateCoordinatorsIfNeeded(coordinators, on: controller)
        context.coordinator.applyInboundEditorState(editorState)

        if configuration.appearance.useThemeBackground {
            scrollView.backgroundColor = configuration.theme.background
        }
        scrollView.hasHorizontalScroller = !configuration.wrapLines
        scrollView.horizontalScrollElasticity = configuration.wrapLines ? .none : .allowed
        if wrapChanged {
            context.coordinator.editorView?.autoresizingMask = configuration.wrapLines ? [.width] : []
            controller.layout.wrapLines = configuration.wrapLines
            controller.layout.invalidateAll()
            context.coordinator.editorView?.relayout()
        }
    }

    @MainActor
    final class Coordinator {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var editorState: Binding<EditorState>
        var controller: EditorController?
        var editorView: AppKitEditorView?
        private var coordinatorIDs: [ObjectIdentifier] = []
        fileprivate var providerIDs: [ObjectIdentifier] = []
        fileprivate var hadExplicitProviders = false
        /// Last cursor positions pushed to the SwiftUI binding (dedupe updates).
        private var lastPushedCursors: [CursorPosition]?
        /// Coalesces language/text applies so SwiftUI updateNSView cannot re-enter itself.
        private var pendingModelApply: DispatchWorkItem?
        private var isApplyingModel = false

        init(
            text: Binding<String>,
            selection: Binding<NSRange>,
            editorState: Binding<EditorState>
        ) {
            self.text = text
            self.selection = selection
            self.editorState = editorState
        }

        func updateCoordinatorsIfNeeded(_ coordinators: [any EditorCoordinator], on controller: EditorController) {
            let ids = coordinators.map { ObjectIdentifier($0) }
            guard ids != coordinatorIDs else { return }
            coordinatorIDs = ids
            controller.setCoordinators(coordinators)
        }

        func needsProviderSync(_ providers: [any HighlightProviding]) -> Bool {
            if !providers.isEmpty {
                let ids = providers.map { ObjectIdentifier($0) }
                return ids != providerIDs
            }
            return hadExplicitProviders || !providerIDs.isEmpty
        }

        /// Runs `body` on the next main-queue turn, coalescing multiple updateNSView calls.
        func scheduleModelApply(_ body: @escaping @MainActor () -> Void) {
            pendingModelApply?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingModelApply = nil
                guard !self.isApplyingModel else { return }
                self.isApplyingModel = true
                defer { self.isApplyingModel = false }
                body()
            }
            pendingModelApply = work
            DispatchQueue.main.async(execute: work)
        }

        /// Installs host providers, or restores tree-sitter when the host clears them (Regex off).
        func syncHighlightProviders(
            _ providers: [any HighlightProviding],
            language: CodeLanguage?,
            on controller: EditorController
        ) {
            if !providers.isEmpty {
                let ids = providers.map { ObjectIdentifier($0) }
                guard ids != providerIDs else { return }
                providerIDs = ids
                hadExplicitProviders = true
                controller.setHighlightProviders(providers)
                return
            }

            guard hadExplicitProviders || !providerIDs.isEmpty else { return }
            // Leaving explicit Regex (or other) providers — reinstall language tree-sitter.
            hadExplicitProviders = false
            providerIDs = []
            controller.restoreLanguageHighlighting()
        }

        func pushStateFromControllerIfNeeded() {
            guard let controller else { return }
            let cursors = controller.cursorPositions
            guard cursors != lastPushedCursors else { return }
            lastPushedCursors = cursors

            var state = editorState.wrappedValue
            if state.cursorPositions != cursors {
                state.cursorPositions = cursors
                editorState.wrappedValue = state
            }
            if controller.editorState.cursorPositions != cursors {
                controller.editorState.cursorPositions = cursors
            }
        }

        /// - Note: Prefer ``pushStateFromControllerIfNeeded`` from updateNSView.
        func pushStateFromController() {
            lastPushedCursors = nil
            pushStateFromControllerIfNeeded()
        }

        func applyInboundEditorState(_ state: EditorState) {
            guard let controller else { return }
            if let cursors = state.cursorPositions, !cursors.isEmpty {
                let ranges = cursors.map(\.range)
                if ranges != controller.selectedRanges {
                    controller.setSelectedRanges(ranges)
                    selection.wrappedValue = controller.selectedRange
                }
            }
            // Do not assign controller.editorState = state when state is only a host mirror;
            // that used to clobber and re-trigger binding updates every frame.
            if controller.editorState != state,
               state.cursorPositions != nil || state.scrollPosition != nil
                || state.findText != nil || state.replaceText != nil || state.findPanelVisible != nil {
                controller.editorState = state
            }
        }
    }
}

#elseif canImport(UIKit)
import UIKit

struct EditorRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var editorState: EditorState
    var configuration: EditorConfiguration
    var language: CodeLanguage?
    var highlightProviders: [any HighlightProviding]
    var coordinators: [any EditorCoordinator]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, editorState: $editorState)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let controller = EditorController(
            text: text,
            configuration: configuration,
            coordinators: coordinators,
            highlightProviders: highlightProviders,
            language: language
        )
        context.coordinator.controller = controller

        let editor = UIKitEditorView(controller: controller)
        editor.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.text.wrappedValue = newText
            coordinator?.pushStateFromControllerIfNeeded()
        }
        editor.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.selection.wrappedValue = range
            coordinator?.pushStateFromControllerIfNeeded()
        }
        context.coordinator.editorView = editor

        let scroll = UIScrollView()
        scroll.addSubview(editor)
        editor.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            editor.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        if configuration.appearance.useThemeBackground {
            scroll.backgroundColor = configuration.theme.background
        }
        return scroll
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let controller = context.coordinator.controller else { return }
        if controller.configuration != configuration {
            controller.configuration = configuration
        }
        if controller.language != language {
            controller.language = language
        }
        context.coordinator.updateCoordinatorsIfNeeded(coordinators, on: controller)
        context.coordinator.syncHighlightProviders(highlightProviders, language: language, on: controller)
        if controller.text != text {
            controller.text = text
        }
        if controller.selectedRange != selection {
            controller.setSelectedRange(selection)
        }
        context.coordinator.applyInboundEditorState(editorState)
        context.coordinator.editorView?.relayout()
        if let editor = context.coordinator.editorView {
            let wrap = configuration.wrapLines
            let width = wrap ? scrollView.bounds.width : max(scrollView.bounds.width, controller.contentSize.width)
            scrollView.contentSize = CGSize(
                width: width,
                height: max(controller.contentSize.height, scrollView.bounds.height)
            )
            editor.frame = CGRect(origin: .zero, size: scrollView.contentSize)
        }
        if configuration.appearance.useThemeBackground {
            scrollView.backgroundColor = configuration.theme.background
            context.coordinator.editorView?.backgroundColor = configuration.theme.background
        }
        context.coordinator.pushStateFromControllerIfNeeded()
    }

    @MainActor
    final class Coordinator {
        var text: Binding<String>
        var selection: Binding<NSRange>
        var editorState: Binding<EditorState>
        var controller: EditorController?
        var editorView: UIKitEditorView?
        private var coordinatorIDs: [ObjectIdentifier] = []
        fileprivate var providerIDs: [ObjectIdentifier] = []
        fileprivate var hadExplicitProviders = false
        private var lastPushedCursors: [CursorPosition]?

        init(
            text: Binding<String>,
            selection: Binding<NSRange>,
            editorState: Binding<EditorState>
        ) {
            self.text = text
            self.selection = selection
            self.editorState = editorState
        }

        func updateCoordinatorsIfNeeded(_ coordinators: [any EditorCoordinator], on controller: EditorController) {
            let ids = coordinators.map { ObjectIdentifier($0) }
            guard ids != coordinatorIDs else { return }
            coordinatorIDs = ids
            controller.setCoordinators(coordinators)
        }

        func syncHighlightProviders(
            _ providers: [any HighlightProviding],
            language: CodeLanguage?,
            on controller: EditorController
        ) {
            if !providers.isEmpty {
                let ids = providers.map { ObjectIdentifier($0) }
                guard ids != providerIDs else { return }
                providerIDs = ids
                hadExplicitProviders = true
                controller.setHighlightProviders(providers)
                return
            }
            guard hadExplicitProviders || !providerIDs.isEmpty else { return }
            hadExplicitProviders = false
            providerIDs = []
            controller.restoreLanguageHighlighting()
        }

        func pushStateFromControllerIfNeeded() {
            guard let controller else { return }
            let cursors = controller.cursorPositions
            guard cursors != lastPushedCursors else { return }
            lastPushedCursors = cursors
            var state = editorState.wrappedValue
            if state.cursorPositions != cursors {
                state.cursorPositions = cursors
                editorState.wrappedValue = state
            }
            if controller.editorState.cursorPositions != cursors {
                controller.editorState.cursorPositions = cursors
            }
        }

        func pushStateFromController() {
            lastPushedCursors = nil
            pushStateFromControllerIfNeeded()
        }

        func applyInboundEditorState(_ state: EditorState) {
            guard let controller else { return }
            if let cursors = state.cursorPositions, !cursors.isEmpty {
                let ranges = cursors.map(\.range)
                if ranges != controller.selectedRanges {
                    controller.setSelectedRanges(ranges)
                    selection.wrappedValue = controller.selectedRange
                }
            }
            if controller.editorState != state,
               state.cursorPositions != nil || state.scrollPosition != nil
                || state.findText != nil || state.replaceText != nil || state.findPanelVisible != nil {
                controller.editorState = state
            }
        }
    }
}
#endif
