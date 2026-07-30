import Foundation

/// Helpers for multi-range selection edits and UTF-16 offset remapping after mutations.
public enum MultiRangeEdit {
    /// Applies `delta` characters at `editLocation` to a single range.
    public static func remap(range: NSRange, editLocation: Int, delta: Int) -> NSRange {
        if range.location + range.length <= editLocation {
            return range
        }
        if range.location >= editLocation {
            return NSRange(location: max(0, range.location + delta), length: range.length)
        }
        // Edit intersects the range interior.
        let newLength = max(0, range.length + delta)
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
            if range.location <= last.location + last.length {
                let end = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    public static func clamp(_ range: NSRange, documentLength: Int) -> NSRange {
        let location = min(max(0, range.location), documentLength)
        let maxLen = documentLength - location
        let length = min(max(0, range.length), maxLen)
        return NSRange(location: location, length: length)
    }

    /// After replacing `range` with `replacementUTF16Count` units, returns the caret after the edit.
    public static func caretAfterReplace(range: NSRange, replacementUTF16Count: Int) -> Int {
        range.location + replacementUTF16Count
    }
}
