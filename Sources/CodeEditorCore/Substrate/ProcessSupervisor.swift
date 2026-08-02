import Foundation

/// Supervised process lifecycle owner (audit §22.4).
///
/// Owns spawn validation, process-group establishment, multi-subscriber I/O,
/// nonblocking cancel with separate ``awaitExit``, and resource tracking.
public actor ProcessSupervisor {
    public let profile: PlatformCapabilityProfile
    private var leases: [UUID: ProcessHandle] = [:]

    public init(profile: PlatformCapabilityProfile = .default()) {
        self.profile = profile
    }

    /// Spawn a process and register a lease. Returns a ``ProcessHandle`` with broadcast events.
    @discardableResult
    public func spawn(_ request: ProcessLaunchRequest) async throws -> ProcessHandle {
        let handle = try ProcessLaunchEngine.launch(request, profile: profile)
        leases[handle.id] = handle
        // Drop lease registration when process exits.
        Task { [weak self] in
            _ = await handle.awaitTermination()
            await self?.release(handle.id)
        }
        return handle
    }

    /// Compatibility with ``ProcessService/launch`` naming.
    public func launch(_ request: ProcessLaunchRequest) async throws -> ProcessHandle {
        try await spawn(request)
    }

    /// Request cancellation without waiting for death (CORE-N03).
    public func cancel(
        _ leaseID: UUID,
        escalation: EscalationPolicy = .termThenKill()
    ) async {
        guard let handle = leases[leaseID] else { return }
        handle.requestCancellation(escalation: escalation)
    }

    /// Wait for process reaping (CORE-N03). Separate from ``cancel``.
    public func awaitExit(_ leaseID: UUID) async throws -> ProcessExit {
        guard let handle = leases[leaseID] else {
            throw ProcessServiceError.alreadyExited
        }
        return await handle.awaitTermination()
    }

    public func handle(for leaseID: UUID) -> ProcessHandle? {
        leases[leaseID]
    }

    public var activeLeaseCount: Int { leases.count }

    private func release(_ id: UUID) {
        leases[id] = nil
    }
}
