import Foundation

// MARK: - Errors

public enum OneShotPromiseError: Error, Sendable, Equatable {
    case timedOut
    case cancelled
    case alreadyCompleted
}

// MARK: - Test / production clocks

/// Wall-clock based on `ContinuousClock`.
public struct ContinuousDeadlineClock: Sendable {
    public typealias Instant = ContinuousClock.Instant
    public typealias Duration = Swift.Duration

    private let clock = ContinuousClock()

    public init() {}

    public var now: Instant { clock.now }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try await clock.sleep(until: deadline, tolerance: tolerance)
    }
}

/// Deterministic clock for tests — advance manually to fire deadlines.
public actor TestDeadlineClock {
    public struct Instant: Comparable, Sendable, Hashable {
        public var offset: Swift.Duration
        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }

        public func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }
    }

    public typealias Duration = Swift.Duration

    private var current: Instant = Instant(offset: .zero)
    private var waiters: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []

    public init() {}

    public var now: Instant { current }

    public func advance(by duration: Swift.Duration) {
        current = Instant(offset: current.offset + duration)
        fireWaiters()
    }

    public func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        _ = tolerance
        if current >= deadline { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            waiters.append((deadline, cont))
        }
    }

    private func fireWaiters() {
        let ready = waiters.filter { $0.deadline <= current }
        waiters.removeAll { $0.deadline <= current }
        for w in ready {
            w.continuation.resume()
        }
    }
}

// MARK: - OneShotPromise

/// Exactly-once completion primitive. Safe for response-before-wait and wait-before-response.
///
/// Uses a lock so pending registration is synchronous (no actor hop race before transport await).
public final class OneShotPromise<Value: Sendable>: @unchecked Sendable {
    private enum State {
        case pending
        case completed(Result<Value, any Error>)
    }

    private struct WaiterID: Hashable {
        let rawValue: UUID
    }

    private let lock = NSLock()
    private var state: State = .pending
    private var waiters: [WaiterID: CheckedContinuation<Value, any Error>] = [:]

    public init() {}

    /// Completes the promise. Returns `true` if this call was the first completion.
    @discardableResult
    public func complete(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        switch state {
        case .completed:
            lock.unlock()
            return false
        case .pending:
            state = .completed(result)
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for (_, w) in pending {
                switch result {
                case .success(let v): w.resume(returning: v)
                case .failure(let e): w.resume(throwing: e)
                }
            }
            return true
        }
    }

    @discardableResult
    public func succeed(_ value: Value) -> Bool {
        complete(.success(value))
    }

    @discardableResult
    public func fail(_ error: any Error) -> Bool {
        complete(.failure(error))
    }

    /// Non-blocking snapshot of the completed result, if any (WASM-N09 request registration).
    public var resultIfCompleted: Result<Value, any Error>? {
        takeCompletedResult()
    }

    public func wait() async throws -> Value {
        try Task.checkCancellation()
        if let completed = takeCompletedResult() {
            return try completed.get()
        }

        let id = WaiterID(rawValue: UUID())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Value, any Error>) in
                self.installWaiter(id, cont)
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    nonisolated private func takeCompletedResult() -> Result<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        if case .completed(let result) = state {
            return result
        }
        return nil
    }

    nonisolated private func installWaiter(_ id: WaiterID, _ cont: CheckedContinuation<Value, any Error>) {
        lock.lock()
        switch state {
        case .completed(let result):
            lock.unlock()
            switch result {
            case .success(let v): cont.resume(returning: v)
            case .failure(let e): cont.resume(throwing: e)
            }
        case .pending:
            waiters[id] = cont
            lock.unlock()
        }
    }

    nonisolated private func cancelWaiter(_ id: WaiterID) {
        lock.lock()
        let cont = waiters.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }

    /// Wait until value, failure, cancellation, or continuous-clock deadline.
    public func wait(
        until deadline: ContinuousClock.Instant,
        clock: ContinuousDeadlineClock = ContinuousDeadlineClock()
    ) async throws -> Value {
        try await race(deadlineWork: {
            try await clock.sleep(until: deadline, tolerance: nil)
        })
    }

    /// Wait until value, failure, cancellation, or test-clock deadline.
    public func wait(
        until deadline: TestDeadlineClock.Instant,
        clock: TestDeadlineClock
    ) async throws -> Value {
        try await race(deadlineWork: {
            try await clock.sleep(until: deadline, tolerance: nil)
        })
    }

    private func race(deadlineWork: @escaping @Sendable () async throws -> Void) async throws -> Value {
        try Task.checkCancellation()
        if let completed = takeCompletedResult() {
            return try completed.get()
        }

        do {
            return try await withThrowingTaskGroup(of: OneShotRaceBox<Value>.self) { group in
                group.addTask {
                    OneShotRaceBox.value(try await self.wait())
                }
                group.addTask {
                    try await deadlineWork()
                    return OneShotRaceBox.timeout
                }
                let first = try await group.next()!
                group.cancelAll()
                while let extra = try? await group.next() {
                    _ = extra
                }
                switch first {
                case .value(let v):
                    return v
                case .timeout:
                    throw OneShotPromiseError.timedOut
                }
            }
        } catch is CancellationError {
            throw OneShotPromiseError.cancelled
        }
    }

    public var isCompleted: Bool {
        takeCompletedResult() != nil
    }
}

private enum OneShotRaceBox<Value: Sendable>: Sendable {
    case value(Value)
    case timeout
}

// MARK: - Deadline scheduler

public struct DeadlineScheduleID: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Monotonic deadline scheduler that fires actions exactly once (unless cancelled).
public final class DeadlineScheduler: @unchecked Sendable {
    private struct Entry {
        let action: @Sendable () async -> Void
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var entries: [DeadlineScheduleID: Entry] = [:]
    private let clock: ContinuousDeadlineClock

    public init(clock: ContinuousDeadlineClock = ContinuousDeadlineClock()) {
        self.clock = clock
    }

    @discardableResult
    public func schedule(
        deadline: ContinuousClock.Instant,
        action: @escaping @Sendable () async -> Void
    ) -> DeadlineScheduleID {
        let id = DeadlineScheduleID()
        let task = Task { [clock] in
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let actionToRun: (@Sendable () async -> Void)? = {
                self.lock.lock()
                let entry = self.entries.removeValue(forKey: id)
                self.lock.unlock()
                return entry?.action
            }()
            if let actionToRun {
                await actionToRun()
            }
        }
        lock.lock()
        entries[id] = Entry(action: action, task: task)
        lock.unlock()
        return id
    }

    public func cancel(_ id: DeadlineScheduleID) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        entry?.task?.cancel()
    }
}
