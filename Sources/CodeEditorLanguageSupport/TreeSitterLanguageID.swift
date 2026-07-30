import Foundation

/// Identifiers for tree-sitter languages (aligned with CodeEditLanguages coverage).
///
/// This closed catalog remains for call-site compatibility (`CodeLanguage.id`,
/// `.swift`, etc.). Prefer open ``LanguageID`` for custom languages and new APIs.
public enum TreeSitterLanguageID: String, Sendable, Hashable, CaseIterable {
    case agda
    case bash
    case c
    case cpp
    case cSharp
    case css
    case dart
    case dockerfile
    case elixir
    case go
    case goMod
    case haskell
    case html
    case java
    case javascript
    case jsdoc
    case json
    case jsx
    case julia
    case kotlin
    case lua
    case markdown
    case markdownInline
    case objc
    case ocaml
    case perl
    case php
    case python
    case regex
    case ruby
    case rust
    case scala
    case sql
    case swift
    case toml
    case tsx
    case typescript
    case verilog
    case yaml
    case zig
    case plainText
}

extension TreeSitterLanguageID {
    /// Open identifier matching this catalog case.
    public var languageID: LanguageID {
        LanguageID(rawValue: rawValue)
    }

    /// Best-effort conversion from an open ``LanguageID``.
    public init?(languageID: LanguageID) {
        self.init(rawValue: languageID.rawValue)
    }
}
