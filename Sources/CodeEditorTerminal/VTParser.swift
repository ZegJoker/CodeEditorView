import Foundation

/// Bounded VT/ANSI escape parser producing high-level actions for ``TerminalScreen``.
public enum VTAction: Sendable, Hashable {
    case print(Character)
    case execute(UInt8) // C0 controls
    case csi(params: [Int], intermediates: [UInt8], final: UInt8)
    case osc(String)
    case esc(UInt8)
    case invalid
}

public final class VTParser: @unchecked Sendable {
    public enum State: Sendable {
        case ground
        case escape
        case csiEntry
        case csiParam
        case csiIntermediate
        case oscString
        /// Seen ESC inside OSC; next byte must be `\\` (ST) to terminate.
        case oscStringMaybeST
        case ignore
    }

    private var state: State = .ground
    private var params: [Int] = []
    private var currentParam: Int?
    private var intermediates: [UInt8] = []
    private var oscBuffer = ""
    private var utf8Buffer: [UInt8] = []
    public let maxOSCLength: Int
    public let maxParams: Int

    public init(maxOSCLength: Int = 4096, maxParams: Int = 32) {
        self.maxOSCLength = maxOSCLength
        self.maxParams = maxParams
    }

    public func reset() {
        state = .ground
        params = []
        currentParam = nil
        intermediates = []
        oscBuffer = ""
        utf8Buffer = []
    }

    public func push(_ data: Data) -> [VTAction] {
        var actions: [VTAction] = []
        for byte in data {
            actions.append(contentsOf: consume(byte))
        }
        return actions
    }

    public func push(_ string: String) -> [VTAction] {
        push(Data(string.utf8))
    }

    private func consume(_ byte: UInt8) -> [VTAction] {
        switch state {
        case .ground:
            if byte == 0x1B {
                state = .escape
                return []
            }
            if byte < 0x20 {
                return [.execute(byte)]
            }
            // UTF-8 multi-byte start (TER-001 fix: never double-append leading byte).
            if byte < 0x80 {
                return [.print(Character(UnicodeScalar(byte)))]
            }
            // collectUTF8 owns buffer initialization when empty.
            return collectUTF8(byte)
        case .escape:
            if byte == 0x5B { // [
                state = .csiEntry
                params = []
                currentParam = nil
                intermediates = []
                return []
            }
            if byte == 0x5D { // ]
                state = .oscString
                oscBuffer = ""
                return []
            }
            state = .ground
            return [.esc(byte)]
        case .csiEntry, .csiParam:
            if byte >= 0x30 && byte <= 0x39 { // 0-9
                state = .csiParam
                let digit = Int(byte - 0x30)
                if let cur = currentParam {
                    currentParam = min(cur * 10 + digit, 9999)
                } else {
                    currentParam = digit
                }
                return []
            }
            if byte == 0x3B { // ;
                state = .csiParam
                params.append(currentParam ?? 0)
                currentParam = nil
                if params.count > maxParams {
                    state = .ignore
                }
                return []
            }
            if byte >= 0x20 && byte <= 0x2F { // intermediates
                state = .csiIntermediate
                intermediates.append(byte)
                return []
            }
            if byte >= 0x40 && byte <= 0x7E {
                if let cur = currentParam {
                    params.append(cur)
                    currentParam = nil
                } else if params.isEmpty {
                    // empty params ok
                }
                let action = VTAction.csi(params: params, intermediates: intermediates, final: byte)
                state = .ground
                params = []
                intermediates = []
                return [action]
            }
            if byte == 0x1B {
                state = .escape
                return []
            }
            // ignore bad
            return []
        case .csiIntermediate:
            if byte >= 0x20 && byte <= 0x2F {
                intermediates.append(byte)
                return []
            }
            if byte >= 0x40 && byte <= 0x7E {
                if let cur = currentParam {
                    params.append(cur)
                }
                let action = VTAction.csi(params: params, intermediates: intermediates, final: byte)
                state = .ground
                params = []
                intermediates = []
                currentParam = nil
                return [action]
            }
            state = .ground
            return [.invalid]
        case .oscString:
            if byte == 0x07 { // BEL terminator
                let s = oscBuffer
                state = .ground
                oscBuffer = ""
                return [.osc(s)]
            }
            if byte == 0x1B {
                // OSC string terminator is ESC \ (ST). Do not close on bare ESC —
                // wait for the following byte in a dedicated transition.
                state = .oscStringMaybeST
                return []
            }
            if oscBuffer.count < maxOSCLength {
                if let scalar = UnicodeScalar(UInt32(byte)), byte < 0x80 {
                    oscBuffer.append(Character(scalar))
                }
            }
            return []
        case .oscStringMaybeST:
            if byte == 0x5C { // ST = ESC \
                let s = oscBuffer
                state = .ground
                oscBuffer = ""
                return [.osc(s)]
            }
            // Not ST — ESC was data/noise; re-process as escape from ground semantics.
            state = .escape
            return consume(byte)
        case .ignore:
            if byte >= 0x40 && byte <= 0x7E {
                state = .ground
            }
            return []
        }
    }

    private var utf8Expected = 0

    private func collectUTF8(_ byte: UInt8) -> [VTAction] {
        if utf8Buffer.isEmpty {
            utf8Expected = utf8Needed(byte)
            if utf8Expected <= 1 {
                if byte < 0x80 {
                    return [.print(Character(UnicodeScalar(byte)))]
                }
                return [.print("\u{FFFD}")]
            }
            utf8Buffer = [byte]
            return []
        }
        utf8Buffer.append(byte)
        if utf8Buffer.count >= utf8Expected {
            let data = Data(utf8Buffer)
            utf8Buffer = []
            utf8Expected = 0
            if let s = String(data: data, encoding: .utf8), let ch = s.first {
                return [.print(ch)]
            }
            return [.print("\u{FFFD}")]
        }
        return []
    }

    private func utf8Needed(_ byte: UInt8) -> Int {
        if byte < 0x80 { return 1 }
        if byte >> 5 == 0b110 { return 2 }
        if byte >> 4 == 0b1110 { return 3 }
        if byte >> 3 == 0b11110 { return 4 }
        return 0
    }
}
