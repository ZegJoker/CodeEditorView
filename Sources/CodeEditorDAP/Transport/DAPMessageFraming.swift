import Foundation

/// DAP Content-Length framing (same wire shape as LSP).
public enum DAPMessageFraming {
    public static let defaultMaxBodyBytes = 16 * 1024 * 1024
    public static let defaultMaxBufferBytes = 20 * 1024 * 1024

    public static func encode(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case bodyTooLarge(Int)
        case bufferOverflow(Int)
        case invalidHeader
        case invalidUTF8Header
    }

    public final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        public let maxBodyBytes: Int
        public let maxBufferBytes: Int
        public private(set) var lastError: DecodeError?

        public init(
            maxBodyBytes: Int = DAPMessageFraming.defaultMaxBodyBytes,
            maxBufferBytes: Int = DAPMessageFraming.defaultMaxBufferBytes
        ) {
            let bodyCap = max(1, maxBodyBytes)
            self.maxBodyBytes = bodyCap
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
                // Drop leading non-framed garbage before each extract attempt (DAP-N09).
                discardLeadingGarbage()
                do {
                    guard let message = try tryExtract() else { break }
                    messages.append(message)
                } catch let error as DecodeError {
                    lastError = error
                    switch error {
                    case .bodyTooLarge, .bufferOverflow:
                        buffer.removeAll(keepingCapacity: false)
                        return messages
                    case .invalidHeader, .invalidUTF8Header:
                        // tryExtract advanced past the bad header; continue scanning.
                        continue
                    }
                } catch {
                    lastError = .invalidHeader
                    if !buffer.isEmpty { buffer.removeFirst() }
                    continue
                }
            }
            return messages
        }

        /// Remove bytes before the next `Content-Length:` framing marker (DAP-N09 malformed resync).
        private func discardLeadingGarbage() {
            let marker = Data("Content-Length:".utf8)
            let markerLower = Data("content-length:".utf8)
            if buffer.isEmpty { return }
            if buffer.starts(with: marker) || buffer.starts(with: markerLower) {
                return
            }
            if let range = buffer.range(of: marker) ?? buffer.range(of: markerLower) {
                buffer.removeSubrange(buffer.startIndex..<range.lowerBound)
                lastError = .invalidHeader
            }
            // Leave short prefixes without a marker (may be incomplete header); overflow path clears.
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
            guard let header = String(data: headerData, encoding: .utf8) else {
                // Drop one UTF-8-invalid byte cluster and resync.
                buffer.removeSubrange(buffer.startIndex..<min(buffer.index(after: buffer.startIndex), sepRange.upperBound))
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
                // Skip this separator block only — next loop will discardLeadingGarbage/resync.
                buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
                throw DecodeError.invalidHeader
            }
            if length > maxBodyBytes {
                // Skip oversized header+body when body is fully buffered; else wait.
                let bodyStart = sepRange.upperBound
                let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
                if available >= length {
                    let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                    buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                } else {
                    buffer.removeAll(keepingCapacity: false)
                }
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
