import Foundation

#if canImport(CoreServices) && os(macOS)
    import CoreServices
#endif

/// Watch event delivered to the workspace file system.
public enum WorkspaceWatchSignal: Sendable, Hashable {
    case changed(rootID: WorkspaceRootID)
    /// Stream overflow or history gap — clients must full-rescan.
    case overflow(rootID: WorkspaceRootID)
    case stopped(rootID: WorkspaceRootID)
}

/// Recursive filesystem watch backend (WSP-005 / audit §8.6).
public protocol WorkspaceFileWatchBackend: Sendable {
    func start(
        rootID: WorkspaceRootID,
        url: URL,
        excludedNames: Set<String>,
        onEvent: @escaping @Sendable (WorkspaceWatchSignal) -> Void
    )
    func stop(rootID: WorkspaceRootID)
    func stopAll()
}

/// Shared sink for FSEvents → Sendable callbacks (macOS).
/// Lock-protected; `@unchecked Sendable` documents external synchronization.
final class WorkspaceWatchSink: @unchecked Sendable {
    static let shared = WorkspaceWatchSink()

    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (WorkspaceWatchSignal) -> Void] = [:]
    private var rootKeys: [WorkspaceRootID: UUID] = [:]

    private init() {}

    func register(
        rootID: WorkspaceRootID,
        handler: @escaping @Sendable (WorkspaceWatchSignal) -> Void
    ) -> UUID {
        let key = UUID()
        lock.lock()
        handlers[key] = handler
        rootKeys[rootID] = key
        lock.unlock()
        return key
    }

    func unregister(rootID: WorkspaceRootID) {
        lock.lock()
        if let key = rootKeys.removeValue(forKey: rootID) {
            handlers[key] = nil
        }
        lock.unlock()
    }

    func emit(_ signal: WorkspaceWatchSignal) {
        let rootID: WorkspaceRootID
        switch signal {
        case .changed(let id), .overflow(let id), .stopped(let id):
            rootID = id
        }
        lock.lock()
        let key = rootKeys[rootID]
        let handler = key.flatMap { handlers[$0] }
        lock.unlock()
        handler?(signal)
    }

    func unregisterAll() {
        lock.lock()
        handlers.removeAll()
        rootKeys.removeAll()
        lock.unlock()
    }
}

#if canImport(CoreServices) && os(macOS)

    /// FSEvents-backed recursive watcher with overflow → rescan signaling.
    public final class FSEventsWorkspaceWatcher: WorkspaceFileWatchBackend, @unchecked Sendable {
        private struct StreamState {
            var stream: FSEventStreamRef?
            var rootID: WorkspaceRootID
        }

        private let queue = DispatchQueue(label: "CodeEditorWorkspace.FSEvents")
        private let lock = NSLock()
        private var streams: [WorkspaceRootID: StreamState] = [:]

        public init() {}

        public func start(
            rootID: WorkspaceRootID,
            url: URL,
            excludedNames: Set<String>,
            onEvent: @escaping @Sendable (WorkspaceWatchSignal) -> Void
        ) {
            _ = excludedNames
            stop(rootID: rootID)
            _ = WorkspaceWatchSink.shared.register(rootID: rootID, handler: onEvent)

            let path = url.path as CFString
            let rootUUID = rootID.rawValue
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(rootUUID as NSUUID).toOpaque(),
                retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<NSUUID>.fromOpaque(info).release()
                },
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, info, numEvents, _, eventFlags, _ in
                guard let info else { return }
                let uuid = Unmanaged<NSUUID>.fromOpaque(info).takeUnretainedValue() as UUID
                let rootID = WorkspaceRootID(rawValue: uuid)
                var overflow = false
                if numEvents > 0 {
                    for i in 0..<Int(numEvents) {
                        let f = eventFlags[i]
                        if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                            || f & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                            || f & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
                        {
                            overflow = true
                        }
                    }
                }
                if overflow {
                    WorkspaceWatchSink.shared.emit(.overflow(rootID: rootID))
                } else {
                    WorkspaceWatchSink.shared.emit(.changed(rootID: rootID))
                }
            }

            guard
                let stream = FSEventStreamCreate(
                    kCFAllocatorDefault,
                    callback,
                    &context,
                    [path] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    0.25,
                    UInt32(
                        kFSEventStreamCreateFlagUseCFTypes
                            | kFSEventStreamCreateFlagFileEvents
                            | kFSEventStreamCreateFlagNoDefer
                    )
                )
            else {
                WorkspaceWatchSink.shared.emit(.overflow(rootID: rootID))
                return
            }

            lock.lock()
            streams[rootID] = StreamState(stream: stream, rootID: rootID)
            lock.unlock()

            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }

        public func stop(rootID: WorkspaceRootID) {
            lock.lock()
            let state = streams.removeValue(forKey: rootID)
            lock.unlock()
            WorkspaceWatchSink.shared.unregister(rootID: rootID)
            if let stream = state?.stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }

        public func stopAll() {
            lock.lock()
            let ids = Array(streams.keys)
            lock.unlock()
            for id in ids {
                stop(rootID: id)
            }
            WorkspaceWatchSink.shared.unregisterAll()
        }

        /// Test hook: simulate overflow for a root.
        public func simulateOverflow(rootID: WorkspaceRootID) {
            WorkspaceWatchSink.shared.emit(.overflow(rootID: rootID))
        }

        deinit {
            stopAll()
        }
    }

#else

    /// Non-macOS fallback: no recursive FSEvents; hosts must rescan on focus.
    public final class FSEventsWorkspaceWatcher: WorkspaceFileWatchBackend, @unchecked Sendable {
        public init() {}
        public func start(
            rootID: WorkspaceRootID,
            url: URL,
            excludedNames: Set<String>,
            onEvent: @escaping @Sendable (WorkspaceWatchSignal) -> Void
        ) {
            _ = url
            _ = excludedNames
            _ = WorkspaceWatchSink.shared.register(rootID: rootID, handler: onEvent)
            onEvent(.changed(rootID: rootID))
        }

        public func stop(rootID: WorkspaceRootID) {
            WorkspaceWatchSink.shared.unregister(rootID: rootID)
        }

        public func stopAll() {
            WorkspaceWatchSink.shared.unregisterAll()
        }

        public func simulateOverflow(rootID: WorkspaceRootID) {
            WorkspaceWatchSink.shared.emit(.overflow(rootID: rootID))
        }
    }

#endif

/// In-memory watch backend for tests (deterministic overflow / change injection).
public final class MockWorkspaceFileWatcher: WorkspaceFileWatchBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [WorkspaceRootID: @Sendable (WorkspaceWatchSignal) -> Void] = [:]
    public private(set) var startedRoots: [WorkspaceRootID] = []

    public init() {}

    public func start(
        rootID: WorkspaceRootID,
        url: URL,
        excludedNames: Set<String>,
        onEvent: @escaping @Sendable (WorkspaceWatchSignal) -> Void
    ) {
        _ = url
        _ = excludedNames
        lock.lock()
        handlers[rootID] = onEvent
        startedRoots.append(rootID)
        lock.unlock()
    }

    public func stop(rootID: WorkspaceRootID) {
        lock.lock()
        handlers[rootID] = nil
        startedRoots.removeAll { $0 == rootID }
        lock.unlock()
    }

    public func stopAll() {
        lock.lock()
        handlers.removeAll()
        startedRoots.removeAll()
        lock.unlock()
    }

    public func emit(_ signal: WorkspaceWatchSignal) {
        let rootID: WorkspaceRootID
        switch signal {
        case .changed(let id), .overflow(let id), .stopped(let id):
            rootID = id
        }
        lock.lock()
        let handler = handlers[rootID]
        lock.unlock()
        handler?(signal)
    }
}
