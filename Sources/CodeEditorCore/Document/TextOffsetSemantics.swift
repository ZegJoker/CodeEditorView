import Foundation

/// Canonical indexing model for CodeEditorView text.
///
/// - **Primary index:** UTF-16 code units (matches `NSString` / `NSRange` / AppKit selection).
/// - **UTF-8:** byte offsets into `String.utf8` for protocols that speak bytes (LSP often uses UTF-16;
///   Tree-sitter may use bytes depending on language mode).
/// - **Grapheme / caret:** extended grapheme cluster boundaries for caret movement that must not
///   split user-perceived characters.
///
/// Invalid inputs throw ``DocumentStoreError`` rather than silently producing wrong edits.
/// **Never** maps an invalid interior offset to end-of-document (DOC-003).
public enum TextOffsetSemantics: Sendable {
    /// How to resolve an offset that is not on the requested boundary.
    public enum BoundaryPolicy: Sendable, Equatable {
        /// Require an exact boundary; throw ``DocumentStoreError/notScalarBoundary`` or
        /// ``DocumentStoreError/notGraphemeBoundary`` otherwise.
        case exact
        /// Snap toward the start of the document.
        case roundDownToScalar
        /// Snap toward the end of the document.
        case roundUpToScalar
        /// Snap to the nearest extended grapheme cluster boundary (prefer left on ties).
        case roundToGrapheme
    }

    // MARK: - Validation

    /// Returns a half-open UTF-16 range, or throws if the range is unusable.
    ///
    /// Overlong ranges and negative lengths are **rejected** (not truncated).
    public static func validatedUTF16Range(
        _ range: NSRange,
        documentUTF16Length length: Int
    ) throws -> NSRange {
        guard length >= 0 else { throw DocumentStoreError.invalidRange(range) }
        guard range.location >= 0, range.location <= length else {
            throw DocumentStoreError.invalidRange(range)
        }
        guard range.length >= 0 else {
            throw DocumentStoreError.invalidRange(range)
        }
        guard range.location + range.length <= length else {
            throw DocumentStoreError.invalidRange(range)
        }
        return range
    }

    /// True when `offset` is a valid caret position in `[0, length]`.
    public static func isValidUTF16Offset(_ offset: Int, documentUTF16Length length: Int) -> Bool {
        offset >= 0 && offset <= length
    }

    // MARK: - UTF-16 ↔ UTF-8

    /// Converts a UTF-16 offset to a UTF-8 byte offset in `text`.
    ///
    /// Uses ``BoundaryPolicy/exact`` by default: offsets inside a surrogate pair throw
    /// ``DocumentStoreError/notScalarBoundary``. Never falls back to EOF.
    public static func utf8Offset(
        fromUTF16Offset utf16Offset: Int,
        in text: String,
        policy: BoundaryPolicy = .exact
    ) throws -> Int {
        let ns = text as NSString
        let utf16Len = ns.length
        guard isValidUTF16Offset(utf16Offset, documentUTF16Length: utf16Len) else {
            throw DocumentStoreError.invalidOffset(utf16Offset)
        }
        if utf16Offset == 0 { return 0 }
        if utf16Offset == utf16Len { return text.utf8.count }

        let stringIndex: String.Index
        do {
            stringIndex = try scalarIndex(atUTF16Offset: utf16Offset, in: text, policy: policy)
        } catch {
            throw error
        }
        guard let utf8Index = stringIndex.samePosition(in: text.utf8) else {
            throw DocumentStoreError.notScalarBoundary(utf16Offset)
        }
        return text.utf8.distance(from: text.utf8.startIndex, to: utf8Index)
    }

    /// Converts a UTF-8 byte offset to a UTF-16 offset in `text`.
    ///
    /// Uses ``BoundaryPolicy/exact`` by default: offsets inside a multi-byte scalar throw
    /// ``DocumentStoreError/notScalarBoundary``. Never falls back to EOF.
    public static func utf16Offset(
        fromUTF8Offset utf8Offset: Int,
        in text: String,
        policy: BoundaryPolicy = .exact
    ) throws -> Int {
        let utf8Count = text.utf8.count
        guard utf8Offset >= 0, utf8Offset <= utf8Count else {
            throw DocumentStoreError.invalidOffset(utf8Offset)
        }
        if utf8Offset == 0 { return 0 }
        if utf8Offset == utf8Count { return (text as NSString).length }

        guard
            let utf8Index = text.utf8.index(
                text.utf8.startIndex,
                offsetBy: utf8Offset,
                limitedBy: text.utf8.endIndex
            )
        else {
            throw DocumentStoreError.invalidOffset(utf8Offset)
        }
        if let stringIndex = String.Index(utf8Index, within: text) {
            guard let utf16Index = stringIndex.samePosition(in: text.utf16) else {
                throw DocumentStoreError.notScalarBoundary(utf8Offset)
            }
            return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
        }

        switch policy {
        case .exact:
            throw DocumentStoreError.notScalarBoundary(utf8Offset)
        case .roundDownToScalar:
            var i = utf8Index
            while i > text.utf8.startIndex {
                text.utf8.formIndex(before: &i)
                if let s = String.Index(i, within: text),
                    let u16 = s.samePosition(in: text.utf16)
                {
                    return text.utf16.distance(from: text.utf16.startIndex, to: u16)
                }
            }
            return 0
        case .roundUpToScalar, .roundToGrapheme:
            var i = utf8Index
            while i < text.utf8.endIndex {
                text.utf8.formIndex(after: &i)
                if let s = String.Index(i, within: text),
                    let u16 = s.samePosition(in: text.utf16)
                {
                    return text.utf16.distance(from: text.utf16.startIndex, to: u16)
                }
            }
            return (text as NSString).length
        }
    }

    // MARK: - Grapheme boundaries

    /// Nearest grapheme-cluster boundary at or before the UTF-16 offset (caret-left semantics).
    public static func graphemeBoundaryBefore(
        utf16Offset: Int,
        in text: String
    ) throws -> Int {
        let nsLen = (text as NSString).length
        guard isValidUTF16Offset(utf16Offset, documentUTF16Length: nsLen) else {
            throw DocumentStoreError.invalidOffset(utf16Offset)
        }
        if utf16Offset == 0 { return 0 }
        // Allow mid-scalar input for grapheme floor: round down to scalar first if needed.
        let idx = try scalarIndex(atUTF16Offset: utf16Offset, in: text, policy: .roundDownToScalar)
        let boundary = text.floorOfGrapheme(at: idx)
        return try utf16Distance(to: boundary, in: text)
    }

    /// Nearest grapheme-cluster boundary at or after the UTF-16 offset (caret-right semantics).
    public static func graphemeBoundaryAfter(
        utf16Offset: Int,
        in text: String
    ) throws -> Int {
        let nsLen = (text as NSString).length
        guard isValidUTF16Offset(utf16Offset, documentUTF16Length: nsLen) else {
            throw DocumentStoreError.invalidOffset(utf16Offset)
        }
        if utf16Offset == nsLen { return nsLen }
        let idx = try scalarIndex(atUTF16Offset: utf16Offset, in: text, policy: .roundUpToScalar)
        let boundary = text.ceilingOfGrapheme(at: idx)
        return try utf16Distance(to: boundary, in: text)
    }

    // MARK: - Line endings

    /// Normalizes all newlines in `text` to `ending`.
    public static func normalizeLineEndings(_ text: String, to ending: LineEnding) -> String {
        // First collapse CRLF → LF, then lone CR → LF, then map to target.
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        if ending == .lineFeed { return s }
        return s.replacingOccurrences(of: "\n", with: ending.rawValue)
    }

    // MARK: - Helpers (no EOF fallback on failure)

    /// Resolve a UTF-16 offset to a `String.Index` on a scalar boundary.
    ///
    /// - Important: On ``BoundaryPolicy/exact``, mid-surrogate offsets throw.
    ///   Never substitutes `text.endIndex` for an interior failure (DOC-003).
    public static func scalarIndex(
        atUTF16Offset offset: Int,
        in text: String,
        policy: BoundaryPolicy = .exact
    ) throws -> String.Index {
        let utf16 = text.utf16
        let utf16Len = utf16.count
        guard isValidUTF16Offset(offset, documentUTF16Length: utf16Len) else {
            throw DocumentStoreError.invalidOffset(offset)
        }
        if offset == 0 { return text.startIndex }
        if offset == utf16Len { return text.endIndex }

        guard
            let i = utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex)
        else {
            throw DocumentStoreError.invalidOffset(offset)
        }
        if let s = String.Index(i, within: text) {
            return s
        }
        // Interior offset is not a scalar boundary (e.g. mid-surrogate).
        switch policy {
        case .exact:
            throw DocumentStoreError.notScalarBoundary(offset)
        case .roundDownToScalar, .roundToGrapheme:
            // Walk UTF-16 left until a valid scalar String.Index exists.
            var o = offset - 1
            while o > 0 {
                if let j = utf16.index(utf16.startIndex, offsetBy: o, limitedBy: utf16.endIndex),
                    let s = String.Index(j, within: text)
                {
                    return s
                }
                o -= 1
            }
            return text.startIndex
        case .roundUpToScalar:
            var o = offset + 1
            while o < utf16Len {
                if let j = utf16.index(utf16.startIndex, offsetBy: o, limitedBy: utf16.endIndex),
                    let s = String.Index(j, within: text)
                {
                    return s
                }
                o += 1
            }
            return text.endIndex
        }
    }

    private static func utf16Distance(to index: String.Index, in text: String) throws -> Int {
        guard let utf16Index = index.samePosition(in: text.utf16) else {
            // Index must be scalar-aligned if produced by our helpers; treat as hard error.
            throw DocumentStoreError.notScalarBoundary(-1)
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }
}

extension String {
    fileprivate func floorOfGrapheme(at index: String.Index) -> String.Index {
        if index == startIndex { return startIndex }
        if index == endIndex { return endIndex }
        var i = index
        while i > startIndex {
            let prev = self.index(before: i)
            let range = self.rangeOfComposedCharacterSequence(at: prev)
            if range.contains(index) || range.upperBound == index {
                return range.lowerBound
            }
            if range.upperBound <= index {
                return range.upperBound > startIndex && range.upperBound < index
                    ? range.upperBound
                    : range.lowerBound
            }
            i = prev
        }
        return startIndex
    }

    fileprivate func ceilingOfGrapheme(at index: String.Index) -> String.Index {
        if index >= endIndex { return endIndex }
        let range = rangeOfComposedCharacterSequence(at: index)
        if range.lowerBound == index { return index }
        return range.upperBound
    }
}
