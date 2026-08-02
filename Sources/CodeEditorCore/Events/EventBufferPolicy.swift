import Foundation

/// Validated finite buffer policy for event streams (DOC-N06).
///
/// Unbounded public buffers are not allowed. Capacity must be in
/// `1...EventBufferPolicy.maximumCapacity`.
public struct EventBufferPolicy: Sendable, Hashable, Codable {
    /// Hard maximum capacity accepted by public APIs.
    public static let maximumCapacity: Int = 10_000
    /// Default newest-N buffer for document/editor event streams.
    public static let `default` = EventBufferPolicy(uncheckedCapacity: 32)

    public let capacity: Int

    /// Creates a policy after validating `capacity`.
    public init(capacity: Int) throws {
        guard capacity > 0, capacity <= Self.maximumCapacity else {
            throw EventBufferPolicyError.invalidCapacity(capacity)
        }
        self.capacity = capacity
    }

    private init(uncheckedCapacity: Int) {
        self.capacity = uncheckedCapacity
    }
}

public enum EventBufferPolicyError: Error, Sendable, Equatable {
    case invalidCapacity(Int)
}


