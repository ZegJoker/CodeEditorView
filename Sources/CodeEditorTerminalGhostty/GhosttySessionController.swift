import Foundation
import CodeEditorTerminal

#if canImport(CGhosttyShim)
import CGhosttyShim
#endif

/// Actor-isolated Ghostty surface controller (TER-001).
///
/// Owns one terminal surface handle and feeds ordered bytes without loss.
/// When `ce_ghostty_is_linked()` is true, CGhosttyShim routes to libghostty;
/// otherwise the shim spool still provides lifecycle for adapter tests while
/// production workbench continues to use PTY + improved VT until link is set.
public actor GhosttySessionController {
    public let id: TerminalSessionID
    public private(set) var isLinkedToGhostty: Bool
    public private(set) var cols: Int
    public private(set) var rows: Int

    #if canImport(CGhosttyShim)
    private var surface: OpaquePointer?
    #endif

    public init(id: TerminalSessionID = TerminalSessionID(), cols: Int = 80, rows: Int = 24) {
        self.id = id
        self.cols = cols
        self.rows = rows
        #if canImport(CGhosttyShim)
        self.isLinkedToGhostty = ce_ghostty_is_linked()
        var cfg = ce_ghostty_config(cols: UInt32(cols), rows: UInt32(rows), font_size_milli: 12_000)
        self.surface = ce_ghostty_surface_create(&cfg)
        #else
        self.isLinkedToGhostty = false
        #endif
    }

    public func shutdown() {
        #if canImport(CGhosttyShim)
        if let surface {
            ce_ghostty_surface_destroy(surface)
            self.surface = nil
        }
        #endif
    }

    public func write(_ bytes: Data) throws {
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

    public func resize(cols: Int, rows: Int, widthPx: Int = 0, heightPx: Int = 0) throws {
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
}
