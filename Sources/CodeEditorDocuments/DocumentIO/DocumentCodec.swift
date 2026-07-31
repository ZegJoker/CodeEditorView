import Foundation
import CodeEditorCore

/// Encode/decode document text with encoding, BOM, and line-ending policies.
public enum DocumentCodec: Sendable {
    public static func decode(_ data: Data) throws -> (text: String, encoding: DocumentEncoding, bom: Bool) {
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
        case .utf16, .other:
            break
        }
        guard let text = String(data: slice, encoding: encoding.stringEncoding)
                ?? String(data: slice, encoding: .utf8)
        else {
            throw DocumentIOError.encodingFailed
        }
        return (text, encoding, bom)
    }

    public static func encode(
        text: String,
        encoding: DocumentEncoding,
        lineEndingPolicy: LineEndingSavePolicy,
        bomPolicy: BOMPolicy
    ) throws -> Data {
        var body = text
        if case .convert(let ending) = lineEndingPolicy {
            body = TextOffsetSemantics.normalizeLineEndings(body, to: ending)
        }

        guard var data = body.data(using: encoding.stringEncoding) else {
            throw DocumentIOError.encodingFailed
        }

        if bomPolicy == .whenEncodingSupports {
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
