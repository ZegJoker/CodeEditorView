import Foundation

/// LSP Content-Length framing encode/decode.
public enum LSPMessageFraming {
    public static func encode(_ body: Data) -> Data {
        var header = "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    public static func encodeJSONObject(_ object: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        return encode(body)
    }

    /// Incremental decoder for partial TCP/pipe reads.
    public final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        public init() {}

        public func append(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            var messages: [Data] = []
            while let message = tryExtract() {
                messages.append(message)
            }
            return messages
        }

        private func tryExtract() -> Data? {
            // Find header/body separator.
            let separator = Data("\r\n\r\n".utf8)
            guard let sepRange = buffer.range(of: separator) else { return nil }
            let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else {
                buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
                return nil
            }
            var contentLength: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1])
                }
            }
            guard let length = contentLength, length >= 0 else {
                buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
                return nil
            }
            let bodyStart = sepRange.upperBound
            let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
            guard available >= length else { return nil }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            return body
        }
    }
}
