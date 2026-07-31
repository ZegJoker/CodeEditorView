import Foundation

/// Four-byte big-endian length prefix + CBOR body (canonical wire framing).
public enum CBORFraming {
    public static let defaultMaxFrameBytes = 4 * 1024 * 1024

    public static func encode(_ body: Data, maxFrameBytes: Int = defaultMaxFrameBytes) throws -> Data {
        guard body.count <= maxFrameBytes else {
            throw ExtensionWireError.payloadTooLarge
        }
        var out = Data(capacity: 4 + body.count)
        let len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        public var maxFrameBytes: Int
        public private(set) var framesAccepted: Int = 0
        public private(set) var bytesSeen: UInt64 = 0

        public init(maxFrameBytes: Int = CBORFraming.defaultMaxFrameBytes) {
            self.maxFrameBytes = maxFrameBytes
        }

        public func append(_ data: Data) throws -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            bytesSeen += UInt64(data.count)
            var messages: [Data] = []
            while true {
                guard buffer.count >= 4 else { break }
                let length: UInt32 = buffer.prefix(4).withUnsafeBytes { raw in
                    raw.load(as: UInt32.self).bigEndian
                }
                if length > UInt32(maxFrameBytes) {
                    buffer.removeAll(keepingCapacity: false)
                    throw ExtensionWireError.payloadTooLarge
                }
                let total = 4 + Int(length)
                guard buffer.count >= total else { break }
                let body = buffer.subdata(in: 4..<total)
                buffer.removeSubrange(0..<total)
                framesAccepted += 1
                messages.append(body)
            }
            return messages
        }

        public func reset() {
            lock.lock()
            buffer.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }
}
