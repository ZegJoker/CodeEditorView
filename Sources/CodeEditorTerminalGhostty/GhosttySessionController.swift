import CodeEditorTerminal
import Foundation

#if canImport(CGhosttyShim)
    import CGhosttyShim
#endif

/// Ghostty integration level (TER-N02 / TER-N10).
public enum GhosttyIntegrationLevel: Int, Sendable, Hashable {
    /// Ghostty not linked — production path unavailable.
    case unavailable = 0
    /// libghostty-vt terminal state + host renderer (honest claim).
    case vtEngine = 1
    /// Full Ghostty Metal/CoreText surface (future).
    case fullSurface = 2
}

/// Structured key event for Ghostty encoder (TER-N04).
public struct GhosttyKeyEvent: Sendable, Hashable {
    public var key: UInt32
    public var mods: UInt16
    public var action: Action
    public var composing: Bool
    public var text: String?

    public enum Action: UInt8, Sendable, Hashable {
        case release = 0
        case press = 1
        case `repeat` = 2
    }

    public static let modShift: UInt16 = 1 << 0
    public static let modCtrl: UInt16 = 1 << 1
    public static let modAlt: UInt16 = 1 << 2
    public static let modSuper: UInt16 = 1 << 3

    public init(
        key: UInt32 = 0,
        mods: UInt16 = 0,
        action: Action = .press,
        composing: Bool = false,
        text: String? = nil
    ) {
        self.key = key
        self.mods = mods
        self.action = action
        self.composing = composing
        self.text = text
    }
}

/// Actor-isolated Ghostty surface controller (TER-N01 / TER-N02 / §21.4).
///
/// Owns one surface handle and feeds ordered raw bytes without loss.
/// Production default is `requireLinked: true` (REL-N08 / TER-N01 fail-closed).
public actor GhosttySessionController {
    public let id: TerminalSessionID
    public private(set) var isLinkedToGhostty: Bool
    public private(set) var integrationLevel: GhosttyIntegrationLevel
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var isDestroyed: Bool = false
    public private(set) var generation: UInt64 = 0

    #if canImport(CGhosttyShim)
        private var surface: OpaquePointer?
    #endif

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        cols: Int = 80,
        rows: Int = 24,
        requireLinked: Bool = true
    ) throws {
        self.id = id
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        #if canImport(CGhosttyShim)
            let linked = ce_ghostty_is_linked()
            self.isLinkedToGhostty = linked
            let levelRaw = Int(ce_ghostty_integration_level())
            self.integrationLevel = GhosttyIntegrationLevel(rawValue: levelRaw) ?? .unavailable
            if requireLinked && !linked {
                throw TerminalError.startFailed(
                    "Ghostty not linked (build with CODEEDITOR_GHOSTTY_LINKED=1 after scripts/build-ghostty.sh)"
                )
            }
            if !linked {
                // TER-N01: no fake surface when unlinked, even if requireLinked is false.
                throw TerminalError.startFailed(
                    "Ghostty surface unavailable: ce_ghostty_is_linked()==false (no production byte-spool)"
                )
            }
            var cfg = ce_ghostty_config(
                cols: UInt32(TerminalDimension.clampCells(cols)),
                rows: UInt32(TerminalDimension.clampCells(rows)),
                font_size_milli: 12_000
            )
            let created = ce_ghostty_surface_create(&cfg)
            self.surface = created
            if created == nil {
                throw TerminalError.startFailed("ce_ghostty_surface_create failed")
            }
        #else
            self.isLinkedToGhostty = false
            self.integrationLevel = .unavailable
            throw TerminalError.startFailed("CGhosttyShim unavailable")
        #endif
    }

    public func shutdown() {
        guard !isDestroyed else { return }
        isDestroyed = true
        #if canImport(CGhosttyShim)
            if let surface {
                ce_ghostty_surface_destroy(surface)
                self.surface = nil
            }
        #endif
    }

    /// Feed PTY→terminal bytes (ordered, no drop). Raw bytes only (TER-N05).
    public func write(_ bytes: Data) throws {
        guard !isDestroyed else { throw TerminalError.notRunning }
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            let rc = bytes.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return ce_ghostty_surface_write(surface, base, bytes.count)
            }
            if rc < 0 { throw TerminalError.startFailed("ghostty write failed") }
            generation = ce_ghostty_surface_generation(surface)
        #else
            throw TerminalError.startFailed("CGhosttyShim not available")
        #endif
    }

    /// Host keystrokes as raw UTF-8 text → encoded bytes for PTY write (legacy).
    public func keyInput(_ bytes: Data) throws -> Data {
        let text = String(decoding: bytes, as: UTF8.self)
        return try encodeKey(GhosttyKeyEvent(text: text.isEmpty ? nil : text))
    }

    /// Structured key encoding via Ghostty key encoder (TER-N04).
    public func encodeKey(_ event: GhosttyKeyEvent) throws -> Data {
        guard !isDestroyed else { throw TerminalError.notRunning }
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            var out = Data()
            try event.text.withCStringOrNil { utf8Ptr, utf8Len in
                var cEvent = ce_ghostty_key_event(
                    key: event.key,
                    mods: event.mods,
                    action: event.action.rawValue,
                    composing: event.composing ? 1 : 0,
                    utf8: utf8Ptr,
                    utf8_len: utf8Len
                )
                var buf = [UInt8](repeating: 0, count: 512)
                let n = ce_ghostty_surface_encode_key(surface, &cEvent, &buf, buf.count)
                if n < 0 { throw TerminalError.startFailed("ghostty encode_key failed") }
                if n > 0 {
                    out.append(contentsOf: buf.prefix(Int(n)))
                }
            }
            // Drain any additional spool (e.g. write_pty responses).
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = ce_ghostty_surface_read(surface, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf.prefix(Int(n)))
            }
            return out
        #else
            throw TerminalError.startFailed("CGhosttyShim not available")
        #endif
    }

    public func resize(cols: Int, rows: Int, widthPx: Int = 0, heightPx: Int = 0) throws {
        guard !isDestroyed else { throw TerminalError.notRunning }
        let c = Int(TerminalDimension.clampCells(cols))
        let r = Int(TerminalDimension.clampCells(rows))
        self.cols = c
        self.rows = r
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            let size = ce_ghostty_size(
                cols: UInt32(c),
                rows: UInt32(r),
                width_px: TerminalDimension.clampPixels(widthPx),
                height_px: TerminalDimension.clampPixels(heightPx)
            )
            if ce_ghostty_surface_resize(surface, size) != 0 {
                throw TerminalError.startFailed("ghostty resize failed")
            }
            generation = ce_ghostty_surface_generation(surface)
        #endif
    }

    /// Plain-text viewport from Ghostty terminal state (not raw spool, TER-N05/N06).
    public func snapshotUTF8() throws -> String {
        guard !isDestroyed else { return "" }
        #if canImport(CGhosttyShim)
            guard let surface else { return "" }
            var buf = [CChar](repeating: 0, count: 256 * 1024)
            let n = ce_ghostty_surface_snapshot_utf8(surface, &buf, buf.count)
            if n < 0 { throw TerminalError.startFailed("ghostty snapshot failed") }
            if n == 0 { return "" }
            let count = Int(n)
            return String(decoding: buf.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
            return ""
        #endif
    }

    public func currentGeneration() -> UInt64 {
        #if canImport(CGhosttyShim)
            if let surface {
                return ce_ghostty_surface_generation(surface)
            }
        #endif
        return generation
    }

    public static var shimABI: Int {
        #if canImport(CGhosttyShim)
            return Int(ce_ghostty_shim_abi())
        #else
            return 0
        #endif
    }

    public static var isLinked: Bool {
        #if canImport(CGhosttyShim)
            return ce_ghostty_is_linked()
        #else
            return false
        #endif
    }

    public static var currentIntegrationLevel: GhosttyIntegrationLevel {
        #if canImport(CGhosttyShim)
            return GhosttyIntegrationLevel(rawValue: Int(ce_ghostty_integration_level())) ?? .unavailable
        #else
            return .unavailable
        #endif
    }

    /// Honest product claim string (TER-N02) — never "Ghostty UI" for VT-only.
    public static var integrationClaim: String {
        switch currentIntegrationLevel {
        case .unavailable:
            return "Ghostty unavailable"
        case .vtEngine:
            return "Ghostty VT engine + CodeEditor renderer"
        case .fullSurface:
            return "Ghostty full surface"
        }
    }
}

// MARK: - Helpers

private extension Optional where Wrapped == String {
    func withCStringOrNil<T>(_ body: (UnsafePointer<CChar>?, Int) throws -> T) rethrows -> T {
        guard let self, !self.isEmpty else {
            return try body(nil, 0)
        }
        return try self.withCString { ptr in
            try body(ptr, self.utf8.count)
        }
    }
}
