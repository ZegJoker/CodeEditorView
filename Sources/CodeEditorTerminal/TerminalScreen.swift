import Foundation

@available(*, deprecated, message: "Legacy custom VT path (TER-N03). Use TerminalService + CodeEditorTerminalGhostty.")
public struct TerminalCell: Sendable, Hashable {
    public var character: Character
    public var fg: Int?  // SGR color index 0-255 or nil default
    public var bg: Int?
    public var bold: Bool
    public var underline: Bool
    public var inverse: Bool

    public static let empty = TerminalCell(
        character: " ", fg: nil, bg: nil, bold: false, underline: false, inverse: false)

    public init(
        character: Character,
        fg: Int? = nil,
        bg: Int? = nil,
        bold: Bool = false,
        underline: Bool = false,
        inverse: Bool = false
    ) {
        self.character = character
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.underline = underline
        self.inverse = inverse
    }
}

@available(*, deprecated, message: "Legacy custom VT path (TER-N03). Use TerminalService + CodeEditorTerminalGhostty.")
public struct TerminalHyperlink: Sendable, Hashable {
    public var id: String?
    public var uri: String
    public var row: Int
    public var colStart: Int
    public var colEnd: Int
}

/// Bounded terminal screen + scrollback model driven by ``VTParser`` actions.
///
/// - Important: Legacy custom-terminal path. Production architecture is
///   ``TerminalService`` + CodeEditorTerminalGhostty (TER-N03).
@available(*, deprecated, message: "Legacy custom VT path (TER-N03). Use TerminalService + CodeEditorTerminalGhostty.")
public final class TerminalScreen: @unchecked Sendable {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorCol: Int = 0
    public private(set) var altScreenActive = false
    public var autoWrap = true
    public var bracketedPaste = false
    public var applicationCursor = false

    private var primary: [[TerminalCell]]
    private var alternate: [[TerminalCell]]
    private var scrollback: [[TerminalCell]] = []
    public let maxScrollback: Int

    private var fg: Int?
    private var bg: Int?
    private var bold = false
    private var underline = false
    private var inverse = false
    private var savedCursor: (row: Int, col: Int)?
    private var currentLinkURI: String?
    public private(set) var hyperlinks: [TerminalHyperlink] = []
    private let parser = VTParser()
    private var utf8Partial = Data()

    public init(cols: Int = 80, rows: Int = 24, maxScrollback: Int = 5_000) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.maxScrollback = max(0, maxScrollback)
        self.primary = Self.blankBuffer(cols: self.cols, rows: self.rows)
        self.alternate = Self.blankBuffer(cols: self.cols, rows: self.rows)
    }

    private var grid: [[TerminalCell]] {
        get { altScreenActive ? alternate : primary }
        set {
            if altScreenActive { alternate = newValue } else { primary = newValue }
        }
    }

    public func feed(_ data: Data) {
        // Incremental UTF-8: prepend any partial, parse complete bytes
        var buffer = utf8Partial
        buffer.append(data)
        // Find complete UTF-8 prefix length
        let (complete, rest) = Self.splitCompleteUTF8(buffer)
        utf8Partial = rest
        for action in parser.push(complete) {
            apply(action)
        }
    }

    public func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(1, newCols)
        let nr = max(1, newRows)
        func resizeBuffer(_ buf: [[TerminalCell]]) -> [[TerminalCell]] {
            var out: [[TerminalCell]] = []
            for r in 0..<nr {
                if r < buf.count {
                    var row = buf[r]
                    if row.count < nc {
                        row.append(contentsOf: Array(repeating: .empty, count: nc - row.count))
                    } else if row.count > nc {
                        row = Array(row.prefix(nc))
                    }
                    out.append(row)
                } else {
                    out.append(Array(repeating: .empty, count: nc))
                }
            }
            return out
        }
        primary = resizeBuffer(primary)
        alternate = resizeBuffer(alternate)
        cols = nc
        rows = nr
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    public func cell(row: Int, col: Int) -> TerminalCell {
        let g = grid
        guard row >= 0, row < g.count, col >= 0, col < g[row].count else { return .empty }
        return g[row][col]
    }

    /// Visible viewport text (for a11y / copy).
    public func viewportText() -> String {
        grid.map { row in
            String(row.map(\.character)).trimmingCharacters(in: CharacterSet(charactersIn: " ").inverted.inverted)
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }

    public func accessibilityText(includeScrollback: Bool = false) -> String {
        if includeScrollback && !altScreenActive {
            let sb = scrollback.map { String($0.map(\.character)) }.joined(separator: "\n")
            let vp = viewportText()
            return sb.isEmpty ? vp : sb + "\n" + vp
        }
        return viewportText()
    }

    public func selectionText(row0: Int, col0: Int, row1: Int, col1: Int) -> String {
        let r0 = min(row0, row1)
        let r1 = max(row0, row1)
        var lines: [String] = []
        for r in r0...r1 {
            let cStart = r == r0 ? min(col0, cols - 1) : 0
            let cEnd = r == r1 ? min(col1, cols - 1) : cols - 1
            var s = ""
            for c in cStart...max(cStart, cEnd) {
                s.append(cell(row: r, col: c).character)
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    public func detectedURLs() -> [String] {
        let text = accessibilityText(includeScrollback: true)
        let pattern = try! NSRegularExpression(
            pattern: #"https?://[^\s<>\"']+"#,
            options: []
        )
        let ns = text as NSString
        let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    public var scrollbackLineCount: Int { scrollback.count }

    // MARK: - Apply

    private func apply(_ action: VTAction) {
        switch action {
        case .print(let ch):
            put(ch)
        case .execute(let b):
            switch b {
            case 0x08:  // BS
                cursorCol = max(0, cursorCol - 1)
            case 0x09:  // TAB
                cursorCol = min(cols - 1, ((cursorCol / 8) + 1) * 8)
            case 0x0A:  // LF
                lineFeed()
            case 0x0D:  // CR
                cursorCol = 0
            case 0x07:  // BEL
                break
            default:
                break
            }
        case .csi(let params, _, let final):
            handleCSI(params: params, final: final)
        case .osc(let s):
            handleOSC(s)
        case .esc:
            break
        case .invalid:
            break
        }
    }

    private func handleCSI(params: [Int], final: UInt8) {
        let p0 = params.first ?? 0
        let n = p0 == 0 ? 1 : p0
        switch final {
        case 0x41:  // CUU A
            cursorRow = max(0, cursorRow - n)
        case 0x42:  // CUD B
            cursorRow = min(rows - 1, cursorRow + n)
        case 0x43:  // CUF C
            cursorCol = min(cols - 1, cursorCol + n)
        case 0x44:  // CUB D
            cursorCol = max(0, cursorCol - n)
        case 0x48, 0x66:  // CUP H / HVP f
            let row = max(1, params.count > 0 ? (params[0] == 0 ? 1 : params[0]) : 1) - 1
            let col = max(1, params.count > 1 ? (params[1] == 0 ? 1 : params[1]) : 1) - 1
            cursorRow = min(rows - 1, row)
            cursorCol = min(cols - 1, col)
        case 0x4A:  // ED J
            eraseDisplay(mode: p0)
        case 0x4B:  // EL K
            eraseLine(mode: p0)
        case 0x6D:  // SGR m
            applySGR(params.isEmpty ? [0] : params)
        case 0x73:  // SCP s save
            savedCursor = (cursorRow, cursorCol)
        case 0x75:  // RCP u restore
            if let s = savedCursor {
                cursorRow = s.row
                cursorCol = s.col
            }
        case 0x68:  // SM h
            if params.contains(2004) { bracketedPaste = true }
            if params.contains(1) { applicationCursor = true }
            if params.contains(1049) { enterAlt() }
        case 0x6C:  // RM l
            if params.contains(2004) { bracketedPaste = false }
            if params.contains(1) { applicationCursor = false }
            if params.contains(1049) { leaveAlt() }
            if params.contains(7) { autoWrap = false }
        default:
            break
        }
    }

    private func handleOSC(_ s: String) {
        // OSC 8 ; ; uri ST hyperlink
        if s.hasPrefix("8;") {
            let parts = s.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 {
                let uri = String(parts[2])
                currentLinkURI = uri.isEmpty ? nil : uri
                if let uri = currentLinkURI {
                    hyperlinks.append(
                        TerminalHyperlink(
                            id: nil,
                            uri: uri,
                            row: cursorRow,
                            colStart: cursorCol,
                            colEnd: cursorCol
                        )
                    )
                }
            }
        }
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                fg = nil
                bg = nil
                bold = false
                underline = false
                inverse = false
            case 1: bold = true
            case 4: underline = true
            case 7: inverse = true
            case 22: bold = false
            case 24: underline = false
            case 27: inverse = false
            case 30...37: fg = p - 30
            case 39: fg = nil
            case 40...47: bg = p - 40
            case 49: bg = nil
            case 90...97: fg = p - 90 + 8
            case 100...107: bg = p - 100 + 8
            case 38:
                if i + 2 < params.count, params[i + 1] == 5 {
                    fg = params[i + 2]
                    i += 2
                }
            case 48:
                if i + 2 < params.count, params[i + 1] == 5 {
                    bg = params[i + 2]
                    i += 2
                }
            default:
                break
            }
            i += 1
        }
    }

    private func put(_ ch: Character) {
        let width = UnicodeWidth.displayWidth(ch)
        if cursorCol >= cols {
            if autoWrap {
                cursorCol = 0
                lineFeed()
            } else {
                cursorCol = cols - 1
            }
        }
        var g = grid
        if cursorRow >= g.count { return }
        if cursorCol < g[cursorRow].count {
            g[cursorRow][cursorCol] = TerminalCell(
                character: ch,
                fg: fg,
                bg: bg,
                bold: bold,
                underline: underline,
                inverse: inverse
            )
        }
        grid = g
        cursorCol += max(1, width)
        if cursorCol > cols { cursorCol = cols }
    }

    private func lineFeed() {
        if cursorRow >= rows - 1 {
            scrollUp()
        } else {
            cursorRow += 1
        }
    }

    private func scrollUp() {
        var g = grid
        let first = g.removeFirst()
        if !altScreenActive {
            scrollback.append(first)
            if scrollback.count > maxScrollback {
                scrollback.removeFirst(scrollback.count - maxScrollback)
            }
        }
        g.append(Array(repeating: .empty, count: cols))
        grid = g
    }

    private func eraseDisplay(mode: Int) {
        var g = grid
        switch mode {
        case 0:  // cursor to end
            for c in cursorCol..<cols { g[cursorRow][c] = .empty }
            for r in (cursorRow + 1)..<rows {
                g[r] = Array(repeating: .empty, count: cols)
            }
        case 1:  // start to cursor
            for r in 0..<cursorRow {
                g[r] = Array(repeating: .empty, count: cols)
            }
            for c in 0...cursorCol where c < cols { g[cursorRow][c] = .empty }
        default:  // 2 entire
            g = Self.blankBuffer(cols: cols, rows: rows)
        }
        grid = g
    }

    private func eraseLine(mode: Int) {
        var g = grid
        switch mode {
        case 0:
            for c in cursorCol..<cols { g[cursorRow][c] = .empty }
        case 1:
            for c in 0...cursorCol where c < cols { g[cursorRow][c] = .empty }
        default:
            g[cursorRow] = Array(repeating: .empty, count: cols)
        }
        grid = g
    }

    private func enterAlt() {
        altScreenActive = true
        alternate = Self.blankBuffer(cols: cols, rows: rows)
        cursorRow = 0
        cursorCol = 0
    }

    private func leaveAlt() {
        altScreenActive = false
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
    }

    private static func blankBuffer(cols: Int, rows: Int) -> [[TerminalCell]] {
        Array(repeating: Array(repeating: .empty, count: cols), count: rows)
    }

    private static func splitCompleteUTF8(_ data: Data) -> (Data, Data) {
        if data.isEmpty { return (Data(), Data()) }
        var i = data.count
        // walk back incomplete trailing sequence
        while i > 0 {
            let b = data[data.index(data.startIndex, offsetBy: i - 1)]
            if b < 0x80 { break }
            if b >> 6 == 0b10 {
                i -= 1
                continue
            }
            // lead byte
            let need: Int
            if b >> 5 == 0b110 {
                need = 2
            } else if b >> 4 == 0b1110 {
                need = 3
            } else if b >> 3 == 0b11110 {
                need = 4
            } else {
                break
            }
            let have = data.count - (i - 1)
            if have < need {
                let complete = data.prefix(i - 1)
                let rest = data.suffix(from: data.index(data.startIndex, offsetBy: i - 1))
                return (Data(complete), Data(rest))
            }
            break
        }
        return (data, Data())
    }
}

/// Minimal East Asian Width-ish display width for terminal cells.
public enum UnicodeWidth {
    public static func displayWidth(_ ch: Character) -> Int {
        guard let scalar = ch.unicodeScalars.first else { return 1 }
        let v = scalar.value
        // Combining marks
        if (v >= 0x0300 && v <= 0x036F) || (v >= 0x1AB0 && v <= 0x1AFF) || (v >= 0xFE00 && v <= 0xFE0F) {
            return 0
        }
        // Wide ranges (approx CJK + emoji)
        if (v >= 0x1100 && v <= 0x115F)
            || (v >= 0x2E80 && v <= 0xA4CF)
            || (v >= 0xAC00 && v <= 0xD7A3)
            || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0xFE10 && v <= 0xFE19)
            || (v >= 0xFE30 && v <= 0xFE6F)
            || (v >= 0xFF00 && v <= 0xFF60)
            || (v >= 0xFFE0 && v <= 0xFFE6)
            || (v >= 0x1F300 && v <= 0x1FAFF)
        {
            return 2
        }
        return 1
    }
}
