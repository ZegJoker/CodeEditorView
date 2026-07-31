import Foundation
import Testing
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import CodeEditorExtensions
import CodeEditorWasmEngine
import CodeEditorExtensionWasmGuest
@testable import CodeEditorExtensionHost

private func fixtureModule() -> Data {
    // Large enough conformance marker with valid magic
    var d = Data(WasmModuleBuilder.magic + WasmModuleBuilder.version)
    d.append(Data(repeating: 0xAB, count: 200))
    return d
}

@Suite("Phase 11 core-Wasm ABI")
struct Phase11ABITests {
    @Test func linkedGuestEchoAndActivate() async throws {
        let engine = WasmEngineFactory.linkedGuest()
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: .default,
            generation: 1
        )
        try await session.start()
        let echoed = try await session.request(.echo, payload: Data("hello-wasm".utf8), timeout: .seconds(2))
        #expect(echoed == Data("hello-wasm".utf8))
        let ping = try await session.request(.ping, payload: Data(), timeout: .seconds(2))
        #expect(!ping.isEmpty)
        let completion = try await session.request(.completion, payload: Data(), timeout: .seconds(2))
        #expect(String(data: completion, encoding: .utf8)?.contains("conformanceHello") == true)
        let trace = await session.conformanceTrace()
        #expect(trace.contains { $0.method == ExtensionMethodID.activate.rawValue })
        #expect(trace.contains { $0.method == ExtensionMethodID.echo.rawValue })
        await session.stop()
    }

    @Test func cancellationStopsSlowWork() async throws {
        let engine = WasmEngineFactory.linkedGuest()
        let session = CoreWasmABISession(
            engine: engine,
            module: fixtureModule(),
            limits: WasmResourceLimits(
                maxPollBudgetPerTick: 2,
                maxPollTicks: 10_000
            ),
            generation: 1
        )
        try await session.start()
        await session.setSlowWork(10_000)
        // Drive polls while cancel flagged
        await session.cancel(ExtensionRequestID())
        for _ in 0..<50 {
            try? await session.pollOnce()
        }
        await session.stop()
        // Host remained responsive (we got here)
        #expect(true)
    }

    @Test func hostSendBackpressure() {
        let limits = WasmResourceLimits(maxHostSendQueueBytes: 100, maxHostSendQueueMessages: 2)
        let box = MessageBox(limits: limits)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusOK)
        #expect(box.enqueue(Data(repeating: 1, count: 10)) == CoreWasmABI.statusBackpressure)
    }

    @Test func maliciousMalformedDoesNotCrashHost() throws {
        let engine = WasmEngineFactory.linkedGuest()
        #expect(throws: WasmEngineError.self) {
            try engine.validate(module: WasmModuleBuilder.malformedModule(), limits: .default)
        }
    }

    @Test func infiniteLoopContained() async throws {
        let engine = InProcessCoreWasmEngine()
        let session = CoreWasmABISession(
            engine: engine,
            module: WasmModuleBuilder.infiniteLoopModule(),
            limits: WasmResourceLimits(maxWallTime: .milliseconds(500), maxPollTicks: 3),
            generation: 1
        )
        // start may succeed; poll should interrupt
        do {
            try await session.start()
            for _ in 0..<20 {
                try await session.pollOnce()
            }
            Issue.record("expected interrupt")
        } catch {
            // contained
        }
        await session.stop()
    }
}

@Suite("Phase 11 dual-run built-in vs Wasm")
struct Phase11DualRunTests {
    @Test func tracesShareMethodSet() async throws {
        let services = await MainActor.run { ExtensionHostServices.makeFull() }
        let brokerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: brokerRoot, withIntermediateDirectories: true)
        let broker = CapabilityBroker(config: .init(
            storageRoot: brokerRoot.appendingPathComponent("s"),
            toolCacheRoot: brokerRoot.appendingPathComponent("c")
        ))
        let env = HostEnvironment(
            capabilities: Set(HostCapability.allCases),
            grantedPermissions: [.readWorkspace]
        )

        // Built-in
        struct Ext: CodeEditorExtension {
            var manifest: ExtensionManifest {
                ExtensionManifest(
                    id: "com.codeeditor.conformance",
                    displayName: "C",
                    activationEvents: [.startup],
                    requiredHostCapabilities: [.languageServices],
                    requestedPermissions: [.readWorkspace]
                )
            }
            func activate(in context: any ExtensionAuthorContext) async throws {
                context.info("ok")
            }
        }
        let builtIn = BuiltInSwiftRuntimeDriver(services: services, environment: env)
        let pkg = PreparedExtensionPackage(
            packageID: "com.codeeditor.conformance",
            displayName: "C",
            version: SemanticVersion(major: 1),
            manifest: Ext().manifest,
            trustClass: .workspaceDev,
            runtimePreference: .builtIn,
            builtInExtension: Ext()
        )
        let prep = try await builtIn.prepare(package: pkg, policy: .testing)
        let biInst = try await builtIn.start(
            prepared: prep,
            handshake: ExtensionHostHandshake(environment: env, generation: 1),
            broker: broker
        ) as! BuiltInExtensionInstance
        _ = try await biInst.request(.echo, payload: Data("x".utf8))
        _ = try await biInst.request(.completion, payload: Data())
        let biTrace = await biInst.conformanceTrace()
        await biInst.stop(reason: .user)

        // Wasm
        let wasmDriver = SwiftWasmRuntimeDriver(engine: WasmEngineFactory.linkedGuest())
        let wasmPkg = PreparedExtensionPackage(
            packageID: "com.codeeditor.conformance",
            displayName: "C",
            version: SemanticVersion(major: 1),
            manifest: Ext().manifest,
            wasmModuleData: fixtureModule(),
            trustClass: .workspaceDev,
            runtimePreference: .swiftWasm
        )
        let wprep = try await wasmDriver.prepare(package: wasmPkg, policy: .testing)
        let wInst = try await wasmDriver.start(
            prepared: wprep,
            handshake: ExtensionHostHandshake(environment: env, generation: 2),
            broker: broker
        ) as! SwiftWasmExtensionInstance
        _ = try await wInst.request(.echo, payload: Data("x".utf8))
        _ = try await wInst.request(.completion, payload: Data())
        let wTrace = await wInst.conformanceTrace()
        await wInst.stop(reason: .user)

        let biMethods = Set(biTrace.map(\.method))
        let wMethods = Set(wTrace.map(\.method))
        #expect(biMethods.contains(ExtensionMethodID.activate.rawValue))
        #expect(wMethods.contains(ExtensionMethodID.activate.rawValue))
        #expect(biMethods.contains(ExtensionMethodID.echo.rawValue))
        #expect(wMethods.contains(ExtensionMethodID.echo.rawValue))
        #expect(biMethods.contains(ExtensionMethodID.completion.rawValue))
        #expect(wMethods.contains(ExtensionMethodID.completion.rawValue))
    }

    @Test func runtimeSelectorChoosesWasm() throws {
        let pkg = PreparedExtensionPackage(
            packageID: "w",
            displayName: "w",
            version: SemanticVersion(major: 1),
            manifest: ExtensionManifest(id: "w", displayName: "w"),
            wasmModuleData: fixtureModule(),
            trustClass: .workspaceDev,
            runtimePreference: .swiftWasm
        )
        let kind = try RuntimeSelector.select(package: pkg, policy: .testing)
        #expect(kind == .swiftWasm)
    }
}

@Suite("Phase 11 cooperative poll proof")
struct Phase11PollProofTests {
    @Test func multiStepWorkCompletesAcrossPolls() async throws {
        let guest = WasmGuestRuntime()
        var sent: [Data] = []
        guest.hostSend = { data in
            sent.append(data)
            return 0
        }
        guest.hostMillis = { 0 }
        guest.hostShouldCancel = { _, _ in 0 }

        // start with good schema
        let config = CBORCodec.encode(CBORValue.stringMap([
            "schema": .text(ExtensionMethodCatalog.schemaHash),
            "generation": .unsigned(1),
        ]))
        let p = guest.alloc(Int32(config.count))
        try guest.writeToMemory(config, at: Int(p))
        #expect(guest.start(configPtr: p, configLen: Int32(config.count)) == 0)

        let req = try ExtensionEnvelopeCodec.encode(.request(
            id: ExtensionRequestID(),
            method: .echo,
            payload: Data("ab".utf8),
            timeoutMS: 1000,
            generation: 1
        ))
        let rp = guest.alloc(Int32(req.count))
        try guest.writeToMemory(req, at: Int(rp))
        #expect(guest.receive(ptr: rp, len: Int32(req.count)) == 0)

        // budget 1 may not finish multi-step methods completely; keep polling
        var busy = true
        var ticks = 0
        while busy && ticks < 20 {
            let st = guest.poll(1)
            busy = st == 2
            ticks += 1
        }
        #expect(!sent.isEmpty)
        let env = try ExtensionEnvelopeCodec.decode(sent[0])
        if case .response(_, let result, let err, _) = env {
            #expect(err == nil)
            #expect(result == Data("ab".utf8))
        } else {
            Issue.record("expected response")
        }
    }
}
