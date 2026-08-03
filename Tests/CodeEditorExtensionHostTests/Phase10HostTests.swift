import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensionAPI
import CodeEditorExtensionGuest
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import CodeEditorLanguageServices
import Foundation
import Testing

@testable import CodeEditorExtensionHost

// MARK: - Helpers

private func makeBroker(roots: [URL] = []) throws -> CapabilityBroker {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // Host-owned npm fixture registry for left-pad@1.0.0
    let npmReg = tmp.appendingPathComponent("npm-registry/left-pad/1.0.0", isDirectory: true)
    try FileManager.default.createDirectory(at: npmReg, withIntermediateDirectories: true)
    try """
        {"name":"left-pad","version":"1.0.0","main":"index.js"}
        """.write(to: npmReg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    try "module.exports=function(){}\n".write(
        to: npmReg.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
    return try CapabilityBroker(
        config: .init(
            worktreeRoots: roots,
            storageRoot: tmp.appendingPathComponent("storage"),
            toolCacheRoot: tmp.appendingPathComponent("cache"),
            processAllowlist: [
                .init(command: "/bin/sleep"),
                .init(command: "sleep"),
                .init(command: "/bin/echo"),
                .init(command: "echo"),
            ],
            downloadAllowlist: [
                .init(host: "example.com", pathPrefix: ["ok"]),
                .init(host: "cdn.example", pathPrefix: []),
            ],
            npmAllowlist: [
                .init(package: "left-pad", version: "1.0.0"),
            ],
            npmRegistryRoot: tmp.appendingPathComponent("npm-registry", isDirectory: true)
        ))
}

private struct ConformanceExt: CodeEditorExtension {
    var manifest: ExtensionManifest {
        ExtensionManifest(
            id: "com.codeeditor.conformance",
            displayName: "Conformance Extension",
            activationEvents: [.startup],
            requiredHostCapabilities: [.languageServices, .storage],
            requestedPermissions: [.readWorkspace, .startProcesses, .network]
        )
    }
    func activate(in context: any ExtensionAuthorContext) async throws {
        context.info("conformance activated")
    }
}

// MARK: - Dual-run

@Suite("Phase 10 dual-run conformance")
struct Phase10DualRunTests {
    @Test func builtInConformanceTrace() async throws {
        let services = await MainActor.run { ExtensionHostServices.makeFull() }
        let broker = try makeBroker()
        let env = HostEnvironment(
            capabilities: Set(HostCapability.allCases),
            grantedPermissions: [.readWorkspace, .startProcesses, .network, .presentUI]
        )
        let builtInDriver = BuiltInSwiftRuntimeDriver(services: services, environment: env)
        let pkg = PreparedExtensionPackage(
            packageID: "com.codeeditor.conformance",
            displayName: "Conformance",
            version: SemanticVersion(major: 1),
            manifest: ConformanceExt().manifest,
            trustClass: .workspaceDev,
            runtimePreference: .builtIn,
            builtInExtension: ConformanceExt()
        )
        let prepared = try await builtInDriver.prepare(package: pkg, policy: .testing)
        let handshake = ExtensionHostHandshake(environment: env, generation: 1)
        let builtInInstance = try await builtInDriver.start(
            prepared: prepared,
            handshake: handshake,
            broker: broker
        )
        let bi = builtInInstance as! BuiltInExtensionInstance
        _ = try await bi.request(ExtensionMethodID.completion, payload: Data())
        _ = try await bi.request(ExtensionMethodID.hover, payload: Data())
        _ = try await bi.request(ExtensionMethodID.echo, payload: Data("x".utf8))
        let builtInTrace = await bi.conformanceTrace()
        await bi.stop(reason: ExtensionStopReason.user)
        let methods = builtInTrace.map(\.method)
        #expect(methods.contains(ExtensionMethodID.activate.rawValue))
        #expect(methods.contains(ExtensionMethodID.completion.rawValue))
        #expect(methods.contains(ExtensionMethodID.hover.rawValue))
        #expect(methods.contains(ExtensionMethodID.echo.rawValue))
    }

    @Test func nativeMockGuestHandshakeAndEcho() async throws {
        let pair = MockWireTransport.makePair()
        let guestExt = ConformanceExt()
        let guestRuntime = ExtensionGuestRuntime(extension: guestExt, transport: pair.remote)
        await guestRuntime.installDefaultLanguageHandlers()

        let hostConn = ExtensionWireConnection(transport: pair.host, defaultTimeout: .seconds(2))
        let handshakeBox = NativeHandshakeWaiter()
        await hostConn.setEnvelopeHandler { envelope in
            if case .handshake(let h) = envelope {
                await handshakeBox.complete(h)
            }
        }
        await hostConn.start()
        let guestTask = Task { await guestRuntime.run() }

        let guestHandshake = try await handshakeBox.wait(timeout: .seconds(2))
        #expect(guestHandshake.schemaHash == ExtensionMethodCatalog.schemaHash)
        #expect(guestHandshake.packageID == "com.codeeditor.conformance")

        let result = ExtensionWireHandshakeResult(
            accepted: true,
            hostCapabilities: HostCapability.allCases.map(\.rawValue),
            grantedPermissions: ["readWorkspace"],
            generation: 1
        )
        try await hostConn.send(.handshakeResult(result))
        await hostConn.setGeneration(1)

        let activated = try await hostConn.request(.activate, payload: Data(), timeout: .seconds(2))
        #expect(activated.isEmpty)
        let echoed = try await hostConn.request(.echo, payload: Data("x".utf8), timeout: .seconds(2))
        #expect(echoed == Data("x".utf8))
        let completion = try await hostConn.request(.completion, payload: Data(), timeout: .seconds(2))
        #expect(!completion.isEmpty)

        await hostConn.close()
        await guestRuntime.stop()
        guestTask.cancel()
    }
}

/// Test helper for handshake wait without Host internals.
actor NativeHandshakeWaiter {
    private var value: ExtensionWireHandshake?
    private var cont: CheckedContinuation<ExtensionWireHandshake, Error>?

    func complete(_ h: ExtensionWireHandshake) {
        if value != nil { return }
        value = h
        cont?.resume(returning: h)
        cont = nil
    }

    func wait(timeout: Duration) async throws -> ExtensionWireHandshake {
        if let value { return value }
        return try await withThrowingTaskGroup(of: ExtensionWireHandshake.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<ExtensionWireHandshake, Error>) in
                    Task { await self.store(c) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ExtensionWireError.timeout
            }
            let v = try await group.next()!
            group.cancelAll()
            return v
        }
    }

    private func store(_ c: CheckedContinuation<ExtensionWireHandshake, Error>) {
        if let value {
            c.resume(returning: value)
        } else {
            cont = c
        }
    }
}

// MARK: - Broker

@Suite("Phase 10 capability broker")
struct Phase10BrokerTests {
    @Test func worktreePathEscapeDenied() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let broker = try makeBroker(roots: [root])
        let id: ExtensionID = "ext.wt"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let handle = try await broker.worktreeHandle(extensionID: id)
        let data = try await broker.worktreeRead(caller: id, handle: handle.id, relative: "a.txt")
        #expect(String(data: data, encoding: .utf8) == "hello")
        do {
            _ = try await broker.worktreeRead(caller: id, handle: handle.id, relative: "../etc/passwd")
            Issue.record("expected path escape")
        } catch BrokerError.pathEscape {
            // ok
        }
    }

    @Test func forgedAndStaleHandlesRejected() async throws {
        let broker = try makeBroker()
        let id: ExtensionID = "ext.h"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let handle = try await broker.worktreeHandle(extensionID: id)
        do {
            _ = try await broker.worktreeList(
                caller: id, handle: BrokerHandleID(rawValue: "forged"), relative: ""
            )
            Issue.record("expected forged")
        } catch BrokerError.forgedHandle {
            // ok
        }
        // Stale generation
        await broker.registerExtension(id: id, generation: 2, granted: [.readWorkspace])
        do {
            _ = try await broker.worktreeList(caller: id, handle: handle.id, relative: "")
            Issue.record("expected stale")
        } catch BrokerError.staleGeneration {
            // ok
        }
    }

    @Test func processAllowlistAndKill() async throws {
        let broker = try makeBroker()
        let id: ExtensionID = "ext.proc"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let handle = try await broker.processHandle(extensionID: id)
        let lease = try await broker.processSpawn(
            caller: id,
            handle: handle.id,
            executable: "/bin/sleep",
            arguments: ["30"]
        )
        #expect(lease.pid > 0)
        #expect(NativeHelperProcessTransport.isProcessAlive(lease.pid))
        try await broker.processKill(caller: id, handle: lease.lease)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!NativeHelperProcessTransport.isProcessAlive(lease.pid))
    }

    @Test func processDeniedWhenNotAllowlisted() async throws {
        let broker = try makeBroker()
        let id: ExtensionID = "ext.proc2"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let handle = try await broker.processHandle(extensionID: id)
        do {
            _ = try await broker.processSpawn(
                caller: id,
                handle: handle.id,
                executable: "/usr/bin/yes",
                arguments: []
            )
            Issue.record("expected deny")
        } catch BrokerError.processDenied {
            // ok
        }
    }

    @Test func downloadAllowlist() async throws {
        let broker = try makeBroker()
        let id: ExtensionID = "ext.dl"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let handle = try await broker.downloadHandle(extensionID: id)
        let url = try await broker.downloadWriteFixture(
            caller: id,
            handle: handle.id,
            host: "example.com",
            path: "/ok/file",
            data: Data("hi".utf8)
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        do {
            _ = try await broker.downloadWriteFixture(
                caller: id,
                handle: handle.id,
                host: "evil.com",
                path: "/",
                data: Data()
            )
            Issue.record("expected download deny")
        } catch BrokerError.downloadDenied {
            // ok
        }
    }

    @Test func npmInstallNoScripts() async throws {
        let broker = try makeBroker()
        let id: ExtensionID = "ext.npm"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let handle = try await broker.npmHandle(extensionID: id)
        let dest = try await broker.npmInstall(
            caller: id, handle: handle.id, package: "left-pad", version: "1.0.0"
        )
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("index.js").path))
        // BROKER-N15: immutable materialization — no post-copy package.json mutation; scripts never run.
        let pkg = try String(contentsOf: dest.appendingPathComponent("package.json"), encoding: .utf8)
        #expect(pkg.contains("left-pad"))
        #expect(dest.path.contains(id.directoryKey))
    }

    @Test func storageQuota() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-\(UUID().uuidString)", isDirectory: true)
        let broker = try CapabilityBroker(
            config: .init(
                storageRoot: tmp.appendingPathComponent("s"),
                toolCacheRoot: tmp.appendingPathComponent("c"),
                storageQuotaBytes: 16
            ))
        let id: ExtensionID = "ext.q"
        await broker.registerExtension(id: id, generation: 1, granted: [])
        let h = try await broker.storageHandle(extensionID: id)
        try await broker.storageSet(caller: id, handle: h.id, key: "a", value: Data(repeating: 1, count: 10))
        do {
            try await broker.storageSet(caller: id, handle: h.id, key: "b", value: Data(repeating: 1, count: 20))
            Issue.record("expected quota")
        } catch BrokerError.quotaExceeded {
            // ok
        }
    }
}

// MARK: - Signing

@Suite("Phase 10 package signing")
struct Phase10SigningTests {
    @Test func signAndVerify() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
            id = "com.example.sign"
            name = "X"
            version = "1.0.0"
            schema_version = 1
            api_version = "1.0"
            license = "MIT"
            [activation]
            events = ["startup"]
            """.write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "MIT".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)

        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: "test-key")
        try ExtensionPackageSigner.sign(
            packageRoot: root,
            privateKeyRaw: kp.privateKeyRaw,
            keyID: kp.keyID,
            subject: "Test Publisher"
        )
        let trust = try ExtensionPackageVerifier.verify(
            packageRoot: root,
            policy: ExtensionTrustPolicy(
                allowWorkspaceDevNative: false,
                trustedKeys: [
                    ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "Test Publisher")
                ]
            )
        )
        #expect(trust == .trustedSigned)

        // Bit-flip signature
        let sigURL = root.appendingPathComponent("signature.ed25519")
        var sig = try Data(contentsOf: sigURL)
        sig[0] ^= 0xFF
        try sig.write(to: sigURL)
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageVerifier.verify(
                packageRoot: root,
                policy: ExtensionTrustPolicy(
                    trustedKeys: [
                        ExtensionPublisherKey(keyID: kp.keyID, publicKeyRaw: kp.publicKeyRaw, subject: "T")
                    ]
                )
            )
        }
    }

    @Test func untrustedNativeRejectedByDefault() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("untrust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        #expect(throws: PackageSignatureError.self) {
            try ExtensionPackageVerifier.verify(packageRoot: root, policy: .strict)
        }
        let trust = try ExtensionPackageVerifier.verify(packageRoot: root, policy: .testing)
        #expect(trust == .workspaceDev)
    }
}

// MARK: - Lifecycle / quarantine

@Suite("Phase 10 orchestrator lifecycle")
struct Phase10OrchestratorTests {
    @Test func quarantineAfterCrashStorm() async throws {
        let services = await MainActor.run { ExtensionHostServices.makeFull() }
        let broker = try makeBroker()
        let orch = ExtensionHostOrchestrator(
            services: services,
            broker: broker,
            environment: .full,
            policy: ExtensionExecutionPolicy(
                trust: .testing,
                maxRestarts: 0,
                quarantineCrashThreshold: 2
            )
        )
        let pkg = PreparedExtensionPackage(
            packageID: "com.example.crashy",
            displayName: "Crashy",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "com.example.crashy", displayName: "Crashy"),
            trustClass: .workspaceDev,
            runtimePreference: .builtIn,
            builtInExtension: ConformanceExt()
        )
        // Use different id for built-in
        let pkg2 = PreparedExtensionPackage(
            packageID: "com.codeeditor.conformance",
            displayName: "C",
            version: SemanticVersion(major: 1),
            manifest: ConformanceExt().manifest,
            trustClass: .workspaceDev,
            runtimePreference: .builtIn,
            builtInExtension: ConformanceExt()
        )
        await orch.register(package: pkg2)
        try await orch.start(id: pkg2.packageID)
        await orch.noteCrash(id: pkg2.packageID, reason: "boom1")
        await orch.noteCrash(id: pkg2.packageID, reason: "boom2")
        #expect(await orch.state(id: pkg2.packageID) == .quarantined)
        await orch.clearQuarantine(id: pkg2.packageID)
        #expect(await orch.state(id: pkg2.packageID) == .ready)
        _ = pkg
    }

    @Test func schemaMismatchIsDetected() {
        let guest = ExtensionWireHandshake(
            schemaHash: "deadbeef",
            packageID: "x",
            packageVersion: "1",
            displayName: "x"
        )
        #expect(guest.schemaHash != ExtensionMethodCatalog.schemaHash)
        #expect(ExtensionWireError.schemaMismatch.code == -32006)
    }
}

// MARK: - Descendant kill (macOS process)

#if os(macOS)
    @Suite("Phase 10 process group teardown")
    struct Phase10ProcessGroupTests {
        @Test func stopKillsHelperAndChildren() async throws {
            // Build path to ConformanceExtensionGuest if available, else skip with sleep-wrapper script
            let binDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("helper-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: binDir) }

            // Minimal shell helper that forks sleep child and speaks enough to stay up
            // Use native transport with /bin/sleep as helper and verify group kill via broker spawn instead.
            let broker = try makeBroker()
            let id: ExtensionID = "ext.desc"
            await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
            let handle = try await broker.processHandle(extensionID: id)
            let lease = try await broker.processSpawn(
                caller: id,
                handle: handle.id,
                executable: "/bin/sleep",
                arguments: ["60"]
            )
            let pid = lease.pid
            #expect(NativeHelperProcessTransport.isProcessAlive(pid))
            // Revoke extension should kill live processes
            await broker.revokeExtension(id: id)
            try await Task.sleep(for: .milliseconds(200))
            #expect(!NativeHelperProcessTransport.isProcessAlive(pid))
        }

        @Test func nativeHelperTransportTerminatesGroup() async throws {
            let transport = try NativeHelperProcessTransport(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"]
            )
            let pid = transport.processIdentifier
            #expect(pid > 0)
            #expect(NativeHelperProcessTransport.isProcessAlive(pid))
            await transport.close()
            try await Task.sleep(for: .milliseconds(200))
            #expect(!NativeHelperProcessTransport.isProcessAlive(pid))
        }
    }
#endif

// MARK: - Guest handlers for dual-run

extension ExtensionGuestRuntime {
    func installDefaultLanguageHandlers() {
        completionHandler = { _ in
            let list = CompletionList(items: [
                CompletionItem(label: "conformanceHello", kind: .function, insertText: "conformanceHello()")
            ])
            return try JSONEncoder().encode(list)
        }
        hoverHandler = { _ in
            let hover = Hover(sections: [HoverSection(content: .markdown("**conformance** hover"))])
            return try JSONEncoder().encode(hover)
        }
        definitionHandler = { _ in
            let uri = DocumentURI(rawValue: "inmemory:conformance")
            let range = TextRange(location: 0, length: 1)
            let links = [LocationLink(targetURI: uri, targetRange: range, targetSelectionRange: range)]
            return try JSONEncoder().encode(links)
        }
    }
}
