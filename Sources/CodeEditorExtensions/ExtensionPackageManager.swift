import CodeEditorExtensionAPI
import Foundation

/// Host package lifecycle with **immutable version directories**, durable state, recovery, and user-data preservation.
public actor ExtensionPackageManager {
    public let installRoot: URL
    public private(set) var generation: UInt64 = 0
    public private(set) var snapshot: ExtensionContributionSnapshot = .empty

    private var packages: [ExtensionID: InstalledPackage] = [:]
    private var previousSnapshots: [ExtensionContributionSnapshot] = []
    private var continuation: AsyncStream<ExtensionContributionSnapshot>.Continuation?
    public let snapshots: AsyncStream<ExtensionContributionSnapshot>
    private let maxEventBuffer: Int
    private var telemetry: StoreTelemetrySink?
    private var revocation: RevocationListDocument = .init()
    private var verifier: (any PackageVerifying)?
    private var installPolicy: ShippingInstallPolicy?

    public var packagesRoot: URL { installRoot.appendingPathComponent("packages", isDirectory: true) }
    public var stateRoot: URL { installRoot.appendingPathComponent("state", isDirectory: true) }
    public var dataRoot: URL { installRoot.appendingPathComponent("data", isDirectory: true) }
    public var telemetryRoot: URL { installRoot.appendingPathComponent("telemetry", isDirectory: true) }
    public var revocationRoot: URL { installRoot.appendingPathComponent("revocation", isDirectory: true) }
    public var cacheRoot: URL { installRoot.appendingPathComponent("cache", isDirectory: true) }
    public var downloadsRoot: URL { cacheRoot.appendingPathComponent("downloads", isDirectory: true) }

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

        public var canActivate: Bool {
            enabled && !quarantined && state == .installed
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
        ] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Filesystem directory for an extension — hash key, never the raw ID (EXT-001).
    public func packageDirectory(for id: ExtensionID) -> URL {
        packagesRoot.appendingPathComponent(id.directoryKey, isDirectory: true)
    }

    /// Load durable state and revocation list (call once after init).
    public func bootstrap() {
        ensureLayout()
        try? loadDurableState()
        try? loadRevocationList()
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

    public func setRevocationList(_ list: RevocationListDocument) throws {
        self.revocation = list
        try persistRevocationList()
    }

    public func revocationList() -> RevocationListDocument { revocation }

    // MARK: - Lifecycle

    @discardableResult
    public func install(from source: URL, asDev: Bool = false) throws -> ValidatedContributionPlan {
        let plan = try ExtensionPackageLoader.load(directory: source)
        if plan.hasErrors {
            throw ExtensionError.dataLoad(
                "package has errors: \(plan.diagnostics.map(\.message).joined(separator: "; "))")
        }
        let version = plan.version.description
        try assertNotRevoked(packageID: plan.packageID.rawValue, version: version)
        try assertInstallPolicy(plan: plan, source: source, asDev: asDev)

        let verify = try runVerify(packageRoot: source)
        if verify.quarantined {
            throw ExtensionError.dataLoad(verify.error ?? "package quarantined at verify")
        }

        let dest: URL
        if asDev {
            dest = source
            packages[plan.packageID] = InstalledPackage(
                plan: {
                    var p = plan
                    p.packageRoot = dest
                    return p
                }(),
                enabled: true,
                installPath: dest,
                isDev: true,
                previousPlan: packages[plan.packageID]?.plan,
                currentVersion: version,
                previousVersion: packages[plan.packageID]?.currentVersion,
                state: .installed,
                trustClass: verify.trustClass,
                quarantined: false,
                quarantineReason: nil,
                publisher: verify.publisher
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

        let idRoot = packageDirectory(for: plan.packageID)
        let versionDir = idRoot.appendingPathComponent(version, isDirectory: true)
        let staging = idRoot.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: idRoot, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        try copyPackage(from: source, to: staging)

        // Re-verify staged tree
        let stagedVerify = try runVerify(packageRoot: staging)
        if stagedVerify.quarantined {
            try? FileManager.default.removeItem(at: staging)
            throw ExtensionError.dataLoad(stagedVerify.error ?? "staged package failed verify")
        }

        let previous = packages[plan.packageID]
        if FileManager.default.fileExists(atPath: versionDir.path) {
            // Immutable: never overwrite; same-version reinstall reuses existing tree.
            try FileManager.default.removeItem(at: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: versionDir)
        }

        try writePointer(idRoot: idRoot, name: "current", version: version)
        if let prev = previous?.currentVersion, prev != version {
            try writePointer(idRoot: idRoot, name: "previous", version: prev)
        }

        var stored = plan
        stored.packageRoot = versionDir
        packages[plan.packageID] = InstalledPackage(
            plan: stored,
            enabled: previous?.enabled ?? true,
            installPath: versionDir,
            isDev: false,
            previousPlan: previous?.currentVersion == version ? previous?.previousPlan : previous?.plan,
            currentVersion: version,
            previousVersion: previous?.currentVersion == version ? previous?.previousVersion : previous?.currentVersion,
            state: .installed,
            trustClass: stagedVerify.trustClass,
            quarantined: false,
            quarantineReason: nil,
            publisher: stagedVerify.publisher
        )
        try ensureUserDataDir(id: plan.packageID)
        try persistDurableState()
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
            if pkg.quarantined { continue }
            if !pkg.isDev {
                let idRoot = packageDirectory(for: id)
                if let rebuilt = loadInstalledFromPointers(id: id, idRoot: idRoot, base: pkg) {
                    packages[id] = rebuilt
                    continue
                }
                if !FileManager.default.fileExists(atPath: pkg.installPath.path) {
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
        return InstalledPackage(
            plan: plan,
            enabled: base?.enabled ?? true,
            installPath: dir,
            isDev: base?.isDev ?? false,
            previousPlan: previousPlan,
            currentVersion: current,
            previousVersion: previousVersion ?? base?.previousVersion,
            state: base?.state ?? .installed,
            trustClass: base?.trustClass ?? .workspaceDev,
            quarantined: base?.quarantined ?? false,
            quarantineReason: base?.quarantineReason,
            publisher: base?.publisher
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
        guard let pkg = packages[id] else { throw ExtensionError.notRegistered }
        if pkg.quarantined {
            recordDenied(id: id, reason: "quarantined")
            throw ExtensionError.dataLoad("quarantined: \(pkg.quarantineReason ?? "")")
        }
        if !pkg.enabled {
            recordDenied(id: id, reason: "disabled")
            throw ExtensionError.dataLoad("package disabled")
        }
        do {
            try assertNotRevoked(packageID: id.rawValue, version: pkg.currentVersion)
        } catch {
            recordDenied(id: id, reason: "revoked")
            try? quarantine(id: id, reason: "revoked")
            throw error
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
        for dir in [packagesRoot, stateRoot, dataRoot, telemetryRoot, revocationRoot, cacheRoot, downloadsRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if telemetry == nil {
            telemetry = StoreTelemetrySink(fileURL: telemetryRoot.appendingPathComponent("migration-events.ndjson"))
        }
    }

    private func ensureUserDataDir(id: ExtensionID) throws {
        try FileManager.default.createDirectory(at: userDataDir(id: id), withIntermediateDirectories: true)
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
        let enabled = packages.values.filter { $0.enabled && !$0.quarantined }.map(\.plan)
        snapshot = ImmutableContributionRegistry.build(packages: enabled, generation: generation)
        continuation?.yield(snapshot)
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
        var path: String
        var enabled: Bool
        var isDev: Bool
        var state: PackageInstallState
        var trustClass: ExtensionTrustClassDTO
        var quarantined: Bool
        var quarantineReason: String?
        var publisher: String?
    }

    private func persistDurableState() throws {
        let records = packages.map { id, pkg in
            DurableRecord(
                id: id.rawValue,
                version: pkg.currentVersion,
                previousVersion: pkg.previousVersion,
                path: pkg.installPath.path,
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

    private func loadDurableState() throws {
        let url = stateRoot.appendingPathComponent("packages.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(DurableState.self, from: data)
        for rec in state.packages {
            guard let id = ExtensionID(rawValue: rec.id) else { continue }
            let path = URL(fileURLWithPath: rec.path)
            guard FileManager.default.fileExists(atPath: path.path),
                var plan = try? ExtensionPackageLoader.load(directory: path, options: .init(computeDigest: false))
            else { continue }
            plan.packageRoot = path
            var previousPlan: ValidatedContributionPlan?
            if let prev = rec.previousVersion, !rec.isDev {
                let prevDir = packageDirectory(for: id)
                    .appendingPathComponent(prev, isDirectory: true)
                if var pp = try? ExtensionPackageLoader.load(directory: prevDir, options: .init(computeDigest: false)) {
                    pp.packageRoot = prevDir
                    previousPlan = pp
                }
            }
            packages[id] = InstalledPackage(
                plan: plan,
                enabled: rec.enabled,
                installPath: path,
                isDev: rec.isDev,
                previousPlan: previousPlan,
                currentVersion: rec.version,
                previousVersion: rec.previousVersion,
                state: rec.state,
                trustClass: rec.trustClass,
                quarantined: rec.quarantined,
                quarantineReason: rec.quarantineReason,
                publisher: rec.publisher
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
        revocation = try JSONDecoder().decode(RevocationListDocument.self, from: data)
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

public final class StoreTelemetrySink: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    public func append(_ event: StoreTelemetryEvent) {
        lock.lock()
        defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(event),
            var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: fileURL)
        }
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
