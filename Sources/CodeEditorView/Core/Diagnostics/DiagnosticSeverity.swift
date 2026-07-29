import CoreGraphics
import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Severity for line annotations / diagnostics (CESE #297 aligned).
public enum DiagnosticSeverity: String, Sendable, Hashable, Codable, CaseIterable {
    case error
    case warning
    case info
    /// Live / subtle hint (e.g. unused, style).
    case live

    /// SF Symbol names aligned with mchakravarty `Message.defaultTheme`.
    public var systemImage: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .live: return "line.horizontal.3"
        }
    }

    /// Display tint for icons / underlines.
    /// Colours aligned with mchakravarty `Message.defaultTheme`.
    public var color: PlatformColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        switch self {
        case .error: return .systemRed
        case .warning: return .systemYellow
        case .info: return .systemCyan
        case .live: return .systemGreen
        }
        #else
        switch self {
        case .error: return .systemRed
        case .warning: return .systemYellow
        case .info: return .systemCyan
        case .live: return .systemGreen
        }
        #endif
    }
}
