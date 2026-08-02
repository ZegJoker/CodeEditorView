import Foundation

// MARK: - Stream policy types

/// Why a broadcast stream finished.
public enum StreamFinishReason: Sendable, Hashable {
    case completed
    case cancelled
    case failed(String)
}

/// Item delivered on a broadcast subscription (sequence, gap, or terminal finish).
public enum StreamItem<Element: Sendable>: Sendable {
    case value(Element)
    /// Missing sequences in the half-open range `[from, to)`.
    case gap(from: UInt64, to: UInt64)
    case finished(StreamFinishReason)
}

/// How much history a late subscriber receives at subscribe time.
public enum ReplayPolicy: Sendable, Hashable {
    case none
    case last(Int)
    case allBuffered
}

// MARK: - Hub

/// Multi-subscriber sequenced event hub with per-subscriber overflow policy (audit §22.3).
///
/// Each `subscribe` returns an independent stream. Producers publish once; all active
/// subscribers receive the event unless their own policy overflows (then `.gap` when requested).
public actor AsyncBroadcastHub<Event: Sendable> {
    public struct SubscriptionID: Hashable, Sendable {
        public let rawValue: UUID
        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    public enum OverflowPolicy: Sendable, Hashable {
        /// Drop oldest buffered items; optionally emit a gap marker covering dropped sequences.
        case dropOldest(capacity: Int, emitGap: Bool)
        /// Suspend the publisher until every subscriber has room (bounded by `maxPending`).
        case suspendProducer(maxPending: Int)
        /// Drop newest when full (no gap).
        case dropNewest(capacity: Int)
    }

    public struct Envelope: Sendable {
        public let sequence: UInt64
        public let event: Event
        public init(sequence: UInt64, event: Event) {
            self.sequence = sequence
            self.event = event
        }
    }

    private struct Subscriber {
        let id: SubscriptionID
        let policy: OverflowPolicy
        var continuation: AsyncStream<StreamItem<Envelope>>.Continuation
        /// Last sequence successfully delivered (0 = none).
        var lastDelivered: UInt64 = 0
        var finished = false
        /// Buffered envelopes waiting for dropOldest drain accounting.
        var pendingCount: Int = 0
        /// When set, the next successful delivery should emit `.gap` covering missed sequences.
        var pendingGapFrom: UInt64?
        /// Count of events dropped for this subscriber (telemetry).
        var droppedCount: Int = 0
    }

    private var subscribers: [SubscriptionID: Subscriber] = [:]
    private var nextSequence: UInt64 = 1
    private var history: [Envelope] = []
    private let maxHistory: Int
    private var finishReason: StreamFinishReason?
    private var isFinished: Bool { finishReason != nil }
    /// Suspended publishers waiting for capacity under `.suspendProducer`.
    private var producerWaiters: [CheckedContinuation<Void, Never>] = []

    public init(maxHistory: Int = 256) {
        self.maxHistory = max(0, maxHistory)
    }

    /// Register a subscriber inside the actor before returning (no registration race).
    public func subscribe(
        policy: OverflowPolicy = .dropOldest(capacity: 64, emitGap: true),
        replay: ReplayPolicy = .none
    ) -> AsyncStream<StreamItem<Envelope>> {
        let id = SubscriptionID()
        let capacity = Self.capacity(for: policy)

        // Capture continuation synchronously in the stream builder, then register on this actor.
        // dropOldest → bufferingNewest (discard oldest when full); dropNewest → bufferingOldest.
        let buffering: AsyncStream<StreamItem<Envelope>>.Continuation.BufferingPolicy = {
            switch policy {
            case .dropOldest, .suspendProducer:
                return .bufferingNewest(max(1, capacity))
            case .dropNewest:
                return .bufferingOldest(max(1, capacity))
            }
        }()
        var contBox: AsyncStream<StreamItem<Envelope>>.Continuation?
        let out = AsyncStream<StreamItem<Envelope>>(bufferingPolicy: buffering) { continuation in
            contBox = continuation
        }
        guard let cont = contBox else {
            return out
        }

        var sub = Subscriber(id: id, policy: policy, continuation: cont)
        cont.onTermination = { _ in
            Task { await self.removeSubscriber(id) }
        }

        // Replay history before any later publish is visible to this subscriber.
        let replayEnvelopes = Self.selectReplay(history: history, policy: replay)
        for env in replayEnvelopes {
            cont.yield(.value(env))
            sub.lastDelivered = env.sequence
            sub.pendingCount += 1
        }

        if let reason = finishReason {
            cont.yield(.finished(reason))
            cont.finish()
            sub.finished = true
        }

        subscribers[id] = sub
        return out
    }

    public func publish(_ event: Event) async {
        if isFinished { return }
        let seq = nextSequence
        nextSequence &+= 1
        let envelope = Envelope(sequence: seq, event: event)
        if maxHistory > 0 {
            history.append(envelope)
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
        }

        var ids = Array(subscribers.keys)
        for id in ids {
            await deliver(envelope, to: id)
        }
        // Resume any suspendProducer waiters if capacity freed.
        resumeProducerWaitersIfPossible()
        _ = ids
    }

    public func finish(_ reason: StreamFinishReason) {
        guard finishReason == nil else { return }
        finishReason = reason
        for id in subscribers.keys {
            guard var sub = subscribers[id], !sub.finished else { continue }
            if let gapFrom = sub.pendingGapFrom, gapFrom <= lastSequence {
                let to = lastSequence &+ 1
                if gapFrom < to {
                    sub.continuation.yield(.gap(from: gapFrom, to: to))
                }
                sub.pendingGapFrom = nil
            }
            sub.finished = true
            sub.continuation.yield(.finished(reason))
            sub.continuation.finish()
            subscribers[id] = sub
        }
        // Unblock suspended producers.
        let waiters = producerWaiters
        producerWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    public var subscriberCount: Int { subscribers.count }
    public var lastSequence: UInt64 { nextSequence == 0 ? 0 : nextSequence &- 1 }

    // MARK: - Private

    private func removeSubscriber(_ id: SubscriptionID) {
        subscribers[id] = nil
        resumeProducerWaitersIfPossible()
    }

    private func deliver(_ envelope: Envelope, to id: SubscriptionID) async {
        guard var sub = subscribers[id], !sub.finished else { return }

        switch sub.policy {
        case .dropOldest(let capacity, let emitGap):
            // Keep only the newest `capacity` values in the AsyncStream buffer.
            // When full, record a pending gap instead of yielding gap markers into the same buffer
            // (gap markers would otherwise displace the values they annotate).
            if sub.pendingCount >= capacity {
                sub.droppedCount += 1
                if emitGap {
                    let from = sub.pendingGapFrom ?? (sub.lastDelivered &+ 1)
                    sub.pendingGapFrom = from
                }
            }
            // Emit coalesced gap immediately before a value that will stay buffered.
            if let gapFrom = sub.pendingGapFrom, emitGap, gapFrom < envelope.sequence {
                // Reserve one slot: if at capacity, the gap yield itself discards an older value.
                _ = sub.continuation.yield(.gap(from: gapFrom, to: envelope.sequence))
                sub.pendingGapFrom = nil
            }
            let result = sub.continuation.yield(.value(envelope))
            switch result {
            case .terminated:
                sub.finished = true
            case .enqueued:
                sub.pendingCount = min(sub.pendingCount + 1, capacity)
                sub.lastDelivered = envelope.sequence
            case .dropped:
                sub.droppedCount += 1
                if emitGap {
                    let from = sub.pendingGapFrom ?? (sub.lastDelivered &+ 1)
                    sub.pendingGapFrom = from
                }
            @unknown default:
                sub.lastDelivered = envelope.sequence
            }
            subscribers[id] = sub

        case .dropNewest(let capacity):
            if sub.pendingCount >= capacity {
                sub.droppedCount += 1
                if case .dropNewest = sub.policy {
                    // keep oldest; drop this event
                }
                subscribers[id] = sub
                return
            }
            let result = sub.continuation.yield(.value(envelope))
            if case .enqueued = result {
                sub.pendingCount += 1
                sub.lastDelivered = envelope.sequence
            } else if case .dropped = result {
                sub.droppedCount += 1
            } else if case .terminated = result {
                sub.finished = true
            }
            subscribers[id] = sub

        case .suspendProducer(let maxPending):
            while true {
                guard var current = subscribers[id], !current.finished else { return }
                if current.pendingCount < maxPending {
                    let result = current.continuation.yield(.value(envelope))
                    switch result {
                    case .enqueued:
                        current.pendingCount += 1
                        current.lastDelivered = envelope.sequence
                        subscribers[id] = current
                        return
                    case .dropped:
                        // Should not drop under suspend; wait for drain.
                        subscribers[id] = current
                        await waitForProducerCapacity()
                    case .terminated:
                        current.finished = true
                        subscribers[id] = current
                        return
                    @unknown default:
                        return
                    }
                } else {
                    await waitForProducerCapacity()
                }
            }
        }
    }

    private func waitForProducerCapacity() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            producerWaiters.append(cont)
        }
    }

    private func resumeProducerWaitersIfPossible() {
        guard !producerWaiters.isEmpty else { return }
        let waiters = producerWaiters
        producerWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    private static func capacity(for policy: OverflowPolicy) -> Int {
        switch policy {
        case .dropOldest(let c, _): return max(1, c)
        case .dropNewest(let c): return max(1, c)
        case .suspendProducer(let c): return max(1, c)
        }
    }

    private static func selectReplay(history: [Envelope], policy: ReplayPolicy) -> [Envelope] {
        switch policy {
        case .none:
            return []
        case .last(let n):
            guard n > 0 else { return [] }
            return Array(history.suffix(n))
        case .allBuffered:
            return history
        }
    }
}

// MARK: - Subscription factory (process leases)

/// Factory that creates independent hub subscriptions without exposing the hub actor directly.
public struct BroadcastSubscriptionFactory<Event: Sendable>: Sendable {
    private let hub: AsyncBroadcastHub<Event>
    private let defaultPolicy: AsyncBroadcastHub<Event>.OverflowPolicy

    public init(
        hub: AsyncBroadcastHub<Event>,
        defaultPolicy: AsyncBroadcastHub<Event>.OverflowPolicy = .dropOldest(capacity: 64, emitGap: true)
    ) {
        self.hub = hub
        self.defaultPolicy = defaultPolicy
    }

    public func subscribe(
        policy: AsyncBroadcastHub<Event>.OverflowPolicy? = nil,
        replay: ReplayPolicy = .none
    ) async -> AsyncStream<StreamItem<AsyncBroadcastHub<Event>.Envelope>> {
        await hub.subscribe(policy: policy ?? defaultPolicy, replay: replay)
    }
}
