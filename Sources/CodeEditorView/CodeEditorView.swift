// CodeEditorView
//
// A multiplatform code editor built with a platform-agnostic core,
// AppKit/UIKit hosts, and SwiftUI wrappers. Uses structured concurrency
// and Observation — no Combine.
//
// Architecture:
//   SwiftUI `CodeEditor` → platform host view → `EditorController` → core engines
//
// Inspired by the product goals of CodeEditTextView; implemented as an original rewrite.
//
// Language contracts and Tree-sitter lifecycle are re-exported so clients can write
// `CodeEditor(..., language: .swift)` with only `import CodeEditorView`. Hosts that need
// highlight configurations must also link a language pack or the `CodeEditorLanguages`
// umbrella (which bootstraps parsers into `LanguageRegistry`).

@_exported import CodeEditorLanguageSupport
@_exported import CodeEditorTreeSitter
