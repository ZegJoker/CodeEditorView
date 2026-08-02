import Foundation

/// Severity for editor-local diagnostics (UI-N07).
public enum EditorDiagnosticSeverity: String, Sendable, Equatable {
    case info
    case warning
    case error
}

/// Domain for routing editor failures (UI-N07).
public enum EditorDiagnosticDomain: String, Sendable, Equatable {
    case input
    case layout
    case command
    case ime
    case accessibility
    case largeFile
}

/// Structured diagnostic for input/action failures that must not be swallowed (UI-N07).
public struct EditorDiagnostic: Sendable, Equatable {
    public var domain: EditorDiagnosticDomain
    public var severity: EditorDiagnosticSeverity
    public var message: String
    public var operation: String?
    /// Selection snapshot to restore after a failed atomic input op (optional).
    public var selectionSnapshot: [NSRange]?
    public var underlyingDescription: String?

    public init(
        domain: EditorDiagnosticDomain,
        severity: EditorDiagnosticSeverity,
        message: String,
        operation: String? = nil,
        selectionSnapshot: [NSRange]? = nil,
        underlying: Error? = nil
    ) {
        self.domain = domain
        self.severity = severity
        self.message = message
        self.operation = operation
        self.selectionSnapshot = selectionSnapshot
        self.underlyingDescription = underlying.map { String(describing: $0) }
    }
}

/// Centralized diagnostic sink for native editor input paths (UI-N07).
///
/// Input/action failures must route here instead of `try?` swallows so selection
/// and document state stay coherent.
@MainActor
public final class EditorDiagnosticChannel {
    public private(set) var recent: [EditorDiagnostic] = []
    public var maxRecent: Int = 64
    public var onDiagnostic: ((EditorDiagnostic) -> Void)?

    public init() {}

    public func report(_ diagnostic: EditorDiagnostic) {
        recent.append(diagnostic)
        if recent.count > maxRecent {
            recent.removeFirst(recent.count - maxRecent)
        }
        onDiagnostic?(diagnostic)
    }

    public func reportInputFailure(_ error: Error, operation: String, selectionSnapshot: [NSRange]? = nil) {
        report(
            EditorDiagnostic(
                domain: .input,
                severity: .error,
                message: "Input operation failed: \(operation)",
                operation: operation,
                selectionSnapshot: selectionSnapshot,
                underlying: error
            )
        )
    }

    public func reportCommandFailure(_ error: Error, operation: String, selectionSnapshot: [NSRange]? = nil) {
        report(
            EditorDiagnostic(
                domain: .command,
                severity: .error,
                message: "Command failed: \(operation)",
                operation: operation,
                selectionSnapshot: selectionSnapshot,
                underlying: error
            )
        )
    }
}

/// Result-returning helper so input paths cannot silently discard errors (UI-N07).
public enum EditorInputActions: Sendable {
    public static func runThrowing(_ body: () throws -> Void) -> Result<Void, Error> {
        do {
            try body()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    public static func runThrowing<T>(_ body: () throws -> T) -> Result<T, Error> {
        do {
            return .success(try body())
        } catch {
            return .failure(error)
        }
    }
}
