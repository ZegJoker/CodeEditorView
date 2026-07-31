import Foundation

/// LSP Content-Length framing encode/decode with hard payload caps.
public enum LSPMessageFraming {
    /// Default maximum accepted body size (16 MiB).
    public static let defaultMaxBodyBytes = 16 * 1024 * 1024
    /// Maximum buffered unparsed bytes before reset.
    public static let defaultMaxBufferBytes = 20 * 1024 * 1024

    public static func encode(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    public static func encodeJSONObject(_ object: Any) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        return encode(body)
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case bodyTooLarge(Int)
        case bufferOverflow(Int)
        case invalidHeader
        case invalidUTF8Header
    }

    /// Incremental decoder for partial TCP/pipe reads.
    public final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        public let maxBodyBytes: Int
        public let maxBufferBytes: Int
        public private(set) var lastError: DecodeError?

        public init(
            maxBodyBytes: Int = LSPMessageFraming.defaultMaxBodyBytes,
            maxBufferBytes: Int = LSPMessageFraming.defaultMaxBufferBytes
        ) {
            let bodyCap = max(1, maxBodyBytes)
            self.maxBodyBytes = bodyCap
            // Respect an explicitly smaller buffer cap (used by fuzz tests).
            self.maxBufferBytes = max(bodyCap + 1, maxBufferBytes)
        }

        public func append(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            lastError = nil
            buffer.append(data)
            if buffer.count > maxBufferBytes {
                lastError = .bufferOverflow(buffer.count)
                buffer.removeAll(keepingCapacity: false)
                return []
            }
            var messages: [Data] = []
            while true {
                do {
                    guard let message = try tryExtract() else { break }
                    messages.append(message)
                } catch let error as DecodeError {
                    lastError = error
                    // Drop partial header/body on hard errors to recover stream.
                    buffer.removeAll(keepingCapacity: false)
                    break
                } catch {
                    lastError = .invalidHeader
                    buffer.removeAll(keepingCapacity: false)
                    break
                }
            }
            return messages
        }

        public func reset() {
            lock.lock()
            buffer.removeAll(keepingCapacity: false)
            lastError = nil
            lock.unlock()
        }

        private func tryExtract() throws -> Data? {
            let separator = Data("\r\n\r\n".utf8)
            guard let sepRange = buffer.range(of: separator) else { return nil }
            let headerData = buffer.subdata(in: buffer.startIndex..<sepRange.lowerBound)
            guard String(data: headerData, encoding: .utf8) != nil else {
                throw DecodeError.invalidUTF8Header
            }
            guard let header = String(data: headerData, encoding: .utf8) else {
                throw DecodeError.invalidUTF8Header
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
                // Skip bad header block
                buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
                throw DecodeError.invalidHeader
            }
            if length > maxBodyBytes {
                throw DecodeError.bodyTooLarge(length)
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
