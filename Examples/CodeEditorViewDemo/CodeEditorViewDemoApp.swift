import SwiftUI
import CodeEditorView
import CodeEditorLanguages

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// Register all Tree-sitter grammars once for the demo process.
private let _codeEditorLanguagesBootstrap: Bool = CodeEditorLanguages.bootstrap()

#if os(macOS)
/// SPM executables are not .app bundles; without an activation policy they never become
/// the key app and keystrokes keep going to Terminal / the previous frontmost app.
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Bring any already-created windows forward.
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

@main
struct CodeEditorViewDemoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(DemoAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            DemoRootView()
                #if os(macOS)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
                #endif
        }
    }
}

@MainActor
final class DemoCoordinator: EditorCoordinator {
    var lastCursorLine: Int?
    /// Inject sample line annotations when enabled (Phase 12).
    var showAnnotations: Bool = false {
        didSet { applyAnnotations() }
    }
    private weak var controller: EditorController?

    func prepare(controller: EditorController) {
        self.controller = controller
        applyAnnotations()
    }

    func selectionDidChange(controller: EditorController, cursors: [CursorPosition]) {
        lastCursorLine = cursors.first?.line
    }

    private func applyAnnotations() {
        guard let controller else { return }
        guard showAnnotations else {
            controller.clearAnnotations()
            return
        }
        // Sample diagnostics — line indices match token ranges (0-based).
        //   0: // Swift…
        //   1: func greet…
        //   2:     print…
        //   3:     if name.isEmpty {
        let text = controller.text as NSString
        let printRange = text.range(of: "print")
        let emptyRange = text.range(of: "isEmpty")
        func lineOf(_ range: NSRange) -> Int {
            guard range.location != NSNotFound,
                  let line = controller.layout.lineIndex.line(atUTF16Offset: range.location)
            else { return 0 }
            return line.index
        }
        func columnOf(_ range: NSRange) -> Int {
            guard range.location != NSNotFound,
                  let line = controller.layout.lineIndex.line(atUTF16Offset: range.location)
            else { return 0 }
            return max(0, range.location - line.utf16Offset)
        }

        var items: [LineAnnotation] = []
        if printRange.location != NSNotFound {
            items.append(
                LineAnnotation(
                    line: lineOf(printRange),
                    column: columnOf(printRange),
                    severity: .warning,
                    message: "This is a warning!",
                    detail: "Function body should not be empty (demo sample).",
                    range: NSRange(location: printRange.location, length: printRange.length)
                )
            )
        }
        if emptyRange.location != NSNotFound {
            items.append(
                LineAnnotation(
                    line: lineOf(emptyRange),
                    column: columnOf(emptyRange),
                    severity: .error,
                    message: "Unknown identifier 'isEmpty'",
                    detail: "Value of type 'String' has no member 'isEmpty' (demo).",
                    range: NSRange(location: emptyRange.location, length: emptyRange.length)
                )
            )
            // Second message on the same line (info) — no underline (no range).
            items.append(
                LineAnnotation(
                    line: lineOf(emptyRange),
                    column: 0,
                    severity: .info,
                    message: "Consider early return for clarity",
                    detail: "Demo informational note stacked with the error card."
                )
            )
        }
        controller.setAnnotations(items)
    }
}

/// Demo jump-to-definition provider (CESE-style mock).
@MainActor
final class DemoJumpToDefinitionDelegate: JumpToDefinitionDelegate {
    func queryLinks(forRange range: NSRange, textView: EditorController) async -> [JumpToDefinitionLink]? {
        let snip = (textView.text as NSString).substring(with: range)
        return [
            JumpToDefinitionLink(
                url: nil,
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "Start of document",
                documentation: "Demo local jump for “\(snip)” — moves to the top of the buffer.",
                sourcePreview: textView.text.split(separator: "\n").first.map(String.init),
                systemImage: "arrow.up.to.line",
                imageColorToken: .blue
            ),
            JumpToDefinitionLink(
                url: URL(string: "https://github.com/ZegJoker/CodeEditorView"),
                targetRange: CursorPosition(range: NSRange(location: 0, length: 0), line: 0, column: 0),
                label: "CodeEditorView repo",
                documentation: "Demo remote link — opens the project homepage.",
                sourcePreview: "https://github.com/ZegJoker/CodeEditorView",
                systemImage: "link",
                imageColorToken: .purple
            ),
        ]
    }

    func openLink(link: JumpToDefinitionLink) {
        #if os(macOS)
        if let url = link.url {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = link.url {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

/// Demo completion provider (CESE-style mock).
@MainActor
final class DemoCompletionDelegate: CodeSuggestionDelegate {
    private let catalog: [SimpleCodeSuggestion] = [
        SimpleCodeSuggestion(label: "greet", detail: "func", systemImage: "function", imageColorToken: .purple),
        SimpleCodeSuggestion(label: "print", detail: "func", systemImage: "function", imageColorToken: .purple),
        SimpleCodeSuggestion(label: "return", detail: "keyword", systemImage: "k.square", imageColorToken: .pink),
        SimpleCodeSuggestion(label: "String", detail: "struct", systemImage: "s.square", imageColorToken: .blue),
        SimpleCodeSuggestion(label: "isEmpty", detail: "var", systemImage: "v.square", imageColorToken: .blue),
        SimpleCodeSuggestion(label: "name", detail: "param", systemImage: "p.square", imageColorToken: .green),
        SimpleCodeSuggestion(label: "world", detail: "literal", systemImage: "textformat", imageColorToken: .orange),
    ]

    func completionTriggerCharacters() -> Set<String> { ["."] }

    func completionSuggestionsRequested(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [any CodeSuggestionEntry])? {
        try? await Task.sleep(for: .milliseconds(80))
        let prefix = Self.wordPrefix(at: cursorPosition.range.location, in: textView.text)
        let items = catalog.filter { prefix.isEmpty || $0.label.lowercased().hasPrefix(prefix.lowercased()) }
        return (cursorPosition, items)
    }

    func completionOnCursorMove(
        textView: EditorController,
        cursorPosition: CursorPosition
    ) -> [any CodeSuggestionEntry]? {
        // Empty prefix (e.g. user deleted the typed character) → dismiss.
        // Note: `String.hasPrefix("")` is true for every string, so we must not filter on "".
        let prefix = Self.wordPrefix(at: cursorPosition.range.location, in: textView.text)
        guard !prefix.isEmpty else { return nil }
        let items = catalog.filter { $0.label.lowercased().hasPrefix(prefix.lowercased()) }
        return items.isEmpty ? nil : items
    }

    func completionWindowApplyCompletion(
        item: any CodeSuggestionEntry,
        textView: EditorController,
        cursorPosition: CursorPosition?
    ) {
        let loc = cursorPosition?.range.location ?? textView.selectedRange.location
        let prefix = Self.wordPrefix(at: loc, in: textView.text)
        let start = loc - prefix.utf16.count
        textView.replaceCharacters(
            in: NSRange(location: max(0, start), length: prefix.utf16.count),
            with: item.label
        )
    }

    private static func wordPrefix(at location: Int, in text: String) -> String {
        let ns = text as NSString
        var i = min(max(0, location), ns.length)
        var chars: [Character] = []
        while i > 0 {
            let ch = ns.substring(with: NSRange(location: i - 1, length: 1))
            guard let c = ch.first, c.isLetter || c.isNumber || c == "_" else { break }
            chars.insert(c, at: 0)
            i -= 1
        }
        return String(chars)
    }
}

// MARK: - Catalog

/// Full language catalog for the picker (highlightable + plain text), sorted by display name.
private enum DemoCatalog {
    static var languages: [CodeLanguage] {
        let highlightable = CodeLanguages.highlightable
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return highlightable + [.plainText]
    }

    static func language(id: TreeSitterLanguageID) -> CodeLanguage {
        CodeLanguages.language(id: id) ?? .plainText
    }
}

// MARK: - Sample sources

private enum DemoSamples {
    static func source(for language: CodeLanguage) -> String {
        switch language.id {
        case .swift:
            return """
            // Swift — CodeEditorView demo
            func greet(_ name: String) {
                print("Hello, \\(name)!")
                if name.isEmpty {
                    return
                }
            }

            greet("world")
            """
        case .json:
            return """
            {
              "name": "CodeEditorView",
              "version": 1,
              "features": ["gutter", "highlight", "tree-sitter"],
              "enabled": true
            }
            """
        case .python:
            return """
            # Python — CodeEditorView demo
            def greet(name: str) -> None:
                print(f"Hello, {name}!")
                if not name:
                    return

            greet("world")
            """
        case .dart:
            return """
            // Dart — CodeEditorView demo
            void greet(String name) {
              print('Hello, $name!');
              if (name.isEmpty) {
                return;
              }
            }

            void main() {
              greet('world');
            }
            """
        case .javascript, .jsx:
            return """
            // JavaScript — CodeEditorView demo
            function greet(name) {
              console.log(`Hello, ${name}!`);
              if (!name) {
                return;
              }
            }

            greet("world");
            """
        case .typescript, .tsx:
            return """
            // TypeScript — CodeEditorView demo
            function greet(name: string): void {
              console.log(`Hello, ${name}!`);
              if (!name) {
                return;
              }
            }

            // Long line to exercise wrap (toggle Wrap and resize the window)
            const message: string = "This is a deliberately long TypeScript string so soft-wrap can be verified when Wrap is enabled.";

            greet("world");
            """
        case .rust:
            return """
            // Rust — CodeEditorView demo
            fn greet(name: &str) {
                println!("Hello, {}!", name);
                if name.is_empty() {
                    return;
                }
            }

            fn main() {
                greet("world");
            }
            """
        case .go:
            return """
            // Go — CodeEditorView demo
            package main

            import "fmt"

            func greet(name string) {
            	fmt.Printf("Hello, %s!\\n", name)
            	if name == "" {
            		return
            	}
            }

            func main() {
            	greet("world")
            }
            """
        case .ruby:
            return """
            # Ruby — CodeEditorView demo
            def greet(name)
              puts "Hello, #{name}!"
              return if name.empty?
            end

            greet("world")
            """
        case .java:
            return """
            // Java — CodeEditorView demo
            public class Main {
                static void greet(String name) {
                    System.out.println("Hello, " + name + "!");
                    if (name.isEmpty()) {
                        return;
                    }
                }

                public static void main(String[] args) {
                    greet("world");
                }
            }
            """
        case .c:
            return """
            // C — CodeEditorView demo
            #include <stdio.h>

            void greet(const char *name) {
                printf("Hello, %s!\\n", name);
            }

            int main(void) {
                greet("world");
                return 0;
            }
            """
        case .cpp:
            return """
            // C++ — CodeEditorView demo
            #include <iostream>
            #include <string>

            void greet(const std::string& name) {
                std::cout << "Hello, " << name << "!" << std::endl;
                if (name.empty()) {
                    return;
                }
            }

            int main() {
                greet("world");
                return 0;
            }
            """
        case .cSharp:
            return """
            // C# — CodeEditorView demo
            using System;

            class Program {
                static void Greet(string name) {
                    Console.WriteLine($"Hello, {name}!");
                    if (string.IsNullOrEmpty(name)) {
                        return;
                    }
                }

                static void Main() {
                    Greet("world");
                }
            }
            """
        case .bash:
            return """
            #!/usr/bin/env bash
            # Bash — CodeEditorView demo
            greet() {
              local name="$1"
              echo "Hello, ${name}!"
              if [[ -z "${name}" ]]; then
                return 1
              fi
            }

            greet "world"
            """
        case .html:
            return """
            <!DOCTYPE html>
            <html lang="en">
              <head>
                <meta charset="utf-8" />
                <title>CodeEditorView</title>
              </head>
              <body>
                <h1>Hello, world!</h1>
                <!-- HTML demo -->
              </body>
            </html>
            """
        case .css:
            return """
            /* CSS — CodeEditorView demo */
            :root {
              --accent: #3b82f6;
            }

            body {
              font-family: system-ui, sans-serif;
              color: #0f172a;
              background: #f8fafc;
            }

            .title {
              color: var(--accent);
              font-weight: 600;
            }
            """
        case .markdown:
            return """
            # CodeEditorView

            Markdown demo with **bold**, *italic*, and a list:

            - Gutter
            - Syntax highlighting
            - Tree-sitter

            ```swift
            print("hello")
            ```
            """
        case .yaml:
            return """
            # YAML — CodeEditorView demo
            name: CodeEditorView
            version: 1
            features:
              - gutter
              - highlight
              - tree-sitter
            enabled: true
            """
        case .toml:
            return """
            # TOML — CodeEditorView demo
            name = "CodeEditorView"
            version = 1

            [features]
            gutter = true
            highlight = true
            tree_sitter = true
            """
        case .sql:
            return """
            -- SQL — CodeEditorView demo
            SELECT id, name, enabled
            FROM projects
            WHERE name = 'CodeEditorView'
              AND enabled = TRUE
            ORDER BY id;
            """
        case .plainText:
            return "Plain text — no tree-sitter highlighting.\nToggle Regex for a simple keyword highlighter.\n"
        default:
            let comment = language.lineComment.isEmpty ? "//" : language.lineComment
            return """
            \(comment) \(language.displayName) — CodeEditorView demo
            \(comment) Extensions: \(language.extensions.sorted().joined(separator: ", "))
            \(comment) Tree-sitter id: \(language.id.rawValue)

            \(comment) Edit this buffer to try syntax highlighting for \(language.displayName).
            """
        }
    }
}

// MARK: - Root view

struct DemoRootView: View {
    @State private var languageID: TreeSitterLanguageID = .swift
    @State private var text = DemoSamples.source(for: .swift)
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var editorState = EditorState()
    @State private var wrapLines = true
    @State private var showInvisibles = false
    @State private var showGutter = true
    @State private var showGuide = true
    @State private var showMinimap = false
    @State private var showFolding = false
    @State private var showAnnotations = false
    @State private var useRegexFallback = false
    @State private var coordinator = DemoCoordinator()
    @State private var completionDelegate = DemoCompletionDelegate()
    @State private var jumpToDefinitionDelegate = DemoJumpToDefinitionDelegate()
    @State private var regexProvider = RegexHighlightProvider.swiftLike()
    @State private var languageFilter = ""

    private var selectedLanguage: CodeLanguage {
        DemoCatalog.language(id: languageID)
    }

    private var filteredLanguages: [CodeLanguage] {
        let all = DemoCatalog.languages
        let query = languageFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.rawValue.localizedCaseInsensitiveContains(query)
                || $0.extensions.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            CodeEditor(
                text: $text,
                selection: $selection,
                editorState: $editorState,
                configuration: EditorConfiguration(
                    appearance: .init(
                        theme: .default,
                        wrapLines: wrapLines,
                        bracketPairEmphasis: .flash
                    ),
                    behavior: .init(
                        isEditable: true,
                        isSelectable: true,
                        indentOption: .spaces(count: 4),
                        reformatAtColumn: 40
                    ),
                    peripherals: .init(
                        showGutter: showGutter,
                        showMinimap: showMinimap,
                        showReformattingGuide: showGuide,
                        showFoldingRibbon: showFolding,
                        showInvisibleCharacters: showInvisibles
                    )
                ),
                language: selectedLanguage.id == .plainText ? nil : selectedLanguage,
                highlightProviders: useRegexFallback ? [regexProvider] : [],
                coordinators: [coordinator],
                completionDelegate: completionDelegate,
                jumpToDefinitionDelegate: jumpToDefinitionDelegate
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()

            statusBar
        }
        .onChange(of: languageID) { _, newValue in
            let language = DemoCatalog.language(id: newValue)
            text = DemoSamples.source(for: language)
            selection = NSRange(location: 0, length: 0)
            // Re-apply sample annotations after language/text swap.
            coordinator.showAnnotations = showAnnotations
        }
        .onChange(of: showAnnotations) { _, enabled in
            coordinator.showAnnotations = enabled
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                languagePicker
                    .frame(minWidth: 180, maxWidth: 260)

                TextField("Filter languages…", text: $languageFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Toggle("Wrap", isOn: $wrapLines)
                Toggle("Gutter", isOn: $showGutter)
                Toggle("Minimap", isOn: $showMinimap)
                Toggle("Folding", isOn: $showFolding)
                Toggle("Annotations", isOn: $showAnnotations)
                Toggle("Column 40", isOn: $showGuide)
                Toggle("Invisibles", isOn: $showInvisibles)
                Toggle("Regex", isOn: $useRegexFallback)

                Button("Find") {
                    var state = editorState
                    state.findPanelVisible = !(state.findPanelVisible ?? false)
                    editorState = state
                }
                .help("Find (⌘F)")

                Spacer()

                Text("Esc/⌃Space complete · ⌘F find · ⌘R replace · \(DemoCatalog.languages.count) langs · \(text.split(separator: "\n").count) lines")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .padding(8)
    }

    private var languagePicker: some View {
        Picker("Language", selection: $languageID) {
            ForEach(filteredLanguages, id: \.id) { language in
                Text(language.displayName)
                    .tag(language.id)
            }
        }
        #if os(macOS)
        .pickerStyle(.menu)
        #else
        .pickerStyle(.menu)
        #endif
    }

    private var statusBar: some View {
        HStack {
            if let cursor = editorState.cursorPositions?.first {
                Text("Ln \(cursor.line + 1), Col \(cursor.column + 1)")
            } else {
                Text("Ln —, Col —")
            }
            Spacer()
            Text(selectedLanguage.displayName)
                .foregroundStyle(.secondary)
            if selectedLanguage.id != .plainText {
                Text("· \(selectedLanguage.id.rawValue)")
                    .foregroundStyle(.tertiary)
            }
            if let line = coordinator.lastCursorLine {
                Text("· coord line \(line + 1)")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospaced())
        .padding(6)
        .background(.bar)
    }
}
