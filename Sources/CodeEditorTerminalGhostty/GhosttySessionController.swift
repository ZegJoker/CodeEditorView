import CodeEditorTerminal
import Foundation

#if canImport(CGhosttyShim)
    import CGhosttyShim
#endif

/// Actor-isolated Ghostty surface controller (TER-001 / §21.4).
///
/// Owns one surface handle and feeds ordered bytes without loss.
/// Production factories should set `requireLinked` and refuse unlinked mode.
public actor GhosttySessionController {
    public let id: TerminalSessionID
    public private(set) var isLinkedToGhostty: Bool
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var isDestroyed: Bool = false

    #if canImport(CGhosttyShim)
        private var surface: OpaquePointer?
    #endif

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        cols: Int = 80,
        rows: Int = 24,
        requireLinked: Bool = false
    ) throws {
        self.id = id
        self.cols = cols
        self.rows = rows
        #if canImport(CGhosttyShim)
            let linked = ce_ghostty_is_linked()
            self.isLinkedToGhostty = linked
            if requireLinked && !linked {
                throw TerminalError.startFailed("Ghostty not linked (build with CODEEDITOR_GHOSTTY_LINKED=1)")
            }
            var cfg = ce_ghostty_config(cols: UInt32(cols), rows: UInt32(rows), font_size_milli: 12_000)
            let created = ce_ghostty_surface_create(&cfg)
            self.surface = created
            if created == nil {
                throw TerminalError.startFailed("ce_ghostty_surface_create failed")
            }
        #else
            self.isLinkedToGhostty = false
            if requireLinked {
                throw TerminalError.startFailed("CGhosttyShim unavailable")
            }
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

    /// Feed PTY→terminal bytes (ordered, no drop).
    public func write(_ bytes: Data) throws {
        guard !isDestroyed else { throw TerminalError.notRunning }
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            let rc = bytes.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return ce_ghostty_surface_write(surface, base, bytes.count)
            }
            if rc < 0 { throw TerminalError.startFailed("ghostty write failed") }
        #else
            throw TerminalError.startFailed("CGhosttyShim not available")
        #endif
    }

    /// Host keystrokes → encoded bytes for PTY write.
    public func keyInput(_ bytes: Data) throws -> Data {
        guard !isDestroyed else { throw TerminalError.notRunning }
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            let rc = bytes.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return ce_ghostty_surface_key_input(surface, base, bytes.count)
            }
            if rc < 0 { throw TerminalError.startFailed("ghostty key input failed") }
            // Drain spool for host→PTY.
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = ce_ghostty_surface_read(surface, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf.prefix(Int(n)))
            }
            return out.isEmpty ? bytes : out
        #else
            return bytes
        #endif
    }

    public func resize(cols: Int, rows: Int, widthPx: Int = 0, heightPx: Int = 0) throws {
        guard !isDestroyed else { throw TerminalError.notRunning }
        self.cols = cols
        self.rows = rows
        #if canImport(CGhosttyShim)
            guard let surface else { throw TerminalError.notRunning }
            let size = ce_ghostty_size(
                cols: UInt32(cols),
                rows: UInt32(rows),
                width_px: UInt32(widthPx),
                height_px: UInt32(heightPx)
            )
            if ce_ghostty_surface_resize(surface, size) != 0 {
                throw TerminalError.startFailed("ghostty resize failed")
            }
        #endif
    }

    public func snapshotUTF8() throws -> String {
        guard !isDestroyed else { return "" }
        #if canImport(CGhosttyShim)
            guard let surface else { return "" }
            var buf = [CChar](repeating: 0, count: 256 * 1024)
            let n = ce_ghostty_surface_snapshot_utf8(surface, &buf, buf.count)
            if n < 0 { throw TerminalError.startFailed("ghostty snapshot failed") }
            return String(cString: buf)
        #else
            return ""
        #endif
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
}
