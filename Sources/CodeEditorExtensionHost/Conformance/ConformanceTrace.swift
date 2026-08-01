import CodeEditorExtensionProtocol
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#endif

public struct ConformanceEvent: Sendable, Equatable, Hashable, Codable {
    public var method: String
    public var direction: String  // "host→guest" | "guest→host" | "local"
    public var payloadDigest: String
    public var errorCode: Int?
    public var generation: UInt64

    public init(
        method: String,
        direction: String,
        payloadDigest: String,
        errorCode: Int? = nil,
        generation: UInt64 = 0
    ) {
        self.method = method
        self.direction = direction
        self.payloadDigest = payloadDigest
        self.errorCode = errorCode
        self.generation = generation
    }

    public static func payloadDigest(_ data: Data) -> String {
        #if canImport(CryptoKit)
            return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
            return String(format: "%08x", data.count)
        #endif
    }
}

public final class ConformanceTracer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ConformanceEvent] = []

    public init() {}

    public func record(_ event: ConformanceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    public func record(
        method: ExtensionMethodID,
        direction: String,
        payload: Data,
        errorCode: Int? = nil,
        generation: UInt64 = 0
    ) {
        record(
            ConformanceEvent(
                method: method.rawValue,
                direction: direction,
                payloadDigest: ConformanceEvent.payloadDigest(payload),
                errorCode: errorCode,
                generation: generation
            ))
    }

    public func snapshot() -> [ConformanceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    public func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }

    /// Compare traces ignoring generation fields (normalized dual-run).
    public static func equivalent(_ a: [ConformanceEvent], _ b: [ConformanceEvent]) -> Bool {
        let na = a.map {
            ConformanceEvent(
                method: $0.method,
                direction: $0.direction,
                payloadDigest: $0.payloadDigest,
                errorCode: $0.errorCode,
                generation: 0
            )
        }
        let nb = b.map {
            ConformanceEvent(
                method: $0.method,
                direction: $0.direction,
                payloadDigest: $0.payloadDigest,
                errorCode: $0.errorCode,
                generation: 0
            )
        }
        return na == nb
    }
}
