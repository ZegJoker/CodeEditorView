import Foundation

/// Operating-system class the host is running on.
public enum HostPlatform: String, Sendable, Hashable, Codable, CaseIterable {
    case macOS
    case iOS
    case other

    /// Platform of the current process.
    public static var current: HostPlatform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #else
        return .other
        #endif
    }
}
