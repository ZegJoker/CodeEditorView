import CodeEditorLanguages
import Foundation
import Testing

@testable import CodeEditorView

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit

    @Suite("Blank line enter crash")
    @MainActor
    struct BlankLineEnterCrashTests {
        init() { CodeEditorLanguages.bootstrap() }

        @Test func exactDemoReproEnterOnBlankLine() async {
            _ = NSApplication.shared

            let source = """
                // Swift — CodeEditorView demo
                func greet(_ name: String) {
                    print("Hello, \\(name)!")
                    if name.isEmpty {
                        return
                    }
                }

                greet("world")
                """

            let controller = EditorController(
                text: source,
                configuration: EditorConfiguration(
                    appearance: .init(theme: .default, wrapLines: true, bracketPairEmphasis: .flash),
                    behavior: .init(
                        isEditable: true, isSelectable: true, indentOption: .spaces(count: 4), reformatAtColumn: 40),
                    peripherals: .init(
                        showGutter: true,
                        showMinimap: true,
                        showReformattingGuide: true,
                        showFoldingRibbon: true,
                        showInvisibleCharacters: false
                    )
                ),
                language: .swift
            )
            controller.installFoldingIfNeeded()
            controller.rebuildFolds()

            let ns = controller.text as NSString
            let printRange = ns.range(of: "print")
            let emptyRange = ns.range(of: "isEmpty")
            func lineOf(_ range: NSRange) -> Int {
                controller.layout.lineIndex.line(atUTF16Offset: range.location)?.index ?? 0
            }
            func colOf(_ range: NSRange) -> Int {
                guard let line = controller.layout.lineIndex.line(atUTF16Offset: range.location) else { return 0 }
                return max(0, range.location - line.utf16Offset)
            }
            var items: [LineAnnotation] = []
            if printRange.location != NSNotFound {
                items.append(
                    LineAnnotation(
                        line: lineOf(printRange), column: colOf(printRange),
                        severity: .warning, message: "This is a warning!",
                        detail: "d",
                        range: NSRange(location: printRange.location, length: printRange.length)
                    ))
            }
            if emptyRange.location != NSNotFound {
                items.append(
                    LineAnnotation(
                        line: lineOf(emptyRange), column: colOf(emptyRange),
                        severity: .error, message: "err", detail: "d",
                        range: NSRange(location: emptyRange.location, length: emptyRange.length)
                    ))
                items.append(
                    LineAnnotation(
                        line: lineOf(emptyRange), severity: .info, message: "info"
                    ))
            }
            controller.setAnnotations(items)

            let blankRange = ns.range(of: "\n\ngreet")
            #expect(blankRange.location != NSNotFound)
            let caret = blankRange.location + 1
            controller.setSelectedRange(NSRange(location: caret, length: 0))

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

            chrome.syncMinimap()
            chrome.layoutSubtreeIfNeeded()
            editor.relayout()
            editor.display()
            chrome.display()

            // Enter
            editor.insertNewline(nil)

            // Wait for async fold rebuild (24ms) + highlighter
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(20))
                editor.relayout()
                editor.display()
                chrome.syncMinimap()
                chrome.display()
                chrome.layoutSubtreeIfNeeded()
            }

            // More enters and typing
            editor.insertNewline(nil)
            editor.display()
            controller.insertText("x")
            editor.relayout()
            editor.display()
            chrome.syncMinimap()
            chrome.display()

            try? await Task.sleep(for: .milliseconds(100))
            editor.display()
            chrome.display()

            #expect(controller.document.length > source.utf16.count)
            window.orderOut(nil)
        }
    }
#endif
