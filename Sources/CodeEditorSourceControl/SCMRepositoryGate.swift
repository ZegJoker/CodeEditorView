import Foundation

/// Per-repository operation coordinator (SCM-N03 / SCM-N05).
///
/// Reads wait until no mutation is active. Mutations and network ops are exclusive
/// (max concurrent mutations observed == 1). Callers acquire/release around work
/// that remains isolated on the provider actor.
public actor SCMRepositoryGate {
    public let id: UUID
    private var activeMutations = 0
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Telemetry for tests / diagnostics.
    public private(set) var maxConcurrentMutationsObserved: Int = 0

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public func acquire(_ category: SCMOperationCategory) async {
        switch category {
        case .read:
            await waitForNoMutation()
        case .mutate, .network:
            await beginMutation()
        }
    }

    public func release(_ category: SCMOperationCategory) {
        switch category {
        case .read:
            break
        case .mutate, .network:
            endMutation()
        }
    }

    private func waitForNoMutation() async {
        while activeMutations > 0 {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                mutationWaiters.append(cont)
            }
        }
    }

    private func beginMutation() async {
        while activeMutations > 0 {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                mutationWaiters.append(cont)
            }
        }
        activeMutations = 1
        maxConcurrentMutationsObserved = max(maxConcurrentMutationsObserved, activeMutations)
    }

    private func endMutation() {
        activeMutations = 0
        let waiters = mutationWaiters
        mutationWaiters.removeAll()
        for w in waiters { w.resume() }
    }
}
