import Foundation

/// Exact process exit taxonomy shared by pipe and PTY supervisors (CORE-N03 / TER-N07).
public enum SupervisedExitReason: Sendable, Hashable {
    case exited(code: Int32)
    case signalled(signal: Int32)
    case cancelled
    case spawnFailed(String)
    case timedOut(code: Int32)
}

/// Opaque PTY lease registered with ``ProcessSupervisor`` (TER-N07).
public struct PTYLeaseID: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Callback table for supervisor-owned PTY sessions so product modules can
/// register lifecycle without Core depending on CGhosttyShim.
public struct PTYSessionCallbacks: Sendable {
    public var cancel: @Sendable () async -> Void
    public var awaitExit: @Sendable () async -> SupervisedExitReason

    public init(
        cancel: @escaping @Sendable () async -> Void,
        awaitExit: @escaping @Sendable () async -> SupervisedExitReason
    ) {
        self.cancel = cancel
        self.awaitExit = awaitExit
    }
}

/// Supervised process lifecycle owner (audit §22.4).
///
/// Owns spawn validation, process-group establishment, multi-subscriber I/O,
/// nonblocking cancel with separate ``awaitExit``, and resource tracking.
/// Also tracks PTY leases registered by terminal transports (TER-N07).
public actor ProcessSupervisor {
    public let profile: PlatformCapabilityProfile
    private var leases: [UUID: ProcessHandle] = [:]
    private var ptyLeases: [PTYLeaseID: PTYSessionCallbacks] = [:]

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

    /// Register an externally spawned PTY session under supervisor lifecycle (TER-N07).
    @discardableResult
    public func registerPTY(_ callbacks: PTYSessionCallbacks) -> PTYLeaseID {
        let id = PTYLeaseID()
        ptyLeases[id] = callbacks
        Task { [weak self] in
            _ = await callbacks.awaitExit()
            await self?.releasePTY(id)
        }
        return id
    }

    /// Nonblocking PTY cancel (TER-N07).
    public func cancelPTY(_ id: PTYLeaseID) async {
        guard let cb = ptyLeases[id] else { return }
        await cb.cancel()
    }

    /// Await PTY reaping (TER-N07). Separate from ``cancelPTY``.
    public func awaitPTYExit(_ id: PTYLeaseID) async throws -> SupervisedExitReason {
        guard let cb = ptyLeases[id] else {
            throw ProcessServiceError.alreadyExited
        }
        return await cb.awaitExit()
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

    public var activeLeaseCount: Int { leases.count + ptyLeases.count }

    public var activePTYLeaseCount: Int { ptyLeases.count }

    private func release(_ id: UUID) {
        leases[id] = nil
    }

    private func releasePTY(_ id: PTYLeaseID) {
        ptyLeases[id] = nil
    }
}
