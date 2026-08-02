import Foundation

/// Bounded byte accumulator with truncation metrics (audit §22 / PR-14).
///
/// Used by process output paths so public streams never grow without limit.
public actor BoundedByteSpool {
    public enum OverflowBehavior: Sendable, Hashable {
        /// Keep the newest bytes; drop from the front.
        case dropOldest
        /// Keep the oldest bytes; reject further appends.
        case rejectNewest
        /// Keep prefix of each append that fits; discard the rest of the chunk.
        case truncateNewest
    }

    public struct AppendResult: Sendable, Equatable {
        public var acceptedBytes: Int
        public var droppedBytes: Int
        public var truncated: Bool

        public init(acceptedBytes: Int, droppedBytes: Int, truncated: Bool) {
            self.acceptedBytes = acceptedBytes
            self.droppedBytes = droppedBytes
            self.truncated = truncated
        }
    }

    public let maxBytes: Int
    public let overflow: OverflowBehavior
    private var storage = Data()
    public private(set) var droppedByteCount: Int = 0
    public private(set) var appendCount: Int = 0

    public init(maxBytes: Int, overflow: OverflowBehavior = .dropOldest) {
        self.maxBytes = max(0, maxBytes)
        self.overflow = overflow
    }

    public var storedByteCount: Int { storage.count }

    public func append(_ data: Data) -> AppendResult {
        appendCount += 1
        guard maxBytes > 0 else {
            droppedByteCount += data.count
            return AppendResult(acceptedBytes: 0, droppedBytes: data.count, truncated: data.count > 0)
        }
        guard !data.isEmpty else {
            return AppendResult(acceptedBytes: 0, droppedBytes: 0, truncated: false)
        }

        switch overflow {
        case .rejectNewest:
            let room = maxBytes - storage.count
            if room <= 0 {
                droppedByteCount += data.count
                return AppendResult(acceptedBytes: 0, droppedBytes: data.count, truncated: true)
            }
            if data.count <= room {
                storage.append(data)
                return AppendResult(acceptedBytes: data.count, droppedBytes: 0, truncated: false)
            }
            let slice = data.prefix(room)
            storage.append(slice)
            let dropped = data.count - room
            droppedByteCount += dropped
            return AppendResult(acceptedBytes: room, droppedBytes: dropped, truncated: true)

        case .truncateNewest:
            let room = maxBytes - storage.count
            if room <= 0 {
                droppedByteCount += data.count
                return AppendResult(acceptedBytes: 0, droppedBytes: data.count, truncated: true)
            }
            if data.count <= room {
                storage.append(data)
                return AppendResult(acceptedBytes: data.count, droppedBytes: 0, truncated: false)
            }
            storage.append(data.prefix(room))
            let dropped = data.count - room
            droppedByteCount += dropped
            return AppendResult(acceptedBytes: room, droppedBytes: dropped, truncated: true)

        case .dropOldest:
            storage.append(data)
            if storage.count <= maxBytes {
                return AppendResult(acceptedBytes: data.count, droppedBytes: 0, truncated: false)
            }
            let overflowCount = storage.count - maxBytes
            storage.removeFirst(overflowCount)
            droppedByteCount += overflowCount
            // Accepted as much of this chunk as remains in the window.
            let accepted = max(0, data.count - overflowCount)
            return AppendResult(
                acceptedBytes: min(data.count, accepted + max(0, maxBytes - (storage.count - min(data.count, storage.count)))),
                droppedBytes: overflowCount,
                truncated: true
            )
        }
    }

    public func readAll() -> Data { storage }

    public func clear() {
        storage.removeAll(keepingCapacity: false)
    }
}
