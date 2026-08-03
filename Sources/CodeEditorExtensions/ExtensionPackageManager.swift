import CodeEditorCore
import CodeEditorExtensionAPI
import Foundation

/// Host package lifecycle with **content-addressed immutable blobs**, durable journal, recovery,
/// and user-data outside package roots (EXT-N11…N16).
public actor ExtensionPackageManager {
    public let installRoot: URL
    public private(set) var generation: UInt64 = 0
    public private(set) var snapshot: ExtensionContributionSnapshot = .empty

    private var packages: [ExtensionID: InstalledPackage] = [:]
    private var previousSnapshots: [ExtensionContributionSnapshot] = []
    private var continuation: AsyncStream<ExtensionContributionSnapshot>.Continuation?
    public let snapshots: AsyncStream<ExtensionContributionSnapshot>
    /// EXT-N19: sequenced full snapshots via shared broadcast hub.
    private let snapshotHub = AsyncBroadcastHub<ExtensionContributionSnapshot>(maxHistory: 32)
    private let maxEventBuffer: Int
    private var telemetry: StoreTelemetrySink?
    private var revocation: RevocationListDocument = .init()
    /// Trusted Ed25519 authorities that may issue revocation lists (EXT-N15).
    private var revocationAuthorities: [RevocationAuthorityKey] = []
    /// Invoked with package IDs disabled by a newly applied revocation list (EXT-N15 driver stop).
    private var revokedDriverTerminator: (@Sendable ([ExtensionID]) async -> Void)?
    /// Last package IDs terminated/disabled by revocation (testable).
    public private(set) var lastRevokedPackageIDs: [ExtensionID] = []
    private var verifier: (any PackageVerifying)?
    private var installPolicy: ShippingInstallPolicy?
    /// Host environment used for loadable snapshot filtering (EXT-N16).
    public var hostEnvironment: HostEnvironment = .full
    /// Maximum age for revocation list freshness (EXT-N15).
    public var revocationMaxAge: TimeInterval = 7 * 24 * 3600

    public var packagesRoot: URL { installRoot.appendingPathComponent("packages", isDirectory: true) }
    public var stateRoot: URL { installRoot.appendingPathComponent("state", isDirectory: true) }
    public var dataRoot: URL { installRoot.appendingPathComponent("data", isDirectory: true) }
    public var telemetryRoot: URL { installRoot.appendingPathComponent("telemetry", isDirectory: true) }
    public var revocationRoot: URL { installRoot.appendingPathComponent("revocation", isDirectory: true) }
    public var cacheRoot: URL { installRoot.appendingPathComponent("cache", isDirectory: true) }
    public var downloadsRoot: URL { cacheRoot.appendingPathComponent("downloads", isDirectory: true) }
    /// Content-addressed immutable package bytes (EXT-N12).
    public var blobsRoot: URL {
        installRoot.appendingPathComponent("blobs/sha256", isDirectory: true)
    }
    public var installsMetaRoot: URL { installRoot.appendingPathComponent("installs", isDirectory: true) }
    public var activeRoot: URL { installRoot.appendingPathComponent("active", isDirectory: true) }
    public var transactionsRoot: URL { installRoot.appendingPathComponent("transactions", isDirectory: true) }
    /// Mutable host state outside immutable package content (EXT-N05).
    public var hostStateRoot: URL { installRoot.appendingPathComponent("host-state", isDirectory: true) }

    public struct InstalledPackage: Sendable {
        public var plan: ValidatedContributionPlan
        public var enabled: Bool
        public var installPath: URL
        public var isDev: Bool
        public var previousPlan: ValidatedContributionPlan?
        public var currentVersion: String
        public var previousVersion: String?
        public var state: PackageInstallState
        public var trustClass: ExtensionTrustClassDTO
        public var quarantined: Bool
        public var quarantineReason: String?
        public var publisher: String?
        /// Content digest binding immutable bytes (EXT-N13/N14).
        public var contentDigest: String?
        /// Relative store key under install root (never a free absolute path).
        public var storeKey: String?

        public var canActivate: Bool {
            enabled && !quarantined && state == .installed && contentDigest != nil
        }
    }

    /// Production initializer — **requires** verifier and install policy (EXT-004 fail-closed).
    public init(
        installRoot: URL,
        policy: ShippingInstallPolicy,
        verifier: any PackageVerifying,
        maxEventBuffer: Int = 32,
        telemetry: StoreTelemetrySink? = nil
    ) {
        self.installRoot = installRoot
        self.maxEventBuffer = max(4, maxEventBuffer)
        self.verifier = verifier
        self.telemetry = telemetry
        self.installPolicy = policy
        var cont: AsyncStream<ExtensionContributionSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(maxEventBuffer)) { cont = $0 }
        self.continuation = cont
        Self.ensureLayout(at: installRoot)
        if telemetry == nil {
            let tel =
                installRoot
                .appendingPathComponent("telemetry", isDirectory: true)
                .appendingPathComponent("migration-events.ndjson")
            self.telemetry = StoreTelemetrySink(fileURL: tel)
        }
    }

    /// Test-only initializer with optional verifier/policy. **Do not use in production hosts.**
    public static func insecureForTests(
        installRoot: URL,
        maxEventBuffer: Int = 32,
        verifier: (any PackageVerifying)? = nil,
        telemetry: StoreTelemetrySink? = nil,
        installPolicy: ShippingInstallPolicy? = nil
    ) -> ExtensionPackageManager {
        ExtensionPackageManager(
            installRoot: installRoot,
            maxEventBuffer: maxEventBuffer,
            verifier: verifier,
            telemetry: telemetry,
            installPolicy: installPolicy,
            allowMissingSecurity: true
        )
    }

    /// Legacy convenience retained for migration — prefer production `init(installRoot:policy:verifier:)`
    /// or ``insecureForTests``. Missing verifier/policy **fail closed** on install (EXT-004).
    public init(
        installRoot: URL,
        maxEventBuffer: Int = 32,
        verifier: (any PackageVerifying)? = nil,
        telemetry: StoreTelemetrySink? = nil,
        installPolicy: ShippingInstallPolicy? = nil
    ) {
        self.init(
            installRoot: installRoot,
            maxEventBuffer: maxEventBuffer,
            verifier: verifier,
            telemetry: telemetry,
            installPolicy: installPolicy,
            allowMissingSecurity: false
        )
    }

    private init(
        installRoot: URL,
        maxEventBuffer: Int,
        verifier: (any PackageVerifying)?,
        telemetry: StoreTelemetrySink?,
        installPolicy: ShippingInstallPolicy?,
        allowMissingSecurity: Bool
    ) {
        self.installRoot = installRoot
        self.maxEventBuffer = max(4, maxEventBuffer)
        self.verifier = verifier
        self.telemetry = telemetry
        self.installPolicy = installPolicy
        self.allowMissingSecurity = allowMissingSecurity
        var cont: AsyncStream<ExtensionContributionSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(maxEventBuffer)) { cont = $0 }
        self.continuation = cont
        Self.ensureLayout(at: installRoot)
        if telemetry == nil {
            let tel =
                installRoot
                .appendingPathComponent("telemetry", isDirectory: true)
                .appendingPathComponent("migration-events.ndjson")
            self.telemetry = StoreTelemetrySink(fileURL: tel)
        }
    }

    private var allowMissingSecurity: Bool = false

    private static func ensureLayout(at installRoot: URL) {
        for dir in [
            installRoot.appendingPathComponent("packages", isDirectory: true),
            installRoot.appendingPathComponent("state", isDirectory: true),
            installRoot.appendingPathComponent("data", isDirectory: true),
            installRoot.appendingPathComponent("telemetry", isDirectory: true),
            installRoot.appendingPathComponent("revocation", isDirectory: true),
            installRoot.appendingPathComponent("cache/downloads", isDirectory: true),
            installRoot.appendingPathComponent("blobs/sha256", isDirectory: true),
            installRoot.appendingPathComponent("installs", isDirectory: true),
            installRoot.appendingPathComponent("active", isDirectory: true),
            installRoot.appendingPathComponent("transactions", isDirectory: true),
            installRoot.appendingPathComponent("host-state", isDirectory: true),
        ] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Filesystem directory for an extension — hash key, never the raw ID (EXT-001).
    public func packageDirectory(for id: ExtensionID) -> URL {
        packagesRoot.appendingPathComponent(id.directoryKey, isDirectory: true)
    }

    /// Store-wide quarantine when durable trust state cannot be loaded safely (EXT-005 / §15.5).
    public private(set) var storeQuarantined: Bool = false
    public private(set) var storeQuarantineReason: String?

    /// Load durable state and revocation list (call once after init).
    /// Corrupt state enters **quarantined store** mode — never an empty permissive allow.
    public func bootstrap() {
        ensureLayout()
        do {
            try loadDurableState()
        } catch {
            storeQuarantined = true
            storeQuarantineReason = "corrupt durable state: \(error)"
            packages.removeAll()
            rebuildSnapshot()
        }
        do {
            try loadRevocationList()
        } catch {
            storeQuarantined = true
            let prior = storeQuarantineReason.map { $0 + "; " } ?? ""
            storeQuarantineReason = prior + "corrupt revocation list: \(error)"
            // Fail closed: clear revocation and deny activation until repaired.
            revocation = RevocationListDocument()
        }
    }

    /// Clear store quarantine after operator repair (re-runs bootstrap load).
    public func repairStoreBootstrap() throws {
        storeQuarantined = false
        storeQuarantineReason = nil
        packages.removeAll()
        try loadDurableState()
        try loadRevocationList()
    }

    public func setVerifier(_ verifier: (any PackageVerifying)?) {
        self.verifier = verifier
    }

    public func setTelemetry(_ sink: StoreTelemetrySink?) {
        self.telemetry = sink
    }

    public func setInstallPolicy(_ policy: ShippingInstallPolicy?) {
        self.installPolicy = policy
    }

    public func currentInstallPolicy() -> ShippingInstallPolicy? { installPolicy }

    /// Configure trusted revocation authorities (EXT-N15). Required for production `setRevocationList`.
    public func setRevocationAuthorities(_ keys: [RevocationAuthorityKey]) {
        revocationAuthorities = keys
    }

    public func revocationAuthorityKeys() -> [RevocationAuthorityKey] { revocationAuthorities }

    /// Register a handler that **immediately** stops running drivers for revoked packages (EXT-N15).
    /// `ExtensionHostOrchestrator.attachPackageManager` installs this to quarantine/stop instances.
    public func onPackagesRevoked(_ handler: @escaping @Sendable ([ExtensionID]) async -> Void) {
        revokedDriverTerminator = handler
    }

    /// Apply a **signed** revocation list (EXT-N15). Signature is verified fail-closed against
    /// ``setRevocationAuthorities``; monotonic sequence prevents rollback; revoked packages are
    /// disabled, removed from snapshots, and drivers are terminated via ``onPackagesRevoked``.
    public func setRevocationList(_ list: RevocationListDocument) async throws {
        // Structural + crypto fail-closed (no unsigned marketplace trust).
        do {
            try RevocationListCrypto.requireSignedStructure(list)
        } catch {
            throw ExtensionError.dataLoad("revocation list incomplete: \(error)")
        }
        if list.sequence > 0 || !list.entries.isEmpty {
            guard !revocationAuthorities.isEmpty else {
                throw ExtensionError.dataLoad(
                    "revocation authorities not configured (EXT-N15 fail closed)")
            }
            do {
                try list.verify(authorities: revocationAuthorities)
            } catch {
                throw ExtensionError.dataLoad("revocation signature invalid: \(error)")
            }
            guard list.isFresh(now: Date(), maxAge: revocationMaxAge) else {
                throw ExtensionError.dataLoad("revocation list is stale or expired (EXT-N15)")
            }
        }

        // EXT-N15: monotonic sequence when an epoch is in use.
        if revocation.sequence > 0 {
            var current = revocation
            try current.applyMonotonicUpdate(list)
            self.revocation = current
        } else {
            self.revocation = list
        }
        try persistRevocationList()

        // Immediately drop revoked packages from active snapshots and terminate drivers.
        var revoked: [ExtensionID] = []
        for (id, pkg) in packages {
            if revocation.entries.contains(where: {
                $0.matches(packageID: id.rawValue, version: pkg.currentVersion)
            }) {
                var p = pkg
                p.enabled = false
                packages[id] = p
                revoked.append(id)
            }
        }
        lastRevokedPackageIDs = revoked
        try persistDurableState()
        await rebuildSnapshotPublishing()
        if !revoked.isEmpty, let terminator = revokedDriverTerminator {
            await terminator(revoked)
        }
    }

    public func revocationList() -> RevocationListDocument { revocation }

    /// EXT-N19: subscribe to sequenced package contribution snapshots.
    public func packageSnapshotStream() async -> AsyncStream<
        StreamItem<AsyncBroadcastHub<ExtensionContributionSnapshot>.Envelope>
    > {
        await snapshotHub.subscribe(
            policy: .dropOldest(capacity: maxEventBuffer, emitGap: true),
            replay: .last(1)
        )
    }

    // MARK: - Lifecycle

    @discardableResult
    public func install(from source: URL, asDev: Bool = false) throws -> ValidatedContributionPlan {
        // EXT-N11: secure inventory + verify **before** activate/trust.
        let limits = PackageInventoryLimits.default
        let sourceInventory = try PackageInventoryBuilder.build(packageRoot: source, limits: limits)
        let sourceDigest = sourceInventory.packageSHA256

        var plan = try ExtensionPackageLoader.load(directory: source)
        if plan.hasErrors {
            throw ExtensionError.dataLoad(
                "package has errors: \(plan.diagnostics.map(\.message).joined(separator: "; "))")
        }
        plan.digest = sourceDigest

        // EXT-N17: bind declared executables from signed manifest only (never disk auto-declare).
        let declared = PackageInventoryBuilder.declaredExecutablePaths(
            runtimeKind: plan.manifestRuntimeKind,
            runtimeEntrypoint: plan.manifestRuntimeEntrypoint,
            packageRoot: source
        )
        // Re-build inventory with declaration binding so declared wasm/native are typed correctly.
        let boundInventory = try PackageInventoryBuilder.build(
            packageRoot: source, limits: limits, declaredExecutablePaths: declared)
        do {
            try PackageInventoryBuilder.assertNoUndeclaredExecutables(
                inventory: boundInventory, declaredPaths: declared
            )
            // Data-only runtimes must contain **zero** executables (not merely "declared.isEmpty").
            if plan.isDataOnlyRuntime {
                try PackageInventoryBuilder.assertDataOnlyHasNoExecutables(
                    inventory: boundInventory, declaredPaths: declared
                )
            }
        } catch let invErr as PackageInventoryError {
            throw ExtensionError.dataLoad(
                "executable content policy (EXT-N17): \(invErr)"
            )
        }

        let version = plan.version.description
        try assertNotRevoked(packageID: plan.packageID.rawValue, version: version)
        try assertRevocationFresh()
        try assertInstallPolicy(plan: plan, source: source, asDev: asDev)

        let verify = try runVerify(packageRoot: source)
        if verify.quarantined {
            throw ExtensionError.dataLoad(verify.error ?? "package quarantined at verify")
        }

        if asDev {
            packages[plan.packageID] = InstalledPackage(
                plan: {
                    var p = plan
                    p.packageRoot = source
                    return p
                }(),
                enabled: true,
                installPath: source,
                isDev: true,
                previousPlan: packages[plan.packageID]?.plan,
                currentVersion: version,
                previousVersion: packages[plan.packageID]?.currentVersion,
                state: .installed,
                trustClass: verify.trustClass,
                quarantined: false,
                quarantineReason: nil,
                publisher: verify.publisher,
                contentDigest: sourceDigest,
                storeKey: nil
            )
            try ensureUserDataDir(id: plan.packageID)
            try persistDurableState()
            rebuildSnapshot()
            record(
                .init(
                    event: "package.install", packageID: plan.packageID.rawValue, toVersion: version, success: true,
                    reason: "dev"))
            return plan
        }

        // EXT-N13: same-version reinstall safety.
        if let existing = packages[plan.packageID], existing.currentVersion == version, !existing.isDev {
            if let existingDigest = existing.contentDigest, existingDigest == sourceDigest {
                // Idempotent: return existing verified install only.
                return existing.plan
            }
            if existing.contentDigest != nil {
                throw ExtensionError.dataLoad(
                    "same-version reinstall with different content digest rejected (EXT-N13)"
                )
            }
        }

        let txID = UUID().uuidString
        let tx = InstallTransaction(
            id: txID,
            packageID: plan.packageID.rawValue,
            version: version,
            contentDigest: sourceDigest,
            phase: .started,
            createdAt: Date()
        )
        try writeTransaction(tx)

        let blobDir = blobsRoot.appendingPathComponent(sourceDigest, isDirectory: true)
        let staging = installRoot
            .appendingPathComponent("cache/staging-\(txID)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
        }

        do {
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try copyPackage(from: source, to: staging)

            // Re-verify staged tree + digest match (EXT-N11).
            let stagedInventory = try PackageInventoryBuilder.build(packageRoot: staging, limits: limits)
            guard stagedInventory.packageSHA256 == sourceDigest else {
                throw ExtensionError.dataLoad("staged digest mismatch")
            }
            let stagedVerify = try runVerify(packageRoot: staging)
            if stagedVerify.quarantined {
                throw ExtensionError.dataLoad(stagedVerify.error ?? "staged package failed verify")
            }

            var txVerify = tx
            txVerify.phase = .verified
            try writeTransaction(txVerify)

            if !FileManager.default.fileExists(atPath: blobDir.path) {
                try FileManager.default.createDirectory(
                    at: blobDir.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staging, to: blobDir)
            } else {
                // Blob already present (content-addressed); drop staging.
                try? FileManager.default.removeItem(at: staging)
            }
            try fsyncDirectory(blobDir.deletingLastPathComponent())

            // Legacy layout pointer for compatibility tools.
            let idRoot = packageDirectory(for: plan.packageID)
            let versionDir = idRoot.appendingPathComponent(version, isDirectory: true)
            try FileManager.default.createDirectory(at: idRoot, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: versionDir.path) {
                try FileManager.default.copyItem(at: blobDir, to: versionDir)
            }

            let previous = packages[plan.packageID]
            try writePointer(idRoot: idRoot, name: "current", version: version)
            if let prev = previous?.currentVersion, prev != version {
                try writePointer(idRoot: idRoot, name: "previous", version: prev)
            }

            // Installs metadata + active pointer (EXT-N12).
            let storeKey = "blobs/sha256/\(sourceDigest)"
            try writeInstallRecord(
                id: plan.packageID,
                version: version,
                digest: sourceDigest,
                trust: stagedVerify.trustClass,
                publisher: stagedVerify.publisher
            )
            try writeActivePointer(id: plan.packageID, version: version, digest: sourceDigest)

            // installPath stays on versioned layout for tooling compatibility; blob is content-addressed.
            var stored = plan
            stored.packageRoot = versionDir
            stored.digest = sourceDigest
            packages[plan.packageID] = InstalledPackage(
                plan: stored,
                enabled: previous?.enabled ?? true,
                installPath: versionDir,
                isDev: false,
                previousPlan: previous?.currentVersion == version ? previous?.previousPlan : previous?.plan,
                currentVersion: version,
                previousVersion: previous?.currentVersion == version
                    ? previous?.previousVersion : previous?.currentVersion,
                state: .installed,
                trustClass: stagedVerify.trustClass,
                quarantined: false,
                quarantineReason: nil,
                publisher: stagedVerify.publisher,
                contentDigest: sourceDigest,
                storeKey: storeKey
            )
            try ensureUserDataDir(id: plan.packageID)
            try ensureHostStateDir(id: plan.packageID)
            try persistDurableState()

            var txDone = txVerify
            txDone.phase = .committed
            try writeTransaction(txDone)

            rebuildSnapshot()
            record(
                .init(
                    event: previous == nil ? "package.install" : "package.update",
                    packageID: plan.packageID.rawValue,
                    fromVersion: previous?.currentVersion,
                    toVersion: version,
                    success: true
                ))
            return stored
        } catch {
            var txFail = tx
            txFail.phase = .rolledBack
            txFail.error = String(describing: error)
            try? writeTransaction(txFail)
            throw error
        }
    }

    public func enable(id: ExtensionID) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        if pkg.quarantined {
            throw ExtensionError.dataLoad("cannot enable quarantined package: \(pkg.quarantineReason ?? "quarantined")")
        }
        try assertNotRevoked(packageID: id.rawValue, version: pkg.currentVersion)
        pkg.enabled = true
        packages[id] = pkg
        try persistDurableState()
        rebuildSnapshot()
    }

    public func disable(id: ExtensionID) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        pkg.enabled = false
        packages[id] = pkg
        try persistDurableState()
        rebuildSnapshot()
    }

    public func update(id: ExtensionID, from source: URL) throws {
        let plan = try ExtensionPackageLoader.load(directory: source)
        guard plan.packageID == id else {
            throw ExtensionError.dataLoad("update id mismatch")
        }
        _ = try install(from: source, asDev: false)
    }

    public func rollback(id: ExtensionID) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        guard let prevVer = pkg.previousVersion, let previousPlan = pkg.previousPlan else {
            throw ExtensionError.dataLoad("no previous generation for \(id.rawValue)")
        }
        if pkg.isDev {
            // Dev: restore previous plan only if path still valid
            pkg.plan = previousPlan
            pkg.previousPlan = nil
            pkg.previousVersion = nil
            pkg.currentVersion = previousPlan.version.description
            packages[id] = pkg
            try persistDurableState()
            rebuildSnapshot()
            record(
                .init(
                    event: "package.rollback", packageID: id.rawValue, toVersion: prevVer, success: true, reason: "dev")
            )
            return
        }
        let idRoot = packageDirectory(for: id)
        let prevDir = idRoot.appendingPathComponent(prevVer, isDirectory: true)
        guard FileManager.default.fileExists(atPath: prevDir.path) else {
            throw ExtensionError.dataLoad("previous version directory missing: \(prevVer)")
        }
        // Atomic pointer flip
        let oldCurrent = pkg.currentVersion
        try writePointer(idRoot: idRoot, name: "current", version: prevVer)
        try writePointer(idRoot: idRoot, name: "previous", version: oldCurrent)

        var restored = previousPlan
        restored.packageRoot = prevDir
        pkg.plan = restored
        pkg.installPath = prevDir
        pkg.previousPlan = nil
        pkg.previousVersion = nil
        pkg.currentVersion = prevVer
        pkg.state = .installed
        packages[id] = pkg
        try persistDurableState()
        rebuildSnapshot()
        record(
            .init(
                event: "package.rollback",
                packageID: id.rawValue,
                fromVersion: oldCurrent,
                toVersion: prevVer,
                success: true
            ))
    }

    public func uninstall(id: ExtensionID, purgeData: Bool = false) throws {
        guard let pkg = packages.removeValue(forKey: id) else {
            throw ExtensionError.notRegistered
        }
        if !pkg.isDev {
            let idRoot = packageDirectory(for: id)
            if FileManager.default.fileExists(atPath: idRoot.path) {
                try FileManager.default.removeItem(at: idRoot)
            }
        }
        if purgeData {
            let data = userDataDir(id: id)
            if FileManager.default.fileExists(atPath: data.path) {
                try FileManager.default.removeItem(at: data)
            }
        }
        try persistDurableState()
        rebuildSnapshot()
        record(
            .init(
                event: "package.uninstall", packageID: id.rawValue, success: true,
                reason: purgeData ? "purge" : "keep-data"))
    }

    public func reloadDev(path: URL) throws -> ValidatedContributionPlan {
        try install(from: path, asDev: true)
    }

    /// Recover interrupted staging and reconcile durable state with filesystem.
    /// EXT-009: never activate a generation that fails live re-verify.
    public func recoverCorruptedState() {
        // Remove leftover staging dirs
        if let idDirs = try? FileManager.default.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for idDir in idDirs {
                guard
                    let children = try? FileManager.default.contentsOfDirectory(
                        at: idDir,
                        includingPropertiesForKeys: nil
                    )
                else { continue }
                for child in children where child.lastPathComponent.hasPrefix(".staging-") {
                    try? FileManager.default.removeItem(at: child)
                }
            }
        }

        // Reconcile known packages against current/previous pointers.
        for (id, pkg) in packages {
            if !pkg.isDev {
                let pathExists = FileManager.default.fileExists(atPath: pkg.installPath.path)
                let blobExists: Bool = {
                    guard let digest = pkg.contentDigest else { return false }
                    return FileManager.default.fileExists(
                        atPath: blobsRoot.appendingPathComponent(digest, isDirectory: true).path)
                }()
                if !pathExists {
                    if blobExists, let digest = pkg.contentDigest {
                        // Rebind install path to content-addressed blob (EXT-N12/N14).
                        var rebound = pkg
                        let blob = blobsRoot.appendingPathComponent(digest, isDirectory: true)
                        rebound.installPath = blob
                        rebound.plan.packageRoot = blob
                        packages[id] = rebound
                    } else {
                        packages.removeValue(forKey: id)
                        continue
                    }
                }
                let live = packages[id] ?? pkg
                if live.quarantined { continue }
                let idRoot = packageDirectory(for: id)
                if var rebuilt = loadInstalledFromPointers(id: id, idRoot: idRoot, base: live) {
                    // Re-verify staged tree before trusting it as active (EXT-N16 fail-closed).
                    // Verify failure (throw) or quarantined result → never preserve prior enabled state.
                    do {
                        let v = try runVerify(packageRoot: rebuilt.installPath)
                        if v.quarantined {
                            rebuilt.quarantined = true
                            rebuilt.quarantineReason = v.error ?? "recover re-verify failed"
                            rebuilt.enabled = false
                            rebuilt.state = .quarantined
                        } else {
                            rebuilt.enabled = live.enabled
                            rebuilt.quarantined = live.quarantined
                            rebuilt.quarantineReason = live.quarantineReason
                            rebuilt.state = live.state
                            rebuilt.trustClass = v.trustClass
                            rebuilt.contentDigest = live.contentDigest ?? rebuilt.contentDigest
                            rebuilt.storeKey = live.storeKey ?? rebuilt.storeKey
                        }
                    } catch {
                        rebuilt.quarantined = true
                        rebuilt.quarantineReason = "recover re-verify threw: \(error)"
                        rebuilt.enabled = false
                        rebuilt.state = .quarantined
                    }
                    packages[id] = rebuilt
                    continue
                }
                // No pointers and no live path → drop (installPath already rebound or removed above).
                if !FileManager.default.fileExists(atPath: (packages[id] ?? live).installPath.path) {
                    packages.removeValue(forKey: id)
                }
            } else if !FileManager.default.fileExists(atPath: pkg.installPath.path) {
                packages.removeValue(forKey: id)
            }
        }

        // Discover packages present on disk but missing from durable state (e.g. state write interrupted).
        if let idDirs = try? FileManager.default.contentsOfDirectory(
            at: packagesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for idDir in idDirs {
                // Directory names are directoryKey hashes; only rebuild when durable state
                // already mapped them, or when extension.toml is present and validates.
                guard let rebuilt = loadInstalledFromPointersByRoot(idRoot: idDir) else { continue }
                let id = rebuilt.plan.packageID
                if packages[id] != nil { continue }
                packages[id] = rebuilt
            }
        }

        try? persistDurableState()
        rebuildSnapshot()
    }

    /// Load package + previous plan from `current` / `previous` pointer files.
    private func loadInstalledFromPointers(
        id: ExtensionID,
        idRoot: URL,
        base: InstalledPackage?
    ) -> InstalledPackage? {
        guard let current = try? readPointer(idRoot: idRoot, name: "current") else { return nil }
        let dir = idRoot.appendingPathComponent(current, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path),
            var plan = try? ExtensionPackageLoader.load(directory: dir, options: .init(computeDigest: false))
        else { return nil }
        // Reject directory/identity mismatch (EXT-001).
        guard plan.packageID == id || idRoot.lastPathComponent == id.directoryKey else { return nil }
        plan.packageRoot = dir
        var previousPlan: ValidatedContributionPlan?
        var previousVersion: String?
        if let prev = try? readPointer(idRoot: idRoot, name: "previous") {
            previousVersion = prev
            let prevDir = idRoot.appendingPathComponent(prev, isDirectory: true)
            if var prevPlan = try? ExtensionPackageLoader.load(
                directory: prevDir,
                options: .init(computeDigest: false)
            ) {
                prevPlan.packageRoot = prevDir
                previousPlan = prevPlan
            }
        }
        // EXT-N16: pointer recovery does not default to trusted without digest/verify.
        var digest = base?.contentDigest
        if digest == nil {
            digest = try? PackageInventoryBuilder.build(packageRoot: dir).packageSHA256
        }
        return InstalledPackage(
            plan: plan,
            enabled: base?.enabled ?? false,
            installPath: dir,
            isDev: base?.isDev ?? false,
            previousPlan: previousPlan,
            currentVersion: current,
            previousVersion: previousVersion ?? base?.previousVersion,
            state: base?.state ?? .discovered,
            trustClass: base?.trustClass ?? .untrusted,
            quarantined: base?.quarantined ?? true,
            quarantineReason: base?.quarantineReason ?? "recovered; re-verify required",
            publisher: base?.publisher,
            contentDigest: digest,
            storeKey: base?.storeKey ?? digest.map { "blobs/sha256/\($0)" }
        )
    }

    /// Discover a package from a filesystem root by reading pointers and validating the manifest ID.
    private func loadInstalledFromPointersByRoot(idRoot: URL) -> InstalledPackage? {
        guard let current = try? readPointer(idRoot: idRoot, name: "current") else { return nil }
        let dir = idRoot.appendingPathComponent(current, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path),
            let plan = try? ExtensionPackageLoader.load(directory: dir, options: .init(computeDigest: false))
        else { return nil }
        // Directory must match the canonical directoryKey of the package ID.
        guard idRoot.lastPathComponent == plan.packageID.directoryKey else { return nil }
        return loadInstalledFromPointers(id: plan.packageID, idRoot: idRoot, base: nil)
    }

    public func quarantine(id: ExtensionID, reason: String) throws {
        guard var pkg = packages[id] else { throw ExtensionError.notRegistered }
        pkg.quarantined = true
        pkg.quarantineReason = reason
        pkg.enabled = false
        pkg.state = .quarantined
        packages[id] = pkg
        try persistDurableState()
        rebuildSnapshot()
        record(.init(event: "package.quarantine", packageID: id.rawValue, success: true, reason: reason))
    }

    public func assertCanActivate(id: ExtensionID) throws {
        if storeQuarantined {
            recordDenied(id: id, reason: "store_quarantined")
            throw ExtensionError.dataLoad(
                "store quarantined: \(storeQuarantineReason ?? "untrusted state")")
        }
        guard let pkg = packages[id] else { throw ExtensionError.notRegistered }
        // EXT-N15: revocation checked before soft disable/quarantine so deny reason stays accurate.
        do {
            try assertNotRevoked(packageID: id.rawValue, version: pkg.currentVersion)
        } catch {
            recordDenied(id: id, reason: "revoked")
            try? quarantine(id: id, reason: "revoked")
            throw error
        }
        if pkg.quarantined {
            recordDenied(id: id, reason: "quarantined")
            throw ExtensionError.dataLoad("quarantined: \(pkg.quarantineReason ?? "")")
        }
        if !pkg.enabled {
            recordDenied(id: id, reason: "disabled")
            throw ExtensionError.dataLoad("package disabled")
        }
        if let keyID = publisherKeyID(for: pkg), isKeyRevoked(keyID) {
            recordDenied(id: id, reason: "key_revoked")
            try? quarantine(id: id, reason: "signing key revoked: \(keyID)")
            throw ExtensionError.dataLoad("signing key revoked: \(keyID)")
        }
        // Live verify on activate
        if !pkg.isDev {
            let v = try runVerify(packageRoot: pkg.installPath)
            if v.quarantined {
                recordDenied(id: id, reason: "verify_failed")
                try quarantine(id: id, reason: v.error ?? "verify failed")
                throw ExtensionError.dataLoad(v.error ?? "verify failed")
            }
        }
    }

    private func recordDenied(id: ExtensionID, reason: String) {
        record(
            .init(
                event: "activation.denied",
                packageID: id.rawValue,
                success: false,
                reason: reason
            ))
    }

    public func installedPackages() -> [InstalledPackage] {
        Array(packages.values).sorted { $0.plan.packageID.rawValue < $1.plan.packageID.rawValue }
    }

    public func package(id: ExtensionID) -> InstalledPackage? {
        packages[id]
    }

    public func userDataDir(id: ExtensionID) -> URL {
        dataRoot.appendingPathComponent(id.directoryKey, isDirectory: true)
    }

    public func trustStatusItems() -> [ExtensionTrustStatusItem] {
        installedPackages().map {
            ExtensionTrustStatusItem(
                packageID: $0.plan.packageID.rawValue,
                version: $0.currentVersion,
                trustClass: $0.trustClass,
                enabled: $0.enabled,
                quarantined: $0.quarantined,
                lastError: $0.quarantineReason,
                publisher: $0.publisher
            )
        }
    }

    public func trustPromptIfNeeded(for id: ExtensionID) -> TrustPromptDescriptor? {
        guard let pkg = packages[id] else { return nil }
        switch pkg.trustClass {
        case .trustedSigned:
            return nil
        case .workspaceDev:
            return TrustPromptDescriptor(
                title: "Trust workspace extension?",
                message: "\(pkg.plan.displayName) is an unsigned workspace-dev package.",
                packageID: id.rawValue,
                publisher: pkg.publisher,
                trustClass: .workspaceDev,
                risks: ["Not signed", "Can load local code"]
            )
        case .untrusted:
            return TrustPromptDescriptor(
                title: "Untrusted extension",
                message: "\(pkg.plan.displayName) could not be verified as a trusted publisher.",
                packageID: id.rawValue,
                publisher: pkg.publisher,
                trustClass: .untrusted,
                risks: ["Unknown publisher", "Signature missing or untrusted"],
                actions: [.deny, .viewDetails]
            )
        }
    }

    // MARK: - Private

    private func ensureLayout() {
        for dir in [
            packagesRoot, stateRoot, dataRoot, telemetryRoot, revocationRoot, cacheRoot, downloadsRoot,
            blobsRoot, installsMetaRoot, activeRoot, transactionsRoot, hostStateRoot,
        ] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if telemetry == nil {
            telemetry = StoreTelemetrySink(
                fileURL: telemetryRoot.appendingPathComponent("migration-events.ndjson"),
                maxFileBytes: 1_048_576,
                maxTotalBytes: 8_388_608
            )
        }
    }

    private func ensureUserDataDir(id: ExtensionID) throws {
        try FileManager.default.createDirectory(at: userDataDir(id: id), withIntermediateDirectories: true)
    }

    private func ensureHostStateDir(id: ExtensionID) throws {
        let dir = hostStateRoot.appendingPathComponent(id.directoryKey, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func assertRevocationFresh() throws {
        // Empty list is fine; non-zero sequence lists must be fresh (EXT-N15).
        if revocation.sequence > 0 || revocation.expiresAt != nil {
            guard revocation.isFresh(now: Date(), maxAge: revocationMaxAge) else {
                throw ExtensionError.dataLoad("revocation list is stale or expired (EXT-N15)")
            }
        }
    }

    private struct InstallTransaction: Codable {
        var id: String
        var packageID: String
        var version: String
        var contentDigest: String
        var phase: Phase
        var createdAt: Date
        var error: String?

        enum Phase: String, Codable {
            case started
            case verified
            case committed
            case rolledBack
        }
    }

    private func writeTransaction(_ tx: InstallTransaction) throws {
        try FileManager.default.createDirectory(at: transactionsRoot, withIntermediateDirectories: true)
        let url = transactionsRoot.appendingPathComponent("\(tx.id).json")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(tx).write(to: url, options: .atomic)
        try fsyncDirectory(transactionsRoot)
    }

    private func writeInstallRecord(
        id: ExtensionID,
        version: String,
        digest: String,
        trust: ExtensionTrustClassDTO,
        publisher: String?
    ) throws {
        let dir = installsMetaRoot.appendingPathComponent(id.directoryKey, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "package_id": id.rawValue,
            "version": version,
            "content_digest": digest,
            "store_key": "blobs/sha256/\(digest)",
            "trust_class": trust.rawValue,
            "publisher": publisher as Any,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("\(version).json"), options: .atomic)
    }

    private func writeActivePointer(id: ExtensionID, version: String, digest: String) throws {
        try FileManager.default.createDirectory(at: activeRoot, withIntermediateDirectories: true)
        let obj: [String: String] = [
            "package_id": id.rawValue,
            "version": version,
            "content_digest": digest,
            "store_key": "blobs/sha256/\(digest)",
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let tmp = activeRoot.appendingPathComponent(".\(id.directoryKey).tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        let dest = activeRoot.appendingPathComponent("\(id.directoryKey).json")
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try fsyncDirectory(activeRoot)
    }

    private func fsyncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    /// Replay incomplete transactions on bootstrap (EXT-N12).
    private func recoverTransactions() {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: transactionsRoot, includingPropertiesForKeys: nil)
        else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                let tx = try? dec.decode(InstallTransaction.self, from: data)
            else { continue }
            if tx.phase == .started || tx.phase == .verified {
                // Roll back incomplete installs: remove staging leftovers; never activate.
                let staging = installRoot.appendingPathComponent("cache/staging-\(tx.id)", isDirectory: true)
                try? FileManager.default.removeItem(at: staging)
                var rolled = tx
                rolled.phase = .rolledBack
                rolled.error = "startup recovery"
                try? writeTransaction(rolled)
            }
        }
    }

    private func writePointer(idRoot: URL, name: String, version: String) throws {
        let url = idRoot.appendingPathComponent(name)
        try version.write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPointer(idRoot: URL, name: String) throws -> String {
        let url = idRoot.appendingPathComponent(name)
        let s = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ExtensionError.dataLoad("empty pointer \(name)") }
        return s
    }

    private func copyPackage(from source: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
    }

    private func runVerify(packageRoot: URL) throws -> PackageVerifyResult {
        if let verifier {
            return try verifier.verify(packageRoot: packageRoot)
        }
        if allowMissingSecurity {
            return PackageVerifyResult(trustClass: .workspaceDev, publisher: nil, quarantined: false, error: nil)
        }
        // EXT-004: fail closed — production installs require an explicit verifier.
        throw ExtensionError.dataLoad("extension package verifier is required (fail-closed)")
    }

    private func assertInstallPolicy(plan: ValidatedContributionPlan, source: URL, asDev: Bool) throws {
        guard let policy = installPolicy else {
            if allowMissingSecurity { return }
            // EXT-004: fail closed — production installs require an explicit policy.
            throw ExtensionError.dataLoad("extension install policy is required (fail-closed)")
        }
        if policy.dynamicInstallation == .disabled {
            record(
                .init(
                    event: "install.denied",
                    packageID: plan.packageID.rawValue,
                    success: false,
                    reason: "dynamicInstallation=disabled"
                ))
            throw ExtensionError.dataLoad(
                "install disabled on shipping profile \(policy.shippingProfileID.rawValue)"
            )
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        let hasWasm = entries.contains(where: { $0.hasSuffix(".wasm") })
        // Explicit markers for tests/fixtures (host apps can place the same markers).
        let forceNative = FileManager.default.fileExists(
            atPath: source.appendingPathComponent(".codeeditor-native").path
        )
        let forceDownloadWasm = FileManager.default.fileExists(
            atPath: source.appendingPathComponent(".codeeditor-wasm-download").path
        )
        let hasNativeHelperBinary = FileManager.default.fileExists(
            atPath: source.appendingPathComponent("native-helper").path
        )

        if forceNative || hasNativeHelperBinary {
            if !policy.allowNativeHelpers {
                record(
                    .init(
                        event: "install.denied",
                        packageID: plan.packageID.rawValue,
                        success: false,
                        reason: "native_helpers"
                    ))
                throw ExtensionError.dataLoad(
                    "native helper install denied on \(policy.shippingProfileID.rawValue)"
                )
            }
        }
        if forceDownloadWasm || hasWasm {
            if !policy.allowDownloadableWasm && !asDev {
                record(
                    .init(
                        event: "install.denied",
                        packageID: plan.packageID.rawValue,
                        success: false,
                        reason: "downloadable_wasm"
                    ))
                throw ExtensionError.dataLoad(
                    "downloadable Wasm install denied on \(policy.shippingProfileID.rawValue)"
                )
            }
        }
        if policy.dataOnlyOnly && (forceNative || forceDownloadWasm || hasNativeHelperBinary) {
            record(
                .init(
                    event: "install.denied",
                    packageID: plan.packageID.rawValue,
                    success: false,
                    reason: "data_only_policy"
                ))
            throw ExtensionError.dataLoad(
                "executable package install denied (data-only policy) on \(policy.shippingProfileID.rawValue)"
            )
        }
    }

    private func assertNotRevoked(packageID: String, version: String) throws {
        for entry in revocation.entries {
            if entry.matches(packageID: packageID, version: version) {
                throw ExtensionError.dataLoad("package revoked: \(entry.reason)")
            }
        }
    }

    private func isKeyRevoked(_ keyID: String) -> Bool {
        revocation.entries.contains { $0.keyID == keyID }
    }

    private func publisherKeyID(for pkg: InstalledPackage) -> String? {
        let pub = pkg.installPath.appendingPathComponent("publisher.json")
        guard let data = try? Data(contentsOf: pub),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return obj["key_id"]
    }

    private func rebuildSnapshot() {
        previousSnapshots.append(snapshot)
        if previousSnapshots.count > 8 {
            previousSnapshots.removeFirst(previousSnapshots.count - 8)
        }
        generation &+= 1
        // EXT-N16: only fully loadable records enter the contribution snapshot.
        let loadable = packages.values.filter { isLoadableForSnapshot($0) }.map(\.plan)
        snapshot = ImmutableContributionRegistry.build(packages: loadable, generation: generation)
        continuation?.yield(snapshot)
        let snap = snapshot
        Task { await snapshotHub.publish(snap) }
    }

    /// Rebuild and **await** hub publish (EXT-N19 deterministic sequencing for revoke/tests).
    private func rebuildSnapshotPublishing() async {
        previousSnapshots.append(snapshot)
        if previousSnapshots.count > 8 {
            previousSnapshots.removeFirst(previousSnapshots.count - 8)
        }
        generation &+= 1
        let loadable = packages.values.filter { isLoadableForSnapshot($0) }.map(\.plan)
        snapshot = ImmutableContributionRegistry.build(packages: loadable, generation: generation)
        continuation?.yield(snapshot)
        await snapshotHub.publish(snapshot)
    }

    /// Full loadable checklist (EXT-N16):
    /// installed ∧ bytes exist ∧ digest matches ∧ trust re-verify ∧ not revoked ∧ enabled
    /// ∧ host/platform compatible ∧ capabilities granted ∧ store not quarantined.
    public func isLoadableForSnapshot(_ pkg: InstalledPackage) -> Bool {
        guard pkg.enabled, !pkg.quarantined, pkg.state == .installed else { return false }
        if storeQuarantined { return false }
        // Reject revoked immediately.
        if revocation.entries.contains(where: {
            $0.matches(packageID: pkg.plan.packageID.rawValue, version: pkg.currentVersion)
        }) {
            return false
        }
        // Host API compatibility.
        if !pkg.plan.manifest.requiredAPIVersion.contains(hostEnvironment.apiVersion) {
            return false
        }
        // Capabilities granted (required ⊆ host capabilities).
        if !pkg.plan.manifest.requiredHostCapabilities.isSubset(of: hostEnvironment.capabilities) {
            return false
        }
        if pkg.isDev {
            guard FileManager.default.fileExists(atPath: pkg.installPath.path) else { return false }
            return true
        }
        guard let digest = pkg.contentDigest, !digest.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: pkg.installPath.path) else { return false }
        // Live digest match under store root.
        guard
            let live = try? PackageInventoryBuilder.build(packageRoot: pkg.installPath).packageSHA256,
            live == digest
        else { return false }
        // Signature/trust re-verify under current policy when a verifier is configured.
        if let verifier {
            do {
                let result = try verifier.verify(packageRoot: pkg.installPath)
                if result.quarantined { return false }
                if result.trustClass == .untrusted { return false }
            } catch {
                return false
            }
        } else if !allowMissingSecurity {
            // Production path: no verifier ⇒ not loadable.
            return false
        }
        return true
    }

    /// Public recovery entry for incomplete install transactions (EXT-N12).
    public func recoverIncompleteTransactions() {
        recoverTransactions()
    }

    /// Recompute contribution snapshot and await hub publish (tests / consumer backlog).
    public func rebuildSnapshotForTests() async {
        await rebuildSnapshotPublishing()
    }

    public func setHostEnvironmentForTests(_ env: HostEnvironment) {
        hostEnvironment = env
    }

    /// Count of transaction journal files currently marked rolledBack or incomplete.
    public func transactionJournalPhases() throws -> [(id: String, phase: String)] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: transactionsRoot, includingPropertiesForKeys: nil)
        else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [(String, String)] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                let tx = try? dec.decode(InstallTransaction.self, from: data)
            else { continue }
            out.append((tx.id, tx.phase.rawValue))
        }
        return out
    }

    private func record(_ event: StoreTelemetryEvent) {
        telemetry?.append(event)
    }

    // MARK: - Durable state

    private struct DurableState: Codable {
        var packages: [DurableRecord]
    }

    private struct DurableRecord: Codable {
        var id: String
        var version: String
        var previousVersion: String?
        /// Absolute path retained only for legacy; prefer storeKey + contentDigest (EXT-N14).
        var path: String?
        var storeKey: String?
        var contentDigest: String?
        var enabled: Bool
        var isDev: Bool
        var state: PackageInstallState
        var trustClass: ExtensionTrustClassDTO
        var quarantined: Bool
        var quarantineReason: String?
        var publisher: String?
    }

    private func persistDurableState() throws {
        let records = packages.map { id, pkg -> DurableRecord in
            let key = pkg.storeKey ?? (pkg.contentDigest.map { "blobs/sha256/\($0)" })
            return DurableRecord(
                id: id.rawValue,
                version: pkg.currentVersion,
                previousVersion: pkg.previousVersion,
                path: nil, // EXT-N14: do not persist free absolute roots as sole identity
                storeKey: key,
                contentDigest: pkg.contentDigest,
                enabled: pkg.enabled,
                isDev: pkg.isDev,
                state: pkg.state,
                trustClass: pkg.trustClass,
                quarantined: pkg.quarantined,
                quarantineReason: pkg.quarantineReason,
                publisher: pkg.publisher
            )
        }
        let data = try JSONEncoder().encode(DurableState(packages: records))
        try data.write(to: stateRoot.appendingPathComponent("packages.json"), options: .atomic)
    }

    private func resolveStorePath(storeKey: String?, contentDigest: String?, legacyPath: String?) -> URL? {
        if let key = storeKey, !key.isEmpty {
            let candidate = installRoot.appendingPathComponent(key, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let digest = contentDigest, !digest.isEmpty {
            let candidate = blobsRoot.appendingPathComponent(digest, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Legacy absolute path: only accept when under installRoot.
        if let legacy = legacyPath {
            let url = URL(fileURLWithPath: legacy)
            let rootPath = installRoot.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path == rootPath || path.hasPrefix(rootPath + "/") {
                if FileManager.default.fileExists(atPath: path) { return url }
            }
        }
        return nil
    }

    private func loadDurableState() throws {
        recoverTransactions()
        let url = stateRoot.appendingPathComponent("packages.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(DurableState.self, from: data)
        for rec in state.packages {
            guard let id = ExtensionID(rawValue: rec.id) else { continue }
            guard
                let path = resolveStorePath(
                    storeKey: rec.storeKey, contentDigest: rec.contentDigest, legacyPath: rec.path)
            else { continue }
            // EXT-N16: re-verify digest when present.
            if let expected = rec.contentDigest, !rec.isDev {
                if let live = try? PackageInventoryBuilder.build(packageRoot: path).packageSHA256,
                    live != expected
                {
                    // Quarantine mismatched recovered package.
                    packages[id] = InstalledPackage(
                        plan: ValidatedContributionPlan(
                            packageID: id,
                            displayName: id.rawValue,
                            version: SemanticVersion.parse(rec.version) ?? .zero,
                            manifest: ExtensionManifest(id: id, displayName: id.rawValue),
                            packageRoot: path,
                            sourceFormat: .toml,
                            digest: expected
                        ),
                        enabled: false,
                        installPath: path,
                        isDev: false,
                        previousPlan: nil,
                        currentVersion: rec.version,
                        previousVersion: rec.previousVersion,
                        state: .quarantined,
                        trustClass: rec.trustClass,
                        quarantined: true,
                        quarantineReason: "content digest mismatch on recovery",
                        publisher: rec.publisher,
                        contentDigest: expected,
                        storeKey: rec.storeKey
                    )
                    continue
                }
            }
            guard
                var plan = try? ExtensionPackageLoader.load(
                    directory: path, options: .init(computeDigest: false))
            else { continue }
            plan.packageRoot = path
            plan.digest = rec.contentDigest
            var previousPlan: ValidatedContributionPlan?
            if let prev = rec.previousVersion, !rec.isDev {
                let prevDir = packageDirectory(for: id)
                    .appendingPathComponent(prev, isDirectory: true)
                if var pp = try? ExtensionPackageLoader.load(
                    directory: prevDir, options: .init(computeDigest: false)
                ) {
                    pp.packageRoot = prevDir
                    previousPlan = pp
                }
            }
            // Recovered packages do not default to trusted/enabled without verification (EXT-N16).
            var enabled = rec.enabled
            var quarantined = rec.quarantined
            var quarantineReason = rec.quarantineReason
            var state = rec.state
            if !rec.isDev, rec.contentDigest == nil {
                enabled = false
                quarantined = true
                quarantineReason = "missing content digest"
                state = .quarantined
            }
            packages[id] = InstalledPackage(
                plan: plan,
                enabled: enabled,
                installPath: path,
                isDev: rec.isDev,
                previousPlan: previousPlan,
                currentVersion: rec.version,
                previousVersion: rec.previousVersion,
                state: state,
                trustClass: rec.trustClass,
                quarantined: quarantined,
                quarantineReason: quarantineReason,
                publisher: rec.publisher,
                contentDigest: rec.contentDigest,
                storeKey: rec.storeKey ?? rec.contentDigest.map { "blobs/sha256/\($0)" }
            )
        }
        rebuildSnapshot()
    }

    private func persistRevocationList() throws {
        let data = try JSONEncoder().encode(revocation)
        try data.write(to: revocationRoot.appendingPathComponent("list.json"), options: .atomic)
    }

    private func loadRevocationList() throws {
        let url = revocationRoot.appendingPathComponent("list.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let loaded = try JSONDecoder().decode(RevocationListDocument.self, from: data)
        // EXT-N15: fail closed on unsigned/stale durable revocation state.
        try RevocationListCrypto.requireSignedStructure(loaded)
        if loaded.sequence > 0 || !loaded.entries.isEmpty {
            if revocationAuthorities.isEmpty {
                throw ExtensionError.dataLoad(
                    "persisted revocation list requires configured authorities (EXT-N15)")
            }
            try loaded.verify(authorities: revocationAuthorities)
            if !loaded.isFresh(now: Date(), maxAge: revocationMaxAge) {
                throw ExtensionError.dataLoad("persisted revocation list is stale (EXT-N15)")
            }
        }
        revocation = loaded
    }
}

// MARK: - Verification protocol (injected; Host provides real implementation)

public struct PackageVerifyResult: Sendable {
    public var trustClass: ExtensionTrustClassDTO
    public var publisher: String?
    public var quarantined: Bool
    public var error: String?

    public init(trustClass: ExtensionTrustClassDTO, publisher: String?, quarantined: Bool, error: String?) {
        self.trustClass = trustClass
        self.publisher = publisher
        self.quarantined = quarantined
        self.error = error
    }
}

public protocol PackageVerifying: Sendable {
    func verify(packageRoot: URL) throws -> PackageVerifyResult
}

// MARK: - Telemetry sink

/// Bounded telemetry sink with size rotation (EXT-N18). Write failures are counted, never swallowed silently.
public final class StoreTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    public let maxFileBytes: Int
    public let maxTotalBytes: Int
    public private(set) var writeFailureCount: Int = 0
    public private(set) var rotationCount: Int = 0
    /// Test-only fault injection: next append fails closed and increments writeFailureCount.
    public var failNextWriteForTests: Bool = false

    public init(
        fileURL: URL,
        maxFileBytes: Int = 1_048_576,
        maxTotalBytes: Int = 8_388_608
    ) {
        self.fileURL = fileURL
        self.maxFileBytes = max(1_024, maxFileBytes)
        self.maxTotalBytes = max(self.maxFileBytes, maxTotalBytes)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func append(_ event: StoreTelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        if failNextWriteForTests {
            failNextWriteForTests = false
            writeFailureCount += 1
            return
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(event),
            var line = String(data: data, encoding: .utf8)
        else {
            writeFailureCount += 1
            return
        }
        line.append("\n")
        let payload = Data(line.utf8)
        do {
            try rotateIfNeeded(additional: payload.count)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } else {
                try payload.write(to: fileURL, options: .atomic)
            }
        } catch {
            writeFailureCount += 1
        }
    }

    public func totalDiskBytesUsed() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        guard
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for f in files where f.lastPathComponent.hasPrefix(base) {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }

    private func rotateIfNeeded(additional: Int) throws {
        let fm = FileManager.default
        let currentSize =
            (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if currentSize + additional <= maxFileBytes {
            // Still enforce total cap across rotations.
            try enforceTotalCap()
            return
        }
        // Rotate: events.ndjson → events.ndjson.1 ; drop older rotated files first.
        let rotated = fileURL.appendingPathExtension("1")
        if fm.fileExists(atPath: rotated.path) {
            try? fm.removeItem(at: rotated)
        }
        if fm.fileExists(atPath: fileURL.path) {
            try fm.moveItem(at: fileURL, to: rotated)
            rotationCount += 1
        }
        try enforceTotalCap()
    }

    private func enforceTotalCap() throws {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        guard
            let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        var siblings = files.filter { $0.lastPathComponent.hasPrefix(base) }
        func total() -> Int {
            siblings.reduce(0) { acc, f in
                acc + ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        // Delete oldest rotated files until under cap (keep primary if possible).
        while total() > maxTotalBytes {
            let candidates = siblings.filter { $0.lastPathComponent != base }
                .sorted {
                    let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return d0 < d1
                }
            guard let victim = candidates.first ?? siblings.first else { break }
            try? fm.removeItem(at: victim)
            siblings.removeAll { $0 == victim }
        }
    }

    private func totalDiskBytesUsedUnlocked() -> Int {
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent
        guard
            let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total = 0
        for f in files where f.lastPathComponent.hasPrefix(base) {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
        }
        return total
    }

    public func readAll() throws -> [StoreTelemetryEvent] {
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? dec.decode(StoreTelemetryEvent.self, from: Data(line.utf8))
        }
    }
}
