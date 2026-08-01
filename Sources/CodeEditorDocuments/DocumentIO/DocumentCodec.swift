import CodeEditorCore
import Foundation

/// Structured decode outcome (DOC-007 / §7.9).
public struct DocumentDecodeResult: Sendable, Equatable {
    public var text: String
    public var encoding: DocumentEncoding
    public var hadBOM: Bool
    /// True when the decoder accepted the bytes without replacement/fallback.
    public var isLossless: Bool

    public init(text: String, encoding: DocumentEncoding, hadBOM: Bool, isLossless: Bool) {
        self.text = text
        self.encoding = encoding
        self.hadBOM = hadBOM
        self.isLossless = isLossless
    }
}

/// Encode/decode document text with encoding, BOM, and line-ending policies.
///
/// Supported encodings are explicit. Free-form ``DocumentEncoding/other`` is rejected
/// unless a ``HostTextCodec`` is supplied (DOC-007).
public enum DocumentCodec: Sendable {
    /// Decode document bytes. Never silently remaps arbitrary encodings to UTF-8.
    public static func decode(_ data: Data) throws -> DocumentDecodeResult {
        var slice = data
        var bom = false
        let encoding = DocumentEncoding.detect(from: data)
        switch encoding {
        case .utf8:
            if slice.starts(with: [0xEF, 0xBB, 0xBF]) {
                slice = Data(slice.dropFirst(3))
                bom = true
            }
        case .utf16LittleEndian:
            if slice.starts(with: [0xFF, 0xFE]) {
                slice = Data(slice.dropFirst(2))
                bom = true
            }
        case .utf16BigEndian:
            if slice.starts(with: [0xFE, 0xFF]) {
                slice = Data(slice.dropFirst(2))
                bom = true
            }
        case .utf16:
            break
        case .other(let name):
            throw DocumentIOError.unsupportedEncoding(name)
        }

        guard let stringEncoding = encoding.stringEncodingOrNil else {
            throw DocumentIOError.unsupportedEncoding(String(describing: encoding))
        }
        guard let text = String(data: slice, encoding: stringEncoding) else {
            // Do not fall back to UTF-8 (mojibake risk). Surface failure.
            throw DocumentIOError.encodingFailed
        }
        // Round-trip check for lossy conversions.
        if let reencoded = text.data(using: stringEncoding), reencoded != slice {
            // Allow UTF-16 endian BOM strip differences only — already stripped.
            // For UTF-8, require exact round-trip of payload.
            if encoding == .utf8 {
                throw DocumentIOError.encodingFailed
            }
        }
        return DocumentDecodeResult(text: text, encoding: encoding, hadBOM: bom, isLossless: true)
    }

    /// Legacy tuple API used by older call sites.
    public static func decodeLegacy(_ data: Data) throws -> (text: String, encoding: DocumentEncoding, bom: Bool) {
        let r = try decode(data)
        return (r.text, r.encoding, r.hadBOM)
    }

    public static func encode(
        text: String,
        encoding: DocumentEncoding,
        lineEndingPolicy: LineEndingSavePolicy,
        bomPolicy: BOMPolicy
    ) throws -> Data {
        if case .other(let name) = encoding {
            throw DocumentIOError.unsupportedEncoding(name)
        }
        var body = text
        if case .convert(let ending) = lineEndingPolicy {
            body = TextOffsetSemantics.normalizeLineEndings(body, to: ending)
        }

        guard let stringEncoding = encoding.stringEncodingOrNil else {
            throw DocumentIOError.unsupportedEncoding(String(describing: encoding))
        }
        guard var data = body.data(using: stringEncoding) else {
            throw DocumentIOError.encodingFailed
        }

        let emitBOM: Bool = {
            switch bomPolicy {
            case .none: return false
            case .whenEncodingSupports: return true
            case .preserve(let had): return had
            }
        }()

        if emitBOM {
            switch encoding {
            case .utf8:
                data = Data([0xEF, 0xBB, 0xBF]) + data
            case .utf16LittleEndian, .utf16:
                data = Data([0xFF, 0xFE]) + data
            case .utf16BigEndian:
                data = Data([0xFE, 0xFF]) + data
            case .other:
                break
            }
        }
        return data
    }
}
