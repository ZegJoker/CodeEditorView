import CoreGraphics
import Foundation

/// Find panel layout mode (find-only vs find + replace).
public enum FindPanelMode: String, CaseIterable, Sendable, Hashable, Codable {
    case find
    case replace

    public var displayName: String {
        switch self {
        case .find: return "Find"
        case .replace: return "Replace"
        }
    }

    /// Panel height used by CESE-style chrome (points).
    public var panelHeight: CGFloat {
        switch self {
        case .find: return 28
        case .replace: return 54
        }
    }
}
