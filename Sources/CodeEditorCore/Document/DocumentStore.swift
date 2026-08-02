import Foundation
import TextStory

/// Platform-agnostic text document backed by `NSMutableAttributedString`.
///
/// Conforms to TextStory's `TextStoring` so mutations and inverse computation
/// share a single abstraction across layout, selection, and undo.
///
/// Content mutations advance ``version`` monotonically and assign a new
/// ``contentState``. Attribute-only updates (syntax highlighting) do **not**
/// change the version or content state.
///
/// ## Concurrency (CORE-N01)
/// Owned and mutated exclusively on the main actor. Cross-isolation sharing
/// must use ``snapshot()`` (`DocumentSnapshot` is `Sendable`). Concurrent
/// mutation is undefined. The type is intentionally **not** `Sendable`.
///
/// Ownership is the **main actor** model: every mutating entry point calls
/// ``assertOwnership()`` (`dispatchPrecondition` on the main queue). The type
/// is not `@MainActor`-annotated so it can still satisfy TextStory's nonisolated
/// ``TextStoring`` protocol; callers remain responsible for hopping to main
/// before mutation (UI and ``TextDocument`` already do).
public final class DocumentStore: TextStoring {
    /// Enforced ownership model (CORE-N01).
    public static let ownershipModel: DocumentOwnershipModel = .mainActor

    /// Attributed storage for paint paths. Package-visible so View can paint without
    /// making the buffer a long-lived public API surface.
    package private(set) var storage: NSMutableAttributedString
    public private(set) var lineEnding: LineEnding
    public var defaultAttributes: [NSAttributedString.Key: Any]

    /// Monotonic content generation. Starts at ``DocumentVersion/zero``.
    public private(set) var version: DocumentVersion = .zero

    /// Logical content identity (DOC-N01). Undo restores a prior ID; versions stay monotonic.
    public private(set) var contentState: DocumentContentStateID

    public init(
        string: String = "",
        attributes: [NSAttributedString.Key: Any] = [:]
    ) {
        self.defaultAttributes = attributes
        self.storage = NSMutableAttributedString(string: string, attributes: attributes)
        self.lineEnding = LineEnding.detect(in: string)
        self.contentState = DocumentContentStateID()
    }

    // MARK: - Snapshot

    /// Immutable plain-text snapshot of the current content generation.
    public func snapshot() -> DocumentSnapshot {
        DocumentSnapshot(version: version, text: fullString, contentState: contentState)
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
        assertOwnership()
        applyMutationWithoutVersionBump(mutation)
        bumpVersionAndContentState()
    }

    /// Evaluates ownership without trapping (CORE-N01).
    ///
    /// Production mutations call ``assertOwnership()``, which traps on violation.
    public static func evaluateOwnership() -> DocumentOwnershipCheckResult {
        Thread.isMainThread ? .ok : .violated
    }

    /// Test-only probe: when set, ownership violations invoke this handler and
    /// **do not** process-trap, so tests can assert the fail-closed path without
    /// killing the suite. Production default is `nil` (always trap).
    ///
    /// - Important: Never set this in production code paths.
    /// Access is intentionally unlocked test-only state (single-threaded test setup).
    nonisolated(unsafe) package static var testOwnershipViolationHandler: (@Sendable () -> Void)?

    /// Fail closed if called off the owning isolation (CORE-N01).
    ///
    /// Uses `dispatchPrecondition(.onQueue(.main))` unless a test installs
    /// ``testOwnershipViolationHandler``.
    public func assertOwnership() {
        switch Self.evaluateOwnership() {
        case .ok:
            return
        case .violated:
            if let handler = Self.testOwnershipViolationHandler {
                handler()
                return
            }
            dispatchPrecondition(condition: .onQueue(.main))
        }
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
        assertOwnership()
        storage = NSMutableAttributedString(string: string, attributes: defaultAttributes)
        lineEnding = LineEnding.detect(in: string)
        bumpVersionAndContentState()
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
        assertOwnership()
        let edit = makeEdit(in: range, replacement: replacement)
        applyMutationWithoutVersionBump(edit.mutation)
        bumpVersionAndContentState()
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
    ///   `replacedRange.location`, then descending length. Equal-offset pure insertions
    ///   are applied in **reverse declaration order** so the visible result matches
    ///   declaration order (DOC-N03): inserting `"1"` then `"2"` at the same offset
    ///   yields `…12…`.
    /// - `sortHighToLow == false`: applies `transaction.changes` in the given order
    ///   (required for undo/redo sequences that already encode application order).
    ///
    /// - Parameter expectedVersion: When set, throws ``DocumentStoreError/staleVersion`` if the
    ///   store's generation does not match (optimistic concurrency for multi-session hosts).
    /// - Parameter restoreContentState: When set (undo/redo), assign this content state
    ///   instead of minting a new ID so dirty tracking can return to a savepoint (DOC-N01).
    @discardableResult
    public func apply(
        _ transaction: EditTransaction,
        sortHighToLow: Bool = true,
        expectedVersion: DocumentVersion? = nil,
        restoreContentState: DocumentContentStateID? = nil
    ) throws -> AppliedEditTransaction {
        assertOwnership()
        guard !transaction.changes.isEmpty else {
            throw DocumentStoreError.emptyTransaction
        }
        if let expectedVersion, expectedVersion != version {
            throw DocumentStoreError.staleVersion(expected: expectedVersion, actual: version)
        }

        let oldVersion = version
        let beforeState = contentState
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

        // 3. Coalesce equal-offset pure insertions into one declaration-order string (DOC-N03).
        let coalesced = Self.coalesceEqualOffsetInsertions(validated)

        // 4. Determine application order.
        let ordered: [(index: Int, change: TextChange, range: NSRange)]
        if sortHighToLow {
            // High→low location; for equal location prefer longer replace first, then index.
            ordered = coalesced.sorted { a, b in
                if a.range.location != b.range.location {
                    return a.range.location > b.range.location
                }
                if a.range.length != b.range.length {
                    return a.range.length > b.range.length
                }
                return a.index < b.index
            }
        } else {
            ordered = coalesced
        }

        // 5. Build the complete mutation plan on a staging buffer so failure never
        //    touches the live store.
        let staging = NSMutableAttributedString(attributedString: storage)
        var textEdits: [TextEdit] = []
        textEdits.reserveCapacity(ordered.count)
        var stagedLength = staging.length

        for item in ordered {
            let range: NSRange
            if sortHighToLow {
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

        // 6. Commit staging → live storage in one step; bump version once.
        storage = staging
        lineEnding = LineEnding.detect(in: storage.string)
        let afterState: DocumentContentStateID
        if let restoreContentState {
            contentState = restoreContentState
            afterState = restoreContentState
            version = version.advanced()
        } else {
            afterState = DocumentContentStateID()
            contentState = afterState
            version = version.advanced()
        }
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
            beforeState: beforeState,
            afterState: afterState,
            inverse: inverse,
            textEdits: textEdits
        )
    }

    // MARK: - Private

    /// Merge pure insertions that share the same pre-edit offset into one replacement
    /// whose string is the concatenation in **declaration order** (DOC-N03).
    private static func coalesceEqualOffsetInsertions(
        _ validated: [(index: Int, change: TextChange, range: NSRange)]
    ) -> [(index: Int, change: TextChange, range: NSRange)] {
        var groups: [Int: [(index: Int, change: TextChange, range: NSRange)]] = [:]
        var nonInsertOrder: [(index: Int, change: TextChange, range: NSRange)] = []
        for item in validated {
            if item.range.length == 0 {
                groups[item.range.location, default: []].append(item)
            } else {
                nonInsertOrder.append(item)
            }
        }
        var result = nonInsertOrder
        for (location, items) in groups {
            if items.count == 1 {
                result.append(items[0])
                continue
            }
            let sorted = items.sorted { $0.index < $1.index }
            let concatenated = sorted.map(\.change.replacement).joined()
            let first = sorted[0]
            let change = TextChange(
                range: NSRange(location: location, length: 0),
                replacement: concatenated
            )
            result.append((index: first.index, change: change, range: first.range))
        }
        // Preserve relative order by original index for the non-high-to-low path.
        return result.sorted { $0.index < $1.index }
    }

    private func applyMutationWithoutVersionBump(_ mutation: TextMutation) {
        storage.replaceCharacters(in: mutation.range, with: mutation.string)
        if !mutation.string.isEmpty, !defaultAttributes.isEmpty {
            let inserted = NSRange(location: mutation.range.location, length: mutation.string.utf16.count)
            storage.addAttributes(defaultAttributes, range: inserted)
        }
    }

    private func bumpVersionAndContentState() {
        version = version.advanced()
        contentState = DocumentContentStateID()
    }
}
