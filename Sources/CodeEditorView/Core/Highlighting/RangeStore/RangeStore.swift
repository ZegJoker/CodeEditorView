import Foundation

/// Continuous runs of optional values over a document length (UTF-16 units).
///
/// Run-array implementation with coalescing; suitable for highlight capture layers.
public struct RangeStore<Element: RangeStoreElement>: Sendable {
    public struct Run: Equatable, Sendable {
        public var length: Int
        public var value: Element?

        public init(length: Int, value: Element?) {
            self.length = max(0, length)
            self.value = value
        }
    }

    private var runs: [Run]

    public var length: Int {
        runs.reduce(0) { $0 + $1.length }
    }

    public init(documentLength: Int) {
        let len = max(0, documentLength)
        runs = len == 0 ? [] : [Run(length: len, value: nil)]
    }

    // MARK: - Query

    public func runs(in range: NSRange) -> [Run] {
        guard range.length > 0, length > 0 else { return [] }
        let lower = max(0, range.location)
        let upper = min(length, range.location + range.length)
        guard lower < upper else { return [] }

        var result: [Run] = []
        var offset = 0
        for run in runs {
            let runStart = offset
            let runEnd = offset + run.length
            offset = runEnd

            let overlapStart = max(runStart, lower)
            let overlapEnd = min(runEnd, upper)
            if overlapStart < overlapEnd {
                result.append(Run(length: overlapEnd - overlapStart, value: run.value))
            }
            if runEnd >= upper { break }
        }
        return result
    }

    // MARK: - Mutation

    public mutating func set(value: Element?, for range: NSRange) {
        guard range.length > 0, length > 0 else { return }
        let lower = max(0, range.location)
        let upper = min(length, range.location + range.length)
        guard lower < upper else { return }
        // Always size the run to the *clamped* span so ranges past EOF never trap.
        set(runs: [Run(length: upper - lower, value: value)], for: NSRange(location: lower, length: upper - lower))
    }

    public mutating func set(runs newRuns: [Run], for range: NSRange) {
        guard range.length > 0, length > 0 else { return }
        let lower = max(0, range.location)
        let upper = min(length, range.location + range.length)
        guard lower < upper else { return }

        let span = upper - lower
        var expected = newRuns.reduce(0) { $0 + $1.length }
        // Tolerate caller mistakes (stale ranges after a full text replace) instead of crashing.
        var runsToApply = newRuns
        if expected != span {
            if expected == 0 {
                runsToApply = [Run(length: span, value: nil)]
            } else if expected > span {
                // Truncate from the end.
                var remaining = span
                var trimmed: [Run] = []
                for run in newRuns {
                    guard remaining > 0 else { break }
                    let take = min(run.length, remaining)
                    if take > 0 {
                        trimmed.append(Run(length: take, value: run.value))
                        remaining -= take
                    }
                }
                runsToApply = trimmed
            } else {
                // Pad with nil.
                runsToApply = newRuns + [Run(length: span - expected, value: nil)]
            }
            expected = runsToApply.reduce(0) { $0 + $1.length }
            guard expected == span else { return }
        }

        var rebuilt: [Run] = []
        var offset = 0
        var inserted = false

        for run in runs {
            let runStart = offset
            let runEnd = offset + run.length
            offset = runEnd

            // Before the target range
            if runEnd <= lower {
                appendCoalesced(run, to: &rebuilt)
                continue
            }
            // After the target range
            if runStart >= upper {
                if !inserted {
                    for r in runsToApply { appendCoalesced(r, to: &rebuilt) }
                    inserted = true
                }
                appendCoalesced(run, to: &rebuilt)
                continue
            }

            // Overlap: keep left tail
            if runStart < lower {
                appendCoalesced(Run(length: lower - runStart, value: run.value), to: &rebuilt)
            }
            // Insert new runs once
            if !inserted {
                for r in runsToApply { appendCoalesced(r, to: &rebuilt) }
                inserted = true
            }
            // Keep right tail
            if runEnd > upper {
                appendCoalesced(Run(length: runEnd - upper, value: run.value), to: &rebuilt)
            }
        }

        if !inserted {
            for r in runsToApply { appendCoalesced(r, to: &rebuilt) }
        }

        runs = rebuilt.isEmpty && length == 0 ? [] : rebuilt
        if runs.isEmpty, length == 0 {
            // keep empty
        }
    }

    /// Keeps store length in sync with a document edit (`delta = insertedUTF16 - removedUTF16`).
    public mutating func storageEdited(editRange: NSRange, delta: Int) {
        let location = max(0, min(editRange.location, length))
        let removed = max(0, min(editRange.length, length - location))
        if removed > 0 {
            delete(range: NSRange(location: location, length: removed))
        }
        let inserted = max(0, removed + delta)
        if inserted > 0 {
            insert(runs: [Run(length: inserted, value: nil)], at: location)
        }
    }

    public mutating func replaceDocumentLength(with newLength: Int) {
        let len = max(0, newLength)
        runs = len == 0 ? [] : [Run(length: len, value: nil)]
    }

    // MARK: - Internals

    private mutating func delete(range: NSRange) {
        guard range.length > 0 else { return }
        let lower = max(0, range.location)
        let upper = min(length, range.location + range.length)
        guard lower < upper else { return }

        var rebuilt: [Run] = []
        var offset = 0
        for run in runs {
            let runStart = offset
            let runEnd = offset + run.length
            offset = runEnd

            if runEnd <= lower || runStart >= upper {
                appendCoalesced(run, to: &rebuilt)
                continue
            }
            if runStart < lower {
                appendCoalesced(Run(length: lower - runStart, value: run.value), to: &rebuilt)
            }
            if runEnd > upper {
                appendCoalesced(Run(length: runEnd - upper, value: run.value), to: &rebuilt)
            }
        }
        runs = rebuilt
    }

    private mutating func insert(runs newRuns: [Run], at location: Int) {
        let loc = max(0, min(location, length))
        var rebuilt: [Run] = []
        var offset = 0
        var inserted = false

        if loc == 0 {
            for r in newRuns { appendCoalesced(r, to: &rebuilt) }
            inserted = true
        }

        for run in runs {
            let runStart = offset
            let runEnd = offset + run.length
            offset = runEnd

            if !inserted, loc <= runStart {
                for r in newRuns { appendCoalesced(r, to: &rebuilt) }
                inserted = true
                appendCoalesced(run, to: &rebuilt)
                continue
            }

            if !inserted, loc > runStart, loc < runEnd {
                let left = loc - runStart
                let right = runEnd - loc
                if left > 0 {
                    appendCoalesced(Run(length: left, value: run.value), to: &rebuilt)
                }
                for r in newRuns { appendCoalesced(r, to: &rebuilt) }
                inserted = true
                if right > 0 {
                    appendCoalesced(Run(length: right, value: run.value), to: &rebuilt)
                }
                continue
            }

            appendCoalesced(run, to: &rebuilt)
        }

        if !inserted {
            for r in newRuns { appendCoalesced(r, to: &rebuilt) }
        }
        runs = rebuilt
    }

    private func appendCoalesced(_ run: Run, to runs: inout [Run]) {
        guard run.length > 0 else { return }
        if let last = runs.last, last.value == run.value {
            runs[runs.count - 1].length += run.length
        } else {
            runs.append(run)
        }
    }
}
