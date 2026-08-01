import Foundation
import TextStory

/// Platform-agnostic text document backed by `NSMutableAttributedString`.
///
/// Conforms to TextStory's `TextStoring` so mutations and inverse computation
/// share a single abstraction across layout, selection, and undo.
///
/// Content mutations advance ``version`` monotonically. Attribute-only updates
/// (syntax highlighting) do **not** change the version.
///
/// ## Concurrency (DOC-010 / §7.12)
/// Not `@MainActor` so it can satisfy TextStory's nonisolated `TextStoring`.
/// **Invariant:** treat as main-actor-affine mutable state. Cross-isolation
/// sharing must use ``snapshot()`` (`DocumentSnapshot` is `Sendable`).
///
/// Concurrent mutation is **undefined**. The type is intentionally **not**
/// `Sendable`. Callers that need cross-actor access must hop to the owning
/// isolation or use ``snapshot()`` only.
public final class DocumentStore: TextStoring {
    /// Attributed storage for paint paths. Package-visible so View can paint without
    /// making the buffer a long-lived public API surface.
    package private(set) var storage: NSMutableAttributedString
    public private(set) var lineEnding: LineEnding
    public var defaultAttributes: [NSAttributedString.Key: Any]

    /// Monotonic content generation. Starts at ``DocumentVersion/zero``.
    public private(set) var version: DocumentVersion = .zero

    public init(
        string: String = "",
        attributes: [NSAttributedString.Key: Any] = [:]
    ) {
        self.defaultAttributes = attributes
        self.storage = NSMutableAttributedString(string: string, attributes: attributes)
        self.lineEnding = LineEnding.detect(in: string)
    }

    // MARK: - Snapshot

    /// Immutable plain-text snapshot of the current content generation.
    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(version: version, text: fullString)
    }

    // MARK: - TextStoring

    public var length: Int { storage.length }

    public func substring(from range: NSRange) -> String? {
        guard let clamped = Self.clampedRange(range, documentLength: storage.length),
            clamped.length > 0
        else {
            // Empty-but-valid range (e.g. caret at end) → empty string; invalid → nil.
            if range.length == 0, range.location >= 0, range.location <= storage.length {
                return ""
            }
            return nil
        }
        // Use NSString — never hit NSAttributedString's throwing range API for plain text.
        return (storage.string as NSString).substring(with: clamped)
    }

    public func applyMutation(_ mutation: TextMutation) {
        applyMutationWithoutVersionBump(mutation)
        bumpVersion()
    }

    // MARK: - Convenience

    public var fullString: String { storage.string }

    public func attributedSubstring(from range: NSRange) -> NSAttributedString {
        // Never call Foundation's throwing `attributedSubstring(from:)` with an untrusted
        // range — out-of-bounds raises NSException and kills the process during draw
        // (seen after Enter on blank lines with fold/annotation/minimap enabled).
        let empty = NSAttributedString(string: "", attributes: defaultAttributes)
        guard let clamped = Self.clampedRange(range, documentLength: storage.length) else {
            return empty
        }
        if clamped.length == 0 {
            return empty
        }
        // Copy via NSString + attribute enumeration so we never pass a bad range into
        // NSAttributedString's range API even if storage mutates mid-flight.
        let ns = storage.string as NSString
        guard NSMaxRange(clamped) <= ns.length else { return empty }
        let plain = ns.substring(with: clamped)
        let result = NSMutableAttributedString(string: plain, attributes: defaultAttributes)
        storage.enumerateAttributes(in: clamped, options: []) { attrs, subrange, _ in
            let localLoc = subrange.location - clamped.location
            let localLen = subrange.length
            guard localLoc >= 0, localLen > 0, localLoc + localLen <= result.length else { return }
            result.addAttributes(attrs, range: NSRange(location: localLoc, length: localLen))
        }
        return result
    }

    /// Clamp `range` to `[0, documentLength)`. Returns `nil` if the range is unusable.
    private static func clampedRange(_ range: NSRange, documentLength docLen: Int) -> NSRange? {
        guard docLen >= 0 else { return nil }
        guard range.location >= 0, range.location <= docLen else { return nil }
        let maxLen = docLen - range.location
        // `range.length` can be negative / NSNotFound-sized; keep it non-negative.
        let rawLen = range.length
        let len = rawLen < 0 ? 0 : min(rawLen, maxLen)
        return NSRange(location: range.location, length: len)
    }

    public func setFullText(_ string: String) {
        storage = NSMutableAttributedString(string: string, attributes: defaultAttributes)
        lineEnding = LineEnding.detect(in: string)
        bumpVersion()
    }

    /// Override detected line ending (e.g. after load with explicit fidelity).
    public func setPreferredLineEnding(_ ending: LineEnding) {
        lineEnding = ending
    }

    public func setAttributes(_ attributes: [NSAttributedString.Key: Any], range: NSRange) {
        guard let clamped = Self.clampedRange(range, documentLength: storage.length),
            clamped.length > 0
        else { return }
        let range = clamped
        // Replace keys (especially foregroundColor) instead of only adding, so language
        // switches cannot leave mixed/stale attribute runs inside a token.
        storage.enumerateAttributes(in: range, options: []) { existing, subrange, _ in
            var merged = existing
            for (key, value) in attributes {
                merged[key] = value
            }
            // Preserve existing font when the caller does not supply a replacement
            // (avoids leaving bold/italic capture fonts only when a new font is set).
            if attributes[.font] == nil, let font = existing[.font] {
                merged[.font] = font
            }
            self.storage.setAttributes(merged, range: subrange)
        }
    }

    /// Resets the whole document to the current typing attributes (clears syntax colors).
    public func resetAttributesToDefaults() {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.setAttributes(defaultAttributes, range: full)
    }

    /// Builds a forward mutation and its inverse for the given replacement.
    public func makeEdit(in range: NSRange, replacement: String) -> TextEdit {
        let mutation = TextMutation(string: replacement, range: range, limit: length)
        let inverse = inverseMutation(for: mutation)
        return TextEdit(mutation: mutation, inverse: inverse)
    }

    /// Applies a replacement and returns the recorded edit (bumps version once).
    @discardableResult
    public func replaceCharacters(in range: NSRange, with replacement: String) -> TextEdit {
        let edit = makeEdit(in: range, replacement: replacement)
        applyMutationWithoutVersionBump(edit.mutation)
        bumpVersion()
        return edit
    }

    // MARK: - Versioned transactions

    /// Applies all changes as **one** content generation.
    ///
    /// ## Atomicity (DOC-001)
    /// All ranges are validated against the **pre-edit** snapshot before any mutation.
    /// Overlapping ranges are rejected. On any failure the document text, attributes,
    /// line ending, and version are unchanged.
    ///
    /// ## Ordering
    /// - `sortHighToLow == true` (default): changes are sorted by descending
    ///   `replacedRange.location`, then descending length, then stable insertion order
    ///   for equal-location insertions (deterministic multi-cursor edits).
    /// - `sortHighToLow == false`: applies `transaction.changes` in the given order
    ///   (required for undo/redo sequences that already encode application order).
    ///
    /// - Parameter expectedVersion: When set, throws ``DocumentStoreError/staleVersion`` if the
    ///   store's generation does not match (optimistic concurrency for multi-session hosts).
    @discardableResult
    public func apply(
        _ transaction: EditTransaction,
        sortHighToLow: Bool = true,
        expectedVersion: DocumentVersion? = nil
    ) throws -> AppliedEditTransaction {
        guard !transaction.changes.isEmpty else {
            throw DocumentStoreError.emptyTransaction
        }
        if let expectedVersion, expectedVersion != version {
            throw DocumentStoreError.staleVersion(expected: expectedVersion, actual: version)
        }

        let oldVersion = version
        let preLength = length

        // 1. Validate every range against the pre-edit snapshot (no mutation yet).
        var validated: [(index: Int, change: TextChange, range: NSRange)] = []
        validated.reserveCapacity(transaction.changes.count)
        for (index, change) in transaction.changes.enumerated() {
            let range = try TextOffsetSemantics.validatedUTF16Range(
                change.replacedRange.nsRange,
                documentUTF16Length: preLength
            )
            validated.append((index, change, range))
        }

        // 2. Reject overlapping ranges on the pre-edit coordinate space.
        let sortedForOverlap = validated.sorted {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.range.length < $1.range.length
        }
        var overlapping: [NSRange] = []
        for i in 1..<sortedForOverlap.count {
            let prev = sortedForOverlap[i - 1].range
            let cur = sortedForOverlap[i].range
            // Adjacent ranges (prev.end == cur.location) are allowed; true overlap is not.
            // Zero-length insertions at the same offset are allowed (deterministic order).
            let prevEnd = prev.location + prev.length
            let curEnd = cur.location + cur.length
            let bothEmpty = prev.length == 0 && cur.length == 0
            if !bothEmpty && cur.location < prevEnd && prev.location < curEnd {
                overlapping.append(prev)
                overlapping.append(cur)
            }
        }
        if !overlapping.isEmpty {
            throw DocumentStoreError.overlappingRanges(overlapping)
        }

        // 3. Determine application order.
        let ordered: [(index: Int, change: TextChange, range: NSRange)]
        if sortHighToLow {
            // High→low location; for equal location prefer longer replace first, then
            // original index ascending so equal-offset pure insertions keep declaration order.
            ordered = validated.sorted { a, b in
                if a.range.location != b.range.location {
                    return a.range.location > b.range.location
                }
                if a.range.length != b.range.length {
                    return a.range.length > b.range.length
                }
                return a.index < b.index
            }
        } else {
            ordered = validated
        }

        // 4. Build the complete mutation plan (edits + inverses) against the pre-edit store
        //    for high→low (ranges stay valid). For ordered sequences, re-validate as we go
        //    on a staging buffer so failure never touches the live store.
        let staging = NSMutableAttributedString(attributedString: storage)
        var textEdits: [TextEdit] = []
        textEdits.reserveCapacity(ordered.count)
        var stagedLength = staging.length

        for item in ordered {
            let range: NSRange
            if sortHighToLow {
                // Still valid against original; after prior high→low mutations lower
                // ranges are unchanged, so validate against staged length which equals
                // original for remaining pre-edit coordinates when applying high→low.
                range = try TextOffsetSemantics.validatedUTF16Range(
                    item.range,
                    documentUTF16Length: stagedLength
                )
            } else {
                range = try TextOffsetSemantics.validatedUTF16Range(
                    item.change.replacedRange.nsRange,
                    documentUTF16Length: stagedLength
                )
            }
            let prior = (staging.string as NSString).substring(with: range)
            let mutation = TextMutation(string: item.change.replacement, range: range, limit: stagedLength)
            let inverse = TextMutation(
                string: prior,
                range: NSRange(location: range.location, length: (item.change.replacement as NSString).length),
                limit: stagedLength - range.length + (item.change.replacement as NSString).length
            )
            staging.replaceCharacters(in: range, with: item.change.replacement)
            if !item.change.replacement.isEmpty, !defaultAttributes.isEmpty {
                let inserted = NSRange(
                    location: range.location,
                    length: (item.change.replacement as NSString).length
                )
                staging.addAttributes(defaultAttributes, range: inserted)
            }
            stagedLength = staging.length
            textEdits.append(TextEdit(mutation: mutation, inverse: inverse))
        }

        // 5. Commit staging → live storage in one step; bump version once.
        storage = staging
        lineEnding = LineEnding.detect(in: storage.string)
        bumpVersion()
        let newVersion = version

        // Inverse: undo last-applied first (reverse of application order).
        let inverseChanges: [TextChange] = textEdits.reversed().map { edit in
            TextChange(range: edit.inverse.range, replacement: edit.inverse.string)
        }
        let inverse = EditTransaction(
            id: UUID(),
            changes: inverseChanges,
            origin: transaction.origin
        )

        return AppliedEditTransaction(
            transaction: EditTransaction(
                id: transaction.id,
                changes: ordered.map(\.change),
                origin: transaction.origin
            ),
            oldVersion: oldVersion,
            newVersion: newVersion,
            inverse: inverse,
            textEdits: textEdits
        )
    }

    // MARK: - Private

    private func applyMutationWithoutVersionBump(_ mutation: TextMutation) {
        storage.replaceCharacters(in: mutation.range, with: mutation.string)
        if !mutation.string.isEmpty, !defaultAttributes.isEmpty {
            let inserted = NSRange(location: mutation.range.location, length: mutation.string.utf16.count)
            storage.addAttributes(defaultAttributes, range: inserted)
        }
    }

    private func bumpVersion() {
        version = version.advanced()
    }
}
