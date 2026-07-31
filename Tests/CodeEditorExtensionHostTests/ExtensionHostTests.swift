import Foundation
import Testing
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensions
import CodeEditorLanguageServices
@testable import CodeEditorExtensionHost

struct DummyRemoteExtension: CodeEditorExtension {
    let manifest: ExtensionManifest

    init(
        id: ExtensionID = "remote.dummy",
        api: VersionRange = .from(.phase9API),
        capabilities: Set<HostCapability> = [.languageServices],
        permissions: Set<ExtensionPermission> = []
    ) {
        self.manifest = ExtensionManifest(
            id: id,
            displayName: "Dummy Remote",
            requiredAPIVersion: api,
            activationEvents: [.startup],
            requiredHostCapabilities: capabilities,
            requestedPermissions: permissions
        )
    }

    func activate(in context: any ExtensionAuthorContext) async throws {}
}

/// Creates a host-side transport and starts a peer server that handshakes immediately.
private func makeLivePair(
    extension ext: any CodeEditorExtension,
    configure: ((RemoteExtensionServer) async -> Void)? = nil
) -> (hostTransport: MockRemoteExtensionTransport, server: RemoteExtensionServer) {
    let pair = MockRemoteExtensionTransport.makePair()
    let server = RemoteExtensionServer(extension: ext, transport: pair.remote)
    return (pair.host, server)
}

@Suite("Extension Host RPC")
struct ExtensionHostTests {
    @Test func framingRoundTrip() throws {
        let body = try ExtensionRPCCodec.encode(.cancel(requestID: UUID()))
        let framed = ExtensionRPCFraming.encode(body)
        let decoder = ExtensionRPCFraming.Decoder()
        let messages = decoder.append(framed)
        #expect(messages.count == 1)
        let env = try ExtensionRPCCodec.decode(messages[0])
        if case .cancel = env {
            // ok
        } else {
            Issue.record("expected cancel")
        }
    }

    @Test func incompatibleAPIRejected() async throws {
        let ext = DummyRemoteExtension(
            api: VersionRange(min: SemanticVersion(major: 99), maxExclusive: nil)
        )
        let pair = makeLivePair(extension: ext)
        let serverTask = Task { await pair.server.run() }
        // Give server a moment to send handshake after we start listening
        let process = RemoteExtensionProcess(
            descriptor: RemoteExtensionDescriptor(
                id: ext.manifest.id,
                displayName: "x",
                manifest: ext.manifest,
                launch: .testFactory("t")
            ),
            environment: .full,
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(2)),
            transportFactory: { pair.hostTransport }
        )
        // Start server first so handshake can be buffered, then process
        try await Task.sleep(nanoseconds: 20_000_000)
        do {
            try await process.start()
            Issue.record("expected rejection")
        } catch is ExtensionHostError {
            // rejected / incompatible
        } catch {
            Issue.record("unexpected \(error)")
        }
        await process.shutdown()
        await pair.server.stop()
        serverTask.cancel()
    }

    @Test func remoteCompletionViaRegistry() async throws {
        let ext = DummyRemoteExtension()
        let pair = makeLivePair(extension: ext)
        let serverTask = Task { await pair.server.run() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let registry = LanguageServiceRegistry()
        let services = ExtensionHostServices(languageServiceRegistry: registry)
        let descriptor = RemoteExtensionDescriptor(
            id: ext.manifest.id,
            displayName: ext.manifest.displayName,
            manifest: ext.manifest,
            launch: .testFactory("mock")
        )
        let host = RemoteExtensionHost(
            environment: .full,
            services: services,
            discovery: StaticRemoteExtensionDiscovery(descriptors: [descriptor]),
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(3))
        )
        await host.registerTestFactory(id: "mock") { pair.hostTransport }
        try await host.refreshDiscovery()
        try await host.start(id: ext.manifest.id)

        let languageHost = LanguageServiceHost(registry: registry)
        let list = try await languageHost.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0),
                context: LanguageServiceContext(languageID: "swift")
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.map(\.label).contains("remoteHello"))
        await host.stop(id: ext.manifest.id)
        await pair.server.stop()
        serverTask.cancel()
    }

    @Test func crashUnregistersProviders() async throws {
        let ext = DummyRemoteExtension()
        let pair = makeLivePair(extension: ext)
        let serverTask = Task { await pair.server.run() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let registry = LanguageServiceRegistry()
        let services = ExtensionHostServices(languageServiceRegistry: registry)
        let descriptor = RemoteExtensionDescriptor(
            id: ext.manifest.id,
            displayName: "d",
            manifest: ext.manifest,
            launch: .testFactory("mock")
        )
        let host = RemoteExtensionHost(
            environment: .full,
            services: services,
            discovery: StaticRemoteExtensionDiscovery(descriptors: [descriptor]),
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(3))
        )
        await host.registerTestFactory(id: "mock") { pair.hostTransport }
        try await host.refreshDiscovery()
        try await host.start(id: ext.manifest.id)

        let languageHost = LanguageServiceHost(registry: registry)
        var list = try await languageHost.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0)
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(!list.items.isEmpty)

        await host.stop(id: ext.manifest.id)
        list = try await languageHost.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0)
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.isEmpty)
        await pair.server.stop()
        serverTask.cancel()
    }

    @Test func timeoutOnSlowCompletion() async throws {
        let ext = DummyRemoteExtension()
        let pair = makeLivePair(extension: ext)
        await pair.server.setCompletionDelayNanoseconds(500_000_000)
        let serverTask = Task { await pair.server.run() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let process = RemoteExtensionProcess(
            descriptor: RemoteExtensionDescriptor(
                id: ext.manifest.id,
                displayName: "slow",
                manifest: ext.manifest,
                launch: .testFactory("t")
            ),
            environment: .full,
            policy: RemoteExtensionHostPolicy(requestTimeout: .milliseconds(80)),
            transportFactory: { pair.hostTransport }
        )
        try await process.start()
        do {
            _ = try await process.call(.completion, payload: Data())
            Issue.record("expected timeout")
        } catch let error as ExtensionHostError {
            #expect(error == .timeout)
        }
        await process.shutdown()
        await pair.server.stop()
        serverTask.cancel()
    }

    @Test func payloadTooLargeRejected() async throws {
        let pair = MockRemoteExtensionTransport.makePair()
        let connection = ExtensionRPCConnection(
            transport: pair.host,
            maxPayloadBytes: 100
        )
        await connection.start()
        let huge = Data(repeating: 0x42, count: 1000)
        do {
            _ = try await connection.request(.ping, payload: huge)
            Issue.record("expected payloadTooLarge")
        } catch let error as ExtensionHostError {
            #expect(error == .payloadTooLarge)
        }
        await connection.close()
    }

    @Test func managerModelStartStop() async throws {
        let ext = DummyRemoteExtension()
        let pair = makeLivePair(extension: ext)
        let serverTask = Task { await pair.server.run() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let services = ExtensionHostServices(languageServiceRegistry: LanguageServiceRegistry())
        let descriptor = RemoteExtensionDescriptor(
            id: ext.manifest.id,
            displayName: "mgr",
            manifest: ext.manifest,
            launch: .testFactory("mock")
        )
        let host = RemoteExtensionHost(
            environment: .full,
            services: services,
            discovery: StaticRemoteExtensionDiscovery(descriptors: [descriptor]),
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(3))
        )
        await host.registerTestFactory(id: "mock") { pair.hostTransport }
        try await host.refreshDiscovery()

        let model = await MainActor.run { ExtensionManagerModel(host: host) }
        await model.reload()
        #expect(await MainActor.run { model.rows.count == 1 })
        try await model.start(id: ext.manifest.id)
        await model.reload()
        #expect(await MainActor.run { model.rows.contains(where: { $0.processState == .running }) })
        await model.stop(id: ext.manifest.id)
        await pair.server.stop()
        serverTask.cancel()
    }

    @Test func handshakeGrantsPermissionIntersection() async throws {
        let ext = DummyRemoteExtension(permissions: [.presentUI, .network])
        let env = HostEnvironment(
            capabilities: Set(HostCapability.allCases),
            grantedPermissions: [.presentUI]
        )
        let pair = makeLivePair(extension: ext)
        let serverTask = Task { await pair.server.run() }
        try await Task.sleep(nanoseconds: 20_000_000)

        let process = RemoteExtensionProcess(
            descriptor: RemoteExtensionDescriptor(
                id: ext.manifest.id,
                displayName: "p",
                manifest: ext.manifest,
                launch: .testFactory("t")
            ),
            environment: env,
            policy: RemoteExtensionHostPolicy(requestTimeout: .seconds(3)),
            transportFactory: { pair.hostTransport }
        )
        try await process.start()
        let grants = await process.grantedPermissions
        #expect(grants == [.presentUI])
        #expect(!grants.contains(.network))
        await process.shutdown()
        await pair.server.stop()
        serverTask.cancel()
    }
}

@Suite("Extension Host platform")
struct ExtensionHostPlatformTests {
    @Test func processTransportFailsClosedWhenProfileDeniesNativeHelpers() {
        do {
            _ = try ProcessRemoteExtensionTransport(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                platformProfile: .processUnavailable
            )
            Issue.record("expected unsupportedCapability")
        } catch let error as CodeEditorPlatformError {
            guard case .unsupportedCapability(let kind, _) = error else {
                Issue.record("wrong platform error \(error)")
                return
            }
            #expect(kind == .nativeExtensionProcess)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}
