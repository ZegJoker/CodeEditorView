import CodeEditorCore
import CodeEditorDocuments
import Foundation

/// Versioned UTF-16 line-start index for fast LSP position conversion.
public struct LSPPositionMap: Sendable, Hashable {
    public let version: DocumentVersion
    /// UTF-16 offsets of each line start (line 0 = 0).
    public let lineStarts: [Int]
    public let utf16Length: Int

    public init(version: DocumentVersion, text: String) {
        self.version = version
        let ns = text as NSString
        self.utf16Length = ns.length
        var starts: [Int] = [0]
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            i += 1
            if ch == 0x0A {
                starts.append(i)
            } else if ch == 0x0D {
                if i < ns.length, ns.character(at: i) == 0x0A {
                    i += 1
                }
                starts.append(i)
            }
        }
        self.lineStarts = starts
    }

    public func position(utf16Offset: Int) -> (line: Int, character: Int) {
        let loc = min(max(0, utf16Offset), utf16Length)
        // Binary search last line start <= loc
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= loc {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return (lo, loc - lineStarts[lo])
    }

    public func utf16Offset(line: Int, character: Int) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let lineIndex = min(max(0, line), lineStarts.count - 1)
        let start = lineStarts[lineIndex]
        let next = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] : utf16Length
        // Line content ends before next start (or EOF). Exclude newline at end of line.
        let lineEnd = next
        let maxChar = max(0, lineEnd - start)
        let col = min(max(0, character), maxChar)
        return start + col
    }
}

/// Cache of position maps keyed by URI, invalidated on version change.
public actor LSPPositionMapCache {
    private var maps: [DocumentURI: LSPPositionMap] = [:]

    public init() {}

    public func map(for uri: DocumentURI, version: DocumentVersion, text: String) -> LSPPositionMap {
        if let existing = maps[uri], existing.version == version {
            return existing
        }
        let built = LSPPositionMap(version: version, text: text)
        maps[uri] = built
        return built
    }

    public func invalidate(uri: DocumentURI) {
        maps.removeValue(forKey: uri)
    }

    public func removeAll() {
        maps.removeAll()
    }
}
