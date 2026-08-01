import Foundation

/// Deterministic CBOR encode/decode for ``CBORValue`` (RFC 8949 subset).
public enum CBORCodec {
    public static func encode(_ value: CBORValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    public static func decode(_ data: Data) throws -> CBORValue {
        var index = data.startIndex
        let value = try read(data, index: &index)
        if index != data.endIndex { throw CBORError.extraData }
        return value
    }

    // MARK: - Write

    private static func write(_ value: CBORValue, into data: inout Data) {
        switch value {
        case .null:
            data.append(0xF6)
        case .bool(let b):
            data.append(b ? 0xF5 : 0xF4)
        case .unsigned(let u):
            writeHeader(major: 0, argument: u, into: &data)
        case .negative(let n):
            let arg = UInt64(bitPattern: -1 - n)
            writeHeader(major: 1, argument: arg, into: &data)
        case .bytes(let bytes):
            writeHeader(major: 2, argument: UInt64(bytes.count), into: &data)
            data.append(bytes)
        case .text(let s):
            let utf = Data(s.utf8)
            writeHeader(major: 3, argument: UInt64(utf.count), into: &data)
            data.append(utf)
        case .array(let items):
            writeHeader(major: 4, argument: UInt64(items.count), into: &data)
            for item in items { write(item, into: &data) }
        case .map(let pairs):
            writeHeader(major: 5, argument: UInt64(pairs.count), into: &data)
            for (k, v) in pairs {
                write(k, into: &data)
                write(v, into: &data)
            }
        }
    }

    private static func writeHeader(major: UInt8, argument: UInt64, into data: inout Data) {
        let mi = major << 5
        if argument < 24 {
            data.append(mi | UInt8(argument))
        } else if argument <= UInt64(UInt8.max) {
            data.append(mi | 24)
            data.append(UInt8(argument))
        } else if argument <= UInt64(UInt16.max) {
            data.append(mi | 25)
            data.append(UInt8((argument >> 8) & 0xFF))
            data.append(UInt8(argument & 0xFF))
        } else if argument <= UInt64(UInt32.max) {
            data.append(mi | 26)
            for shift: UInt64 in [24, 16, 8, 0] {
                data.append(UInt8((argument >> shift) & 0xFF))
            }
        } else {
            data.append(mi | 27)
            for shift: UInt64 in [56, 48, 40, 32, 24, 16, 8, 0] {
                data.append(UInt8((argument >> shift) & 0xFF))
            }
        }
    }

    // MARK: - Read

    private static func read(_ data: Data, index: inout Data.Index) throws -> CBORValue {
        guard index < data.endIndex else { throw CBORError.truncated }
        let initial = data[index]
        index = data.index(after: index)
        let major = initial >> 5
        let additional = initial & 0x1F

        if major == 7 {
            switch additional {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw CBORError.unsupportedMajor(initial)
            }
        }
        if additional == 31 { throw CBORError.indefiniteNotSupported }

        let argument = try readArgument(additional, data: data, index: &index)

        switch major {
        case 0:
            return .unsigned(argument)
        case 1:
            if argument > UInt64(Int64.max) { throw CBORError.typeMismatch("negative overflow") }
            return .negative(-1 - Int64(argument))
        case 2:
            let count = try intCount(argument)
            let end = try advance(data, index: index, count: count)
            let slice = Data(data[index..<end])
            index = end
            return .bytes(slice)
        case 3:
            let count = try intCount(argument)
            let end = try advance(data, index: index, count: count)
            let slice = Data(data[index..<end])
            index = end
            guard let s = String(data: slice, encoding: .utf8) else { throw CBORError.invalidUTF8 }
            return .text(s)
        case 4:
            var items: [CBORValue] = []
            items.reserveCapacity(Int(min(argument, 10_000)))
            for _ in 0..<argument {
                items.append(try read(data, index: &index))
            }
            return .array(items)
        case 5:
            var pairs: [(CBORValue, CBORValue)] = []
            pairs.reserveCapacity(Int(min(argument, 10_000)))
            for _ in 0..<argument {
                let k = try read(data, index: &index)
                let v = try read(data, index: &index)
                pairs.append((k, v))
            }
            return .map(pairs)
        default:
            throw CBORError.unsupportedMajor(major)
        }
    }

    private static func intCount(_ argument: UInt64) throws -> Int {
        guard argument <= UInt64(Int.max) else { throw CBORError.truncated }
        return Int(argument)
    }

    private static func readArgument(_ additional: UInt8, data: Data, index: inout Data.Index) throws -> UInt64 {
        if additional < 24 { return UInt64(additional) }
        let len: Int
        switch additional {
        case 24: len = 1
        case 25: len = 2
        case 26: len = 4
        case 27: len = 8
        default: throw CBORError.unsupportedMajor(additional)
        }
        let end = try advance(data, index: index, count: len)
        var value: UInt64 = 0
        for b in data[index..<end] {
            value = (value << 8) | UInt64(b)
        }
        index = end
        return value
    }

    private static func advance(_ data: Data, index: Data.Index, count: Int) throws -> Data.Index {
        guard let end = data.index(index, offsetBy: count, limitedBy: data.endIndex),
            data.distance(from: index, to: end) == count
        else { throw CBORError.truncated }
        return end
    }
}
