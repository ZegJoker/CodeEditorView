import Foundation
import Testing
@testable import CodeEditorView
import CodeEditorLanguages

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit


@MainActor
private final class CrashReproCompletionDelegate: CodeSuggestionDelegate {
    private let items: [SimpleCodeSuggestion] = [
        SimpleCodeSuggestion(label: "print", detail: "func"),
        SimpleCodeSuggestion(label: "greet", detail: "func"),
        SimpleCodeSuggestion(label: "return", detail: "keyword"),
        SimpleCodeSuggestion(label: "String", detail: "struct"),
        SimpleCodeSuggestion(label: "isEmpty", detail: "var"),
        SimpleCodeSuggestion(label: "name", detail: "param"),
    ]
    func completionTriggerCharacters() -> Set<String> { ["."] }
    func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        (cursorPosition, items)
    }
    func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? { items }
    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    ) {
        textView.insertText(item.label)
    }
}

@Suite("Typing crash repro")
@MainActor
struct TypingCrashReproTests {
    init() { CodeEditorLanguages.bootstrap() }

    @Test func typeWithMinimapFoldAnnotationsAndCompletions() async {
        _ = NSApplication.shared

        let source = """
        // Swift — crash repro
        func greet(_ name: String) {
            print("Hello")
            if name.isEmpty {
                return
            }
        }

        greet("world")
        """
        let controller = EditorController(
            text: source,
            configuration: EditorConfiguration(
                wrapLines: true,
                showGutter: true,
                showMinimap: true,
                showFoldingRibbon: true
            ),
            language: .swift
        )
        controller.completionDelegate = CrashReproCompletionDelegate()
        controller.installFoldingIfNeeded()
        controller.rebuildFolds()

        // Collapse a fold if any
        if let fold = controller.foldStarting(atLine: 1) {
            controller.toggleFold(atLine: 1)
            _ = fold
        }

        let text = controller.text as NSString
        let printRange = text.range(of: "print")
        let emptyRange = text.range(of: "isEmpty")
        var anns: [LineAnnotation] = []
        if printRange.location != NSNotFound,
           let line = controller.layout.lineIndex.line(atUTF16Offset: printRange.location) {
            anns.append(LineAnnotation(
                line: line.index,
                column: max(0, printRange.location - line.utf16Offset),
                severity: .warning,
                message: "This is a warning!",
                detail: "detail",
                range: printRange
            ))
        }
        if emptyRange.location != NSNotFound,
           let line = controller.layout.lineIndex.line(atUTF16Offset: emptyRange.location) {
            anns.append(LineAnnotation(
                line: line.index,
                column: max(0, emptyRange.location - line.utf16Offset),
                severity: .error,
                message: "Unknown identifier",
                detail: "detail",
                range: emptyRange
            ))
            anns.append(LineAnnotation(
                line: line.index,
                severity: .info,
                message: "Consider early return"
            ))
        }
        controller.setAnnotations(anns)

        let editor = AppKitEditorView(controller: controller)
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let chrome = EditorChromeView(controller: controller, editorView: editor, wrapLines: true)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        chrome.syncMinimap()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)

        chrome.layoutSubtreeIfNeeded()
        editor.relayout()
        editor.display()
        chrome.display()

        // Heavy typing under all three features
        let keys = Array("xyz.") + Array("print") + Array("\nabc\n  def\n") + Array("hello_world_test")
        for ch in keys {
            if ch == "\n" {
                controller.insertNewline()
            } else {
                controller.insertText(String(ch))
            }
            editor.relayout()
            editor.displayIfNeeded()
            chrome.layoutSubtreeIfNeeded()
            chrome.displayIfNeeded()
            chrome.syncMinimap()
            try? await Task.sleep(for: .milliseconds(10))
            editor.displayIfNeeded()
        }

        // Toggle fold while dirty
        if let _ = controller.foldStarting(atLine: 1) {
            controller.toggleFold(atLine: 1)
            editor.relayout()
            editor.display()
        }

        // Refresh annotations after edits
        controller.setAnnotations(anns)
        editor.relayout()
        editor.display()
        chrome.syncMinimap()
        chrome.display()

        #expect(controller.document.length > 0)
        window.orderOut(nil)
    }
}
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@Suite("Toggle features crash repro")
@MainActor
struct ToggleFeaturesCrashReproTests {
    @Test func enableMinimapFoldAnnotationsThenType() async {
        _ = NSApplication.shared
        let source = DemoLikeSource.swift
        var config = EditorConfiguration(
            wrapLines: true,
            showGutter: true,
            showMinimap: false,
            showFoldingRibbon: false
        )
        let controller = EditorController(text: source, configuration: config, language: .swift)
        controller.completionDelegate = CrashReproCompletionDelegate()

        let editor = AppKitEditorView(controller: controller)
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let chrome = EditorChromeView(controller: controller, editorView: editor, wrapLines: true)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        chrome.layoutSubtreeIfNeeded()
        editor.relayout()
        editor.display()

        // Simulate demo toggles: enable minimap, folding, annotations
        config.peripherals.showMinimap = true
        controller.configuration = config
        chrome.syncMinimap()
        chrome.layoutSubtreeIfNeeded()
        chrome.display()

        config.peripherals.showFoldingRibbon = true
        controller.configuration = config
        controller.installFoldingIfNeeded()
        controller.rebuildFolds()
        editor.relayout()
        editor.display()

        // annotations
        let text = controller.text as NSString
        let printRange = text.range(of: "print")
        if printRange.location != NSNotFound,
           let line = controller.layout.lineIndex.line(atUTF16Offset: printRange.location) {
            controller.setAnnotations([
                LineAnnotation(
                    line: line.index,
                    column: max(0, printRange.location - line.utf16Offset),
                    severity: .warning,
                    message: "warn",
                    detail: "d",
                    range: printRange
                )
            ])
        }
        editor.relayout()
        editor.display()
        chrome.syncMinimap()
        chrome.display()

        // Type
        for ch in Array("ab.cde\nfg") {
            if ch == "\n" { controller.insertNewline() }
            else { controller.insertText(String(ch)) }
            editor.relayout()
            editor.displayIfNeeded()
            chrome.syncMinimap()
            chrome.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(controller.text.contains("ab"))
        window.orderOut(nil)
    }
}

private enum DemoLikeSource {
    static let swift = """
    // Swift — CodeEditorView demo
    func greet(_ name: String) {
        print("Hello, \\(name)!")
        if name.isEmpty {
            return
        }
    }

    greet("world")
    """
}
#endif
