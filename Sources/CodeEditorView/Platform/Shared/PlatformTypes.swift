import CoreGraphics

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
    public typealias PlatformFont = NSFont
    public typealias PlatformColor = NSColor
    public typealias PlatformView = NSView
#elseif canImport(UIKit)
    import UIKit
    public typealias PlatformFont = UIFont
    public typealias PlatformColor = UIColor
    public typealias PlatformView = UIView
#endif

public enum PlatformDefaults {
    public static var monospacedFont: PlatformFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    public static var textColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .labelColor
        #else
            .label
        #endif
    }

    public static var selectionColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .selectedTextBackgroundColor
        #else
            .systemBlue.withAlphaComponent(0.3)
        #endif
    }

    public static var caretColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .textColor
        #else
            .label
        #endif
    }

    public static var editorBackground: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .textBackgroundColor
        #else
            .systemBackground
        #endif
    }

    public static var lineHighlight: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .selectedTextBackgroundColor.withSystemEffect(.disabled)
        #else
            .systemGray.withAlphaComponent(0.15)
        #endif
    }

    public static var keywordColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemPink
        #else
            .systemPink
        #endif
    }

    public static var typeColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemTeal
        #else
            .systemTeal
        #endif
    }

    public static var stringColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemRed
        #else
            .systemRed
        #endif
    }

    public static var numberColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemBlue
        #else
            .systemBlue
        #endif
    }

    public static var valueColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemPurple
        #else
            .systemPurple
        #endif
    }

    public static var commentColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .secondaryLabelColor
        #else
            .secondaryLabel
        #endif
    }

    public static var variableColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemCyan
        #else
            .systemCyan
        #endif
    }

    public static var attributeColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemBrown
        #else
            .systemBrown
        #endif
    }

    public static var operatorColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .systemOrange
        #else
            .systemOrange
        #endif
    }

    public static var punctuationColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .tertiaryLabelColor
        #else
            .tertiaryLabel
        #endif
    }

    public static var reformattingGuideColor: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            .separatorColor
        #else
            .separator
        #endif
    }
}
