import Foundation

/// Host-injected tooling surface kinds (no package dependency on LSP/Terminal/SCM).
public enum WorkbenchToolingKind: String, Sendable, Hashable, Codable, CaseIterable {
    case languageService
    case task
    case terminal
    case scm
    case search
    case extensionRuntime
    case custom
}

public enum WorkbenchToolingStatus: Sendable, Hashable, Codable {
    case ready
    case loading
    case unavailable(reason: String)
    case failed(message: String)

    public var isHealthy: Bool {
        if case .ready = self { return true }
        return false
    }

    public var message: String? {
        switch self {
        case .ready: return nil
        case .loading: return "Loading…"
        case .unavailable(let r): return r
        case .failed(let m): return m
        }
    }
}

/// Live tooling surface held by the workbench (protocol-neutral).
public struct WorkbenchToolingSurface: Identifiable, Sendable, Hashable {
    public var id: String
    public var kind: WorkbenchToolingKind
    public var title: String
    public var status: WorkbenchToolingStatus
    public var boundContributionID: String?
    public var canRetry: Bool

    public init(
        id: String,
        kind: WorkbenchToolingKind,
        title: String,
        status: WorkbenchToolingStatus = .ready,
        boundContributionID: String? = nil,
        canRetry: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.boundContributionID = boundContributionID
        self.canRetry = canRetry
    }
}

/// Codable snapshot for restoration (status messages only).
public struct WorkbenchToolingSurfaceSnapshot: Codable, Sendable, Hashable {
    public var id: String
    public var kind: WorkbenchToolingKind
    public var title: String
    public var statusKind: String
    public var statusMessage: String?
    public var boundContributionID: String?

    public init(from surface: WorkbenchToolingSurface) {
        self.id = surface.id
        self.kind = surface.kind
        self.title = surface.title
        self.boundContributionID = surface.boundContributionID
        switch surface.status {
        case .ready:
            statusKind = "ready"
            statusMessage = nil
        case .loading:
            statusKind = "loading"
            statusMessage = nil
        case .unavailable(let r):
            statusKind = "unavailable"
            statusMessage = r
        case .failed(let m):
            statusKind = "failed"
            statusMessage = m
        }
    }

    public func toSurface() -> WorkbenchToolingSurface {
        let status: WorkbenchToolingStatus
        switch statusKind {
        case "loading": status = .loading
        case "unavailable": status = .unavailable(reason: statusMessage ?? "unavailable")
        case "failed": status = .failed(message: statusMessage ?? "failed")
        default: status = .ready
        }
        return WorkbenchToolingSurface(
            id: id,
            kind: kind,
            title: title,
            status: status,
            boundContributionID: boundContributionID
        )
    }
}

/// Registry of tooling surfaces with isolation (one failure does not remove others).
@MainActor
public final class WorkbenchToolingSurfaceRegistry {
    private var surfaces: [String: WorkbenchToolingSurface] = [:]
    public private(set) var revision: UInt64 = 0
    public var retryHandler: (@MainActor (String) -> Void)?

    public init() {}

    public func upsert(_ surface: WorkbenchToolingSurface) {
        surfaces[surface.id] = surface
        revision &+= 1
    }

    public func setStatus(id: String, status: WorkbenchToolingStatus) {
        guard var s = surfaces[id] else { return }
        s.status = status
        surfaces[id] = s
        revision &+= 1
    }

    public func remove(id: String) {
        surfaces.removeValue(forKey: id)
        revision &+= 1
    }

    public func surface(id: String) -> WorkbenchToolingSurface? {
        surfaces[id]
    }

    public func all() -> [WorkbenchToolingSurface] {
        surfaces.values.sorted { $0.id < $1.id }
    }

    public func failed() -> [WorkbenchToolingSurface] {
        all().filter {
            if case .failed = $0.status { return true }
            if case .unavailable = $0.status { return true }
            return false
        }
    }

    public func retry(id: String) {
        retryHandler?(id)
    }

    public func snapshots() -> [WorkbenchToolingSurfaceSnapshot] {
        all().map(WorkbenchToolingSurfaceSnapshot.init(from:))
    }

    public func apply(snapshots: [WorkbenchToolingSurfaceSnapshot]) {
        for snap in snapshots {
            upsert(snap.toSurface())
        }
    }
}
