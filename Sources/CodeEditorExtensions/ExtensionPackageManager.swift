import Foundation
import CodeEditorExtensionAPI

/// Host package lifecycle: install/enable/disable/update/rollback/uninstall + contribution snapshots.
public actor ExtensionPackageManager {
    public let installRoot: URL
    public private(set) var generation: UInt64 = 0
    public private(set) var snapshot: ExtensionContributionSnapshot = .empty

    private var packages: [ExtensionID: InstalledPackage] = [:]
    private var previousSnapshots: [ExtensionContributionSnapshot] = []
    private var continuation: AsyncStream<ExtensionContributionSnapshot>.Continuation?
    public let snapshots: AsyncStream<ExtensionContributionSnapshot>
    private let maxEventBuffer: Int

    public struct InstalledPackage: Sendable {
        public var plan: ValidatedContributionPlan
        public var enabled: Bool
        public var installPath: URL
        public var isDev: Bool
        public var previousPlan: ValidatedContributionPlan?
    }

    public init(installRoot: URL, maxEventBuffer: Int = 32) {
        self.installRoot = installRoot
        self.maxEventBuffer = max(4, maxEventBuffer)
        var cont: AsyncStream<ExtensionContributionSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(maxEventBuffer)) { cont = $0 }
        self.continuation = cont
        try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    @discardableResult
    public func install(from source: URL, asDev: Bool = false) throws -> ValidatedContributionPlan {
        let plan = try ExtensionPackageLoader.load(directory: source)
        if plan.hasErrors {
            throw ExtensionError.dataLoad("package has errors: \(plan.diagnostics.map(\.message).joined(separator: "; "))")
        }
        let dest: URL
        if asDev {
            dest = source
        } else {
            dest = installRoot.appendingPathComponent(plan.packageID.rawValue)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try copyPackage(from: source, to: dest)
        }
        var stored = plan
        stored.packageRoot = dest
        let previous = packages[plan.packageID]?.plan
        packages[plan.packageID] = InstalledPackage(
            plan: stored,
            enabled: true,
            installPath: dest,
            isDev: asDev,
            previousPlan: previous
        )
        rebuildSnapshot()
        return stored
    }

    public func enable(id: ExtensionID) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        pkg.enabled = true
        packages[id] = pkg
        rebuildSnapshot()
    }

    public func disable(id: ExtensionID) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        pkg.enabled = false
        packages[id] = pkg
        rebuildSnapshot()
    }

    public func update(id: ExtensionID, from source: URL) throws {
        let plan = try ExtensionPackageLoader.load(directory: source)
        guard plan.packageID == id else {
            throw ExtensionError.dataLoad("update id mismatch")
        }
        let previous = packages[id]
        let dest = installRoot.appendingPathComponent(id.rawValue)
        let staging = installRoot.appendingPathComponent(".\(id.rawValue).staging")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try copyPackage(from: source, to: staging)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: staging, to: dest)
        var stored = plan
        stored.packageRoot = dest
        packages[id] = InstalledPackage(
            plan: stored,
            enabled: previous?.enabled ?? true,
            installPath: dest,
            isDev: false,
            previousPlan: previous?.plan
        )
        rebuildSnapshot()
    }

    public func rollback(id: ExtensionID) throws {
        guard var pkg = packages[id], let previous = pkg.previousPlan else {
            throw ExtensionError.dataLoad("no previous generation for \(id.rawValue)")
        }
        pkg.plan = previous
        pkg.previousPlan = nil
        packages[id] = pkg
        rebuildSnapshot()
    }

    public func uninstall(id: ExtensionID) throws {
        guard let pkg = packages.removeValue(forKey: id) else {
            throw ExtensionError.notRegistered
        }
        if !pkg.isDev, FileManager.default.fileExists(atPath: pkg.installPath.path) {
            try? FileManager.default.removeItem(at: pkg.installPath)
        }
        rebuildSnapshot()
    }

    /// Dev reload: re-read package from path; shadows installed same id.
    public func reloadDev(path: URL) throws -> ValidatedContributionPlan {
        try install(from: path, asDev: true)
    }

    /// Recover by dropping packages whose install path is missing.
    public func recoverCorruptedState() {
        for (id, pkg) in packages {
            if !pkg.isDev, !FileManager.default.fileExists(atPath: pkg.installPath.path) {
                packages.removeValue(forKey: id)
            }
        }
        rebuildSnapshot()
    }

    public func installedPackages() -> [InstalledPackage] {
        Array(packages.values).sorted { $0.plan.packageID.rawValue < $1.plan.packageID.rawValue }
    }

    public func package(id: ExtensionID) -> InstalledPackage? {
        packages[id]
    }

    // MARK: - Snapshot

    private func rebuildSnapshot() {
        previousSnapshots.append(snapshot)
        if previousSnapshots.count > 8 {
            previousSnapshots.removeFirst(previousSnapshots.count - 8)
        }
        generation &+= 1
        // Dev packages shadow installed of same id via dictionary key (last install wins).
        let enabled = packages.values.filter(\.enabled).map(\.plan)
        snapshot = ImmutableContributionRegistry.build(packages: enabled, generation: generation)
        continuation?.yield(snapshot)
    }

    private func copyPackage(from source: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
    }
}
