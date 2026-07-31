/// Typed platform / capability failures. Prefer these over incidental Foundation errors.
public enum CodeEditorPlatformError: Error, Sendable, Equatable {
    case unsupportedCapability(kind: PlatformCapabilityKind, reason: String)

    public var localizedDescription: String {
        switch self {
        case let .unsupportedCapability(kind, reason):
            return "Unsupported capability \(kind.rawValue): \(reason)"
        }
    }
}
