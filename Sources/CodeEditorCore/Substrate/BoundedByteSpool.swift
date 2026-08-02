import Foundation

/// Bounded byte accumulator with truncation metrics and absolute-offset viewport reads
/// (audit §22 / PR-14 / TASK-N03).
///
/// Used by process and task output paths so public streams never grow without limit.
/// Dropped prefix bytes advance ``baseOffset`` so UI can page by absolute sequence range.
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

    /// Result of a sequence-range / UI viewport read over the spool.
    public struct ViewportRead: Sendable, Equatable {
        /// Absolute stream offset the caller requested.
        public let requestedOffset: UInt64
        /// Absolute offset of the first byte in ``data`` (clamped into retained window).
        public let absoluteOffset: UInt64
        /// Bytes returned (may be empty when offset is past the end).
        public let data: Data
        /// True when the requested offset lies before the retained window (prefix dropped).
        public let leadingTruncated: Bool
        /// Absolute end of currently retained data (`baseOffset + storedByteCount`).
        public let availableEnd: UInt64
        /// Absolute start of currently retained data.
        public let availableStart: UInt64

        public init(
            requestedOffset: UInt64,
            absoluteOffset: UInt64,
            data: Data,
            leadingTruncated: Bool,
            availableEnd: UInt64,
            availableStart: UInt64
        ) {
            self.requestedOffset = requestedOffset
            self.absoluteOffset = absoluteOffset
            self.data = data
            self.leadingTruncated = leadingTruncated
            self.availableEnd = availableEnd
            self.availableStart = availableStart
        }
    }

    public let maxBytes: Int
    public let overflow: OverflowBehavior
    private var storage = Data()
    public private(set) var droppedByteCount: Int = 0
    public private(set) var appendCount: Int = 0
    /// Absolute byte offset of the first stored byte in the logical stream.
    /// Advances when ``OverflowBehavior/dropOldest`` discards a prefix.
    public private(set) var baseOffset: UInt64 = 0
    /// Total bytes ever appended (logical stream end = this value).
    public private(set) var totalAppendedBytes: UInt64 = 0

    public init(maxBytes: Int, overflow: OverflowBehavior = .dropOldest) {
        self.maxBytes = max(0, maxBytes)
        self.overflow = overflow
    }

    public var storedByteCount: Int { storage.count }

    /// Absolute end offset of retained data (exclusive).
    public var absoluteEndOffset: UInt64 {
        baseOffset + UInt64(storage.count)
    }

    public func append(_ data: Data) -> AppendResult {
        appendCount += 1
        totalAppendedBytes += UInt64(data.count)
        guard maxBytes > 0 else {
            droppedByteCount += data.count
            // Reject everything: no retained window; base tracks logical end.
            baseOffset = totalAppendedBytes
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
            baseOffset += UInt64(overflowCount)
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

    /// Read up to `byteCount` starting at absolute stream offset `absoluteOffset` (TASK-N03 UI viewport).
    ///
    /// When the requested offset is before the retained window, the read begins at ``baseOffset``
    /// and ``ViewportRead/leadingTruncated`` is set.
    public func read(from absoluteOffset: UInt64, maxBytes byteCount: Int) -> ViewportRead {
        let availableStart = baseOffset
        let availableEnd = baseOffset &+ UInt64(storage.count)
        let limit = byteCount > 0 ? byteCount : 0
        let leadingTruncated = absoluteOffset < availableStart
        // Clamp start into [availableStart, availableEnd].
        var startAbs = absoluteOffset
        if startAbs < availableStart { startAbs = availableStart }
        if startAbs > availableEnd { startAbs = availableEnd }
        let localStart = Int(startAbs &- availableStart)
        let remaining = storage.count > localStart ? storage.count - localStart : 0
        let take = remaining < limit ? remaining : limit
        let slice: Data
        if take > 0, localStart >= 0, localStart + take <= storage.count {
            // Prefer dropFirst/prefix so we never form an invalid Range on sliced Data storage.
            slice = Data(storage.dropFirst(localStart).prefix(take))
        } else {
            slice = Data()
        }
        return ViewportRead(
            requestedOffset: absoluteOffset,
            absoluteOffset: startAbs,
            data: slice,
            leadingTruncated: leadingTruncated,
            availableEnd: availableEnd,
            availableStart: availableStart
        )
    }

    public func clear() {
        storage.removeAll(keepingCapacity: false)
        baseOffset = totalAppendedBytes
    }
}
