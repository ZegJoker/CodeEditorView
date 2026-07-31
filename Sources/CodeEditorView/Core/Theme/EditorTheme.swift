import CoreGraphics
import Foundation
import CodeEditorLanguageSupport

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Colors and text attributes for editor chrome and syntax highlighting.
public struct EditorTheme: Equatable {
    /// Style applied to a syntax capture or plain text.
    public struct Attribute: Equatable {
        public var color: PlatformColor
        public var bold: Bool
        public var italic: Bool

        public init(color: PlatformColor, bold: Bool = false, italic: Bool = false) {
            self.color = color
            self.bold = bold
            self.italic = italic
        }
    }

    public var text: Attribute
    public var insertionPoint: PlatformColor
    public var invisibles: Attribute
    public var background: PlatformColor
    public var lineHighlight: PlatformColor
    public var selection: PlatformColor
    public var keywords: Attribute
    public var commands: Attribute
    public var types: Attribute
    public var attributes: Attribute
    public var variables: Attribute
    public var values: Attribute
    public var numbers: Attribute
    public var strings: Attribute
    public var characters: Attribute
    public var comments: Attribute
    public var operators: Attribute
    public var punctuation: Attribute
    public var constants: Attribute
    public var gutterText: PlatformColor
    public var gutterBackground: PlatformColor
    public var reformattingGuide: PlatformColor

    public init(
        text: Attribute,
        insertionPoint: PlatformColor,
        invisibles: Attribute,
        background: PlatformColor,
        lineHighlight: PlatformColor,
        selection: PlatformColor,
        keywords: Attribute,
        commands: Attribute,
        types: Attribute,
        attributes: Attribute,
        variables: Attribute,
        values: Attribute,
        numbers: Attribute,
        strings: Attribute,
        characters: Attribute,
        comments: Attribute,
        operators: Attribute? = nil,
        punctuation: Attribute? = nil,
        constants: Attribute? = nil,
        gutterText: PlatformColor? = nil,
        gutterBackground: PlatformColor? = nil,
        reformattingGuide: PlatformColor? = nil
    ) {
        self.text = text
        self.insertionPoint = insertionPoint
        self.invisibles = invisibles
        self.background = background
        self.lineHighlight = lineHighlight
        self.selection = selection
        self.keywords = keywords
        self.commands = commands
        self.types = types
        self.attributes = attributes
        self.variables = variables
        self.values = values
        self.numbers = numbers
        self.strings = strings
        self.characters = characters
        self.comments = comments
        self.operators = operators ?? .init(color: PlatformDefaults.operatorColor)
        self.punctuation = punctuation ?? .init(color: PlatformDefaults.punctuationColor)
        self.constants = constants ?? values
        self.gutterText = gutterText ?? text.color.withAlphaComponent(0.4)
        self.gutterBackground = gutterBackground ?? background
        self.reformattingGuide = reformattingGuide ?? PlatformDefaults.reformattingGuideColor
    }

    /// Default light theme with distinct syntax colors (Xcode-like).
    public static var `default`: EditorTheme {
        EditorTheme(
            text: .init(color: PlatformDefaults.textColor),
            insertionPoint: PlatformDefaults.caretColor,
            invisibles: .init(color: PlatformDefaults.textColor.withAlphaComponent(0.35)),
            background: PlatformDefaults.editorBackground,
            lineHighlight: PlatformDefaults.lineHighlight,
            selection: PlatformDefaults.selectionColor,
            keywords: .init(color: PlatformDefaults.keywordColor, bold: true),
            commands: .init(color: PlatformDefaults.keywordColor),
            types: .init(color: PlatformDefaults.typeColor),
            attributes: .init(color: PlatformDefaults.attributeColor),
            variables: .init(color: PlatformDefaults.variableColor),
            values: .init(color: PlatformDefaults.valueColor),
            numbers: .init(color: PlatformDefaults.numberColor),
            strings: .init(color: PlatformDefaults.stringColor),
            characters: .init(color: PlatformDefaults.stringColor),
            comments: .init(color: PlatformDefaults.commentColor, italic: true),
            operators: .init(color: PlatformDefaults.operatorColor),
            punctuation: .init(color: PlatformDefaults.punctuationColor),
            constants: .init(color: PlatformDefaults.valueColor)
        )
    }

    /// Optional overrides for capture names / extension theme tokens (string keys).
    /// Keys are lowercased capture names (e.g. `"keyword"`, `"function"`).
    public var tokenOverrides: [String: Attribute] = [:]

    /// Maps a capture to theme attributes.
    public func attribute(for capture: CaptureName?) -> Attribute {
        guard let capture else { return text }
        if let override = tokenOverrides[capture.rawValue.lowercased()] {
            return override
        }
        switch capture {
        case .include, .constructor, .keyword, .boolean, .variableBuiltin,
             .keywordReturn, .keywordFunction, .repeat, .conditional, .tag:
            return keywords
        case .comment:
            return comments
        case .variable, .property, .parameter:
            return variables
        case .function, .method:
            return values
        case .number, .float:
            return numbers
        case .string, .character:
            return strings
        case .type, .typeAlternate:
            return types
        case .attribute:
            return attributes
        case .command:
            return commands
        case .value, .constant:
            return constants
        case .operator:
            return operators
        case .punctuation:
            return punctuation
        case .text:
            return text
        }
    }

    /// Resolve a free-form syntax token name (extension themes / Zed-style tokens).
    public func resolve(token: String) -> Attribute {
        let key = token.lowercased()
        if let override = tokenOverrides[key] { return override }
        if let capture = CaptureName(rawValue: key) {
            return attribute(for: capture)
        }
        // Common aliases
        switch key {
        case "keyword", "keyword.control", "storage.type": return keywords
        case "comment", "comment.line", "comment.block": return comments
        case "string", "string.quoted": return strings
        case "constant.numeric", "number": return numbers
        case "entity.name.function", "function", "support.function": return values
        case "entity.name.type", "type", "storage.type.class": return types
        case "variable", "variable.other": return variables
        case "constant", "constant.language": return constants
        case "keyword.operator", "operator": return operators
        case "punctuation", "meta.brace": return punctuation
        default: return text
        }
    }

    /// Merges string token colors into ``tokenOverrides`` (host/extension themes).
    public mutating func applyTokenMap(_ map: [String: PlatformColor]) {
        for (key, color) in map {
            tokenOverrides[key.lowercased()] = Attribute(color: color)
        }
    }

    public func color(for capture: CaptureName?) -> PlatformColor {
        attribute(for: capture).color
    }

    /// Returns `font` with bold/italic traits required by the capture.
    public func font(for capture: CaptureName?, base: PlatformFont) -> PlatformFont {
        let attrs = attribute(for: capture)
        guard attrs.bold || attrs.italic else { return base }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        var result = base
        if attrs.bold {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }
        if attrs.italic {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
        #else
        var traits = base.fontDescriptor.symbolicTraits
        if attrs.bold { traits.insert(.traitBold) }
        if attrs.italic { traits.insert(.traitItalic) }
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return PlatformFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }
}

