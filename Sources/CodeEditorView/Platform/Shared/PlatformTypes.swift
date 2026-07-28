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
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        .monospacedSystemFont(ofSize: 12, weight: .regular)
        #else
        .monospacedSystemFont(ofSize: 12, weight: .regular)
        #endif
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
}
