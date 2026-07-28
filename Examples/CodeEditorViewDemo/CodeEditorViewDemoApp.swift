import SwiftUI
import CodeEditorView
import CodeEditorLanguages

@main
struct CodeEditorViewDemoApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
        }
    }
}

@MainActor
final class DemoCoordinator: EditorCoordinator {
    var lastCursorLine: Int?

    func prepare(controller: EditorController) {}

    func selectionDidChange(controller: EditorController, cursors: [CursorPosition]) {
        lastCursorLine = cursors.first?.line
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
    @State private var useRegexFallback = false
    @State private var coordinator = DemoCoordinator()
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
                    behavior: .init(reformatAtColumn: 40),
                    peripherals: .init(
                        showGutter: showGutter,
                        showReformattingGuide: showGuide,
                        showInvisibleCharacters: showInvisibles
                    )
                ),
                language: selectedLanguage.id == .plainText ? nil : selectedLanguage,
                highlightProviders: useRegexFallback ? [regexProvider] : [],
                coordinators: [coordinator]
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .onChange(of: languageID) { _, newValue in
            let language = DemoCatalog.language(id: newValue)
            text = DemoSamples.source(for: language)
            selection = NSRange(location: 0, length: 0)
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
                Toggle("Column 40", isOn: $showGuide)
                Toggle("Invisibles", isOn: $showInvisibles)
                Toggle("Regex", isOn: $useRegexFallback)

                Spacer()

                Text("\(DemoCatalog.languages.count) languages · \(text.split(separator: "\n").count) lines")
                    .foregroundStyle(.secondary)
                    .font(.caption)
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
