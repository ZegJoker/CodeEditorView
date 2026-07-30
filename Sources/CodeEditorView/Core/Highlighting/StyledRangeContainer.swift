import Foundation
import CodeEditorLanguageSupport

/// Merges highlight runs from multiple providers into a single style stream.
@MainActor
public final class StyledRangeContainer {
    public typealias ProviderID = Int

    private var stores: [ProviderID: RangeStore<CaptureName>] = [:]
    private var orderedProviderIDs: [ProviderID] = []
    private var documentLength: Int

    public var onStylesDidChange: ((NSRange) -> Void)?

    public init(documentLength: Int, providerIDs: [ProviderID] = []) {
        self.documentLength = max(0, documentLength)
        self.orderedProviderIDs = providerIDs
        for id in providerIDs {
            stores[id] = RangeStore(documentLength: self.documentLength)
        }
    }

    public func setProviders(_ providerIDs: [ProviderID]) {
        orderedProviderIDs = providerIDs
        var next: [ProviderID: RangeStore<CaptureName>] = [:]
        for id in providerIDs {
            next[id] = stores[id] ?? RangeStore(documentLength: documentLength)
        }
        stores = next
    }

    public func storageEdited(editRange: NSRange, delta: Int) {
        for id in orderedProviderIDs {
            stores[id]?.storageEdited(editRange: editRange, delta: delta)
        }
        documentLength = max(0, documentLength + delta)
        // Ensure stores track absolute length if delta bookkeeping drifts.
        for id in orderedProviderIDs {
            if let store = stores[id], store.length != documentLength {
                stores[id]?.replaceDocumentLength(with: documentLength)
            }
        }
    }

    public func replaceDocumentLength(_ length: Int, notify: Bool = true) {
        documentLength = max(0, length)
        for id in orderedProviderIDs {
            stores[id] = RangeStore(documentLength: documentLength)
        }
        if notify, documentLength > 0 {
            onStylesDidChange?(NSRange(location: 0, length: documentLength))
        }
    }

    public func setHighlights(_ highlights: [HighlightRange], forProvider id: ProviderID, in range: NSRange) {
        guard var store = stores[id] else { return }
        // Keep store length aligned with the document (text may have been replaced mid-refresh).
        if store.length != documentLength {
            store.replaceDocumentLength(with: documentLength)
        }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: store.length))
        guard clamped.length > 0 else {
            stores[id] = store
            return
        }
        // Clear range then apply captures.
        store.set(value: nil, for: clamped)
        for highlight in highlights {
            let intersection = NSIntersectionRange(highlight.range, clamped)
            guard intersection.length > 0 else { continue }
            // Prefer explicit capture; fall back to raw name mapping so tokens are not dropped.
            let capture = highlight.capture
                ?? highlight.rawCapture.flatMap { CaptureName.from(capture: $0) }
            guard let capture else { continue }
            store.set(value: capture, for: intersection)
        }
        stores[id] = store
        onStylesDidChange?(clamped)
    }

    /// Coalesced runs for `range`. Later providers win on overlap.
    public func runs(in range: NSRange) -> [RangeStore<CaptureName>.Run] {
        guard range.length > 0, documentLength > 0 else { return [] }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: documentLength))
        guard clamped.length > 0 else { return [] }

        // Start with plain nil runs, overlay providers in order.
        var base = RangeStore<CaptureName>(documentLength: clamped.length)
        // Work in local coordinates 0..<clamped.length
        for id in orderedProviderIDs {
            guard let store = stores[id] else { continue }
            let providerRuns = store.runs(in: clamped)
            var localOffset = 0
            for run in providerRuns {
                if let value = run.value {
                    base.set(
                        value: value,
                        for: NSRange(location: localOffset, length: run.length)
                    )
                }
                localOffset += run.length
            }
        }
        return base.runs(in: NSRange(location: 0, length: clamped.length))
    }
}
