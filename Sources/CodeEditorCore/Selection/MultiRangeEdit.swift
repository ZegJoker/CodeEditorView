import Foundation

/// Helpers for multi-range selection edits and UTF-16 offset remapping after mutations.
public enum MultiRangeEdit {
    /// Overflow-safe end offset for an `NSRange` (DOC-N05). Returns `nil` on overflow/negatives.
    public static func endOffset(of range: NSRange) -> Int? {
        try? TextOffsetSemantics.utf16EndOffset(location: range.location, length: range.length)
    }

    /// Applies `delta` characters at `editLocation` to a single range.
    public static func remap(range: NSRange, editLocation: Int, delta: Int) -> NSRange {
        // Reject unusable arithmetic without trapping (DOC-N05).
        guard range.location >= 0, range.length >= 0,
            let rangeEnd = endOffset(of: range)
        else {
            return NSRange(location: 0, length: 0)
        }
        if rangeEnd <= editLocation {
            return range
        }
        if range.location >= editLocation {
            let (newLoc, overflow) = range.location.addingReportingOverflow(delta)
            if overflow || newLoc < 0 {
                return NSRange(location: 0, length: range.length)
            }
            return NSRange(location: newLoc, length: range.length)
        }
        // Edit intersects the range interior.
        let (newLength, overflow) = range.length.addingReportingOverflow(delta)
        if overflow || newLength < 0 {
            return NSRange(location: range.location, length: 0)
        }
        return NSRange(location: range.location, length: newLength)
    }

    public static func remap(ranges: [NSRange], editLocation: Int, delta: Int) -> [NSRange] {
        ranges.map { remap(range: $0, editLocation: editLocation, delta: delta) }
    }

    /// Normalizes ranges: clamp to document, sort, merge overlaps.
    public static func normalize(_ ranges: [NSRange], documentLength: Int) -> [NSRange] {
        let clamped = ranges.map { clamp($0, documentLength: documentLength) }
            .sorted { $0.location < $1.location }
        guard !clamped.isEmpty else {
            return [NSRange(location: min(0, documentLength), length: 0)]
        }
        var merged: [NSRange] = []
        for range in clamped {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            guard let lastEnd = endOffset(of: last), let rangeEnd = endOffset(of: range) else {
                merged.append(range)
                continue
            }
            if range.location <= lastEnd {
                let end = max(lastEnd, rangeEnd)
                let (length, overflow) = end.subtractingReportingOverflow(last.location)
                if overflow || length < 0 {
                    merged.append(range)
                } else {
                    merged[merged.count - 1] = NSRange(location: last.location, length: length)
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public static func clamp(_ range: NSRange, documentLength: Int) -> NSRange {
        guard documentLength >= 0 else {
            return NSRange(location: 0, length: 0)
        }
        // Overflow-safe clamp: never compute location+length before bounding (DOC-N05).
        let location = min(max(0, range.location), documentLength)
        let maxLen = documentLength - location
        let rawLen = max(0, range.length)
        let length = min(rawLen, maxLen)
        return NSRange(location: location, length: length)
    }

    /// After replacing `range` with `replacementUTF16Count` units, returns the caret after the edit.
    public static func caretAfterReplace(range: NSRange, replacementUTF16Count: Int) -> Int {
        let (end, overflow) = range.location.addingReportingOverflow(max(0, replacementUTF16Count))
        if overflow { return range.location }
        return end
    }
}
