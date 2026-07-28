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

// Core types are available through the module automatically.
// This file documents the public surface and ensures the target has a root source file.
