import Foundation

/// Streaming UTF-8 decoder that holds incomplete trailing multibyte sequences
/// until the next chunk completes them (audit TASK-N02 / process output).
///
/// Incomplete sequences are retained in a carry buffer; callers never see a
/// replacement character for a split scalar that later completes.
public struct IncrementalUTF8Decoder: Sendable {
    private var carry = Data()
    /// Maximum carry retained when bytes never form valid UTF-8 (fail-closed bound).
    private let maxCarryBytes: Int

    public init(maxCarryBytes: Int = 8) {
        self.maxCarryBytes = max(4, maxCarryBytes)
    }

    public var pendingByteCount: Int { carry.count }

    /// Push raw bytes; returns fully-decoded complete scalars as a string and the
    /// raw bytes that were consumed (complete sequences only). Incomplete tail stays
    /// in the decoder.
    @discardableResult
    public mutating func push(_ data: Data) -> (text: String, consumed: Data) {
        guard !data.isEmpty || !carry.isEmpty else {
            return ("", Data())
        }
        carry.append(data)
        // Cap carry if garbage never completes (avoid unbounded growth on binary noise).
        if carry.count > maxCarryBytes + 16 * 1024 {
            // Emit replacement for overlong invalid prefix, keep last maxCarryBytes.
            let drop = carry.count - maxCarryBytes
            let dropped = carry.prefix(drop)
            carry.removeFirst(drop)
            let replaced = String(decoding: dropped, as: UTF8.self)
            return (replaced, Data(dropped))
        }

        // Longest complete UTF-8 prefix ending before any incomplete trailing sequence.
        let end = Self.completePrefixEnd(carry)
        guard end > 0 else {
            return ("", Data())
        }
        let complete = Data(carry.prefix(end))
        carry.removeFirst(end)
        let text = String(decoding: complete, as: UTF8.self)
        return (text, complete)
    }

    /// Flush remaining carry at stream end (may include U+FFFD for incomplete tail).
    public mutating func finish() -> String {
        guard !carry.isEmpty else { return "" }
        let text = String(decoding: carry, as: UTF8.self)
        carry.removeAll(keepingCapacity: false)
        return text
    }

    public mutating func reset() {
        carry.removeAll(keepingCapacity: false)
    }

    /// Index of first incomplete trailing sequence start, or `data.count` if all complete.
    private static func completePrefixEnd(_ data: Data) -> Int {
        if data.isEmpty { return 0 }
        var i = data.count
        // Walk back at most 3 bytes to find a valid lead that needs more bytes.
        let minCheck = max(0, data.count - 3)
        while i > minCheck {
            let b = data[data.startIndex + (i - 1)]
            if b & 0b1000_0000 == 0 {
                // ASCII — complete through i.
                return i
            }
            if b & 0b1100_0000 == 0b1000_0000 {
                // Continuation — keep walking back.
                i -= 1
                continue
            }
            // Lead byte at i-1.
            let leadIndex = i - 1
            let lead = data[data.startIndex + leadIndex]
            let needed: Int
            if lead & 0b1110_0000 == 0b1100_0000 {
                needed = 2
            } else if lead & 0b1111_0000 == 0b1110_0000 {
                needed = 3
            } else if lead & 0b1111_1000 == 0b1111_0000 {
                needed = 4
            } else {
                // Invalid lead — treat as complete through end (will become U+FFFD).
                return data.count
            }
            let available = data.count - leadIndex
            if available >= needed {
                return data.count
            }
            // Incomplete sequence starts at leadIndex.
            return leadIndex
        }
        return data.count
    }
}
