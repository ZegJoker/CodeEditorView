import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import Foundation

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

    /// EXT-N08: throw when CryptoKit is unavailable — never `fatalError`.
    public static func payloadDigest(
        _ data: Data,
        availability: CryptoAvailability = .system
    ) throws -> String {
        let full = try SecurityDigest.sha256Hex(data, availability: availability)
        return String(full.prefix(16))
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
        let digest: String
        do {
            digest = try ConformanceEvent.payloadDigest(payload)
        } catch {
            // EXT-N08: fail closed without process death — mark digest unusable.
            digest = "crypto-unavailable"
        }
        record(
            ConformanceEvent(
                method: method.rawValue,
                direction: direction,
                payloadDigest: digest,
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
