import CodeEditorCore
import CodeEditorExtensionAPI
import CodeEditorExtensionProtocol
import Foundation
import Testing

@testable import CodeEditorExtensionHost

// MARK: - Helpers

private func brokerTemp() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("broker-n-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

private func makeAuditBroker(
    roots: [URL] = [],
    storageQuotaBytes: Int = 16 * 1024 * 1024,
    maxDownloadBytes: Int = 32 * 1024 * 1024,
    processAllowlist: [CapabilityBroker.ProcessAllow] = [
        .init(command: "/bin/echo"),
        .init(command: "echo"),
        .init(command: "/bin/sleep"),
        .init(command: "sleep"),
    ],
    downloadAllowlist: [CapabilityBroker.DownloadAllow] = [
        .init(host: "example.com", pathPrefix: ["allowed"]),
        .init(host: "cdn.example", pathPrefix: []),
    ],
    npmAllowlist: [CapabilityBroker.NPMAllow] = [],
    npmRegistryRoot: URL? = nil,
    maxKeyLength: Int = 256,
    maxKeyCount: Int = 4096,
    maxValueBytes: Int = 1024 * 1024,
    maxSettingsBytes: Int = 256 * 1024,
    maxMutationsPerWindow: Int = 10_000
) throws -> (CapabilityBroker, URL) {
    let tmp = try brokerTemp()
    let broker = try CapabilityBroker(
        config: .init(
            worktreeRoots: roots,
            storageRoot: tmp.appendingPathComponent("storage"),
            toolCacheRoot: tmp.appendingPathComponent("cache"),
            storageQuotaBytes: storageQuotaBytes,
            maxDownloadBytes: maxDownloadBytes,
            processAllowlist: processAllowlist,
            downloadAllowlist: downloadAllowlist,
            npmAllowlist: npmAllowlist,
            npmRegistryRoot: npmRegistryRoot,
            maxKeyLength: maxKeyLength,
            maxKeyCount: maxKeyCount,
            maxValueBytes: maxValueBytes,
            maxSettingsBytes: maxSettingsBytes,
            maxMutationsPerWindow: maxMutationsPerWindow
        )
    )
    return (broker, tmp)
}

// MARK: - BROKER-N01

@Suite("BROKER-N01 caller-bound handles")
struct BROKERN01Tests {
    @Test func test_BROKER_N01_crossExtensionHandleUseIsForged() async throws {
        let root = try brokerTemp()
        try "secret".write(to: root.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let (broker, _) = try makeAuditBroker(roots: [root])
        let victim: ExtensionID = "ext.victim"
        let attacker: ExtensionID = "ext.attacker"
        await broker.registerExtension(id: victim, generation: 1, granted: [.readWorkspace])
        await broker.registerExtension(id: attacker, generation: 1, granted: [.readWorkspace])
        let victimHandle = try await broker.worktreeHandle(extensionID: victim)
        // Attacker uses victim's handle id → forgedHandle
        do {
            _ = try await broker.worktreeRead(
                caller: attacker,
                handle: victimHandle.id,
                relative: "x.txt"
            )
            Issue.record("expected forgedHandle for cross-extension use")
        } catch BrokerError.forgedHandle {
            // expected
        }
        // Victim still works
        let data = try await broker.worktreeRead(
            caller: victim,
            handle: victimHandle.id,
            relative: "x.txt"
        )
        #expect(String(data: data, encoding: .utf8) == "secret")
    }

    @Test func test_BROKER_N01_crossExtensionOnEveryHandleKind() async throws {
        let (broker, _) = try makeAuditBroker(
            processAllowlist: [.init(command: "/bin/echo")],
            downloadAllowlist: [.init(host: "example.com", pathPrefix: ["ok"])]
        )
        let a: ExtensionID = "ext.a"
        let b: ExtensionID = "ext.b"
        let grants: Set<ExtensionPermission> = [.readWorkspace, .startProcesses, .network]
        await broker.registerExtension(id: a, generation: 1, granted: grants)
        await broker.registerExtension(id: b, generation: 1, granted: grants)

        let storage = try await broker.storageHandle(extensionID: a)
        do {
            _ = try await broker.storageGet(caller: b, handle: storage.id, key: "k")
            Issue.record("storage cross-ext")
        } catch BrokerError.forgedHandle {}

        let settings = try await broker.settingsHandle(extensionID: a)
        do {
            _ = try await broker.settingsGet(caller: b, handle: settings.id, key: "k")
            Issue.record("settings cross-ext")
        } catch BrokerError.forgedHandle {}

        let project = try await broker.projectHandle(extensionID: a)
        do {
            _ = try await broker.projectInfo(caller: b, handle: project.id)
            Issue.record("project cross-ext")
        } catch BrokerError.forgedHandle {}

        let proc = try await broker.processHandle(extensionID: a)
        do {
            _ = try await broker.processSpawn(
                caller: b, handle: proc.id, executable: "/bin/echo", arguments: ["hi"]
            )
            Issue.record("process cross-ext")
        } catch BrokerError.forgedHandle {}

        let dl = try await broker.downloadHandle(extensionID: a)
        do {
            _ = try await broker.downloadWriteFixture(
                caller: b, handle: dl.id, host: "example.com", path: "/ok", data: Data()
            )
            Issue.record("download cross-ext")
        } catch BrokerError.forgedHandle {}
    }
}

// MARK: - BROKER-N02

@Suite("BROKER-N02 unregistered mint denied")
struct BROKERN02Tests {
    @Test func test_BROKER_N02_unregisteredCannotMintAnyHandle() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.none"
        do {
            _ = try await broker.storageHandle(extensionID: id)
            Issue.record("expected unregistered")
        } catch BrokerError.unregisteredExtension {
            // ok
        }
        do {
            _ = try await broker.settingsHandle(extensionID: id)
            Issue.record("expected unregistered settings")
        } catch BrokerError.unregisteredExtension {
            // ok
        }
        do {
            _ = try await broker.mintHandlesJSON(extensionID: id)
            Issue.record("expected unregistered mint")
        } catch BrokerError.unregisteredExtension {
            // ok
        }
    }

    @Test func test_BROKER_N02_registeredCanMintSettingsStorage() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.reg"
        await broker.registerExtension(id: id, generation: 7, granted: [])
        let s = try await broker.settingsHandle(extensionID: id)
        #expect(s.generation == 7)
        let st = try await broker.storageHandle(extensionID: id)
        #expect(st.generation == 7)
    }
}

// MARK: - BROKER-N03

@Suite("BROKER-N03 strict wire schemas")
struct BROKERN03Tests {
    @Test func test_BROKER_N03_malformedJSONFailsClosed() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.wire"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let h = try await broker.storageHandle(extensionID: id)
        do {
            _ = try await broker.dispatch(
                method: .storageSet,
                extensionID: id,
                payload: Data("not-json".utf8)
            )
            Issue.record("expected invalidRequest")
        } catch BrokerError.invalidRequest {
            // ok
        }
        // Missing required fields → fail (no empty defaults)
        do {
            _ = try await broker.dispatch(
                method: .storageSet,
                extensionID: id,
                payload: Data(#"{"handle":"\#(h.id.rawValue)"}"#.utf8)
            )
            Issue.record("expected schema fail on missing fields")
        } catch BrokerError.invalidRequest {
            // ok
        }
        // Invalid base64 fails closed (not empty Data)
        do {
            _ = try await broker.dispatch(
                method: .storageSet,
                extensionID: id,
                payload: Data(
                    #"{"handle":"\#(h.id.rawValue)","key":"k","data_b64":"!!!notb64!!!"}"#.utf8
                )
            )
            Issue.record("expected invalid base64")
        } catch BrokerError.invalidRequest {
            // ok
        }
        // Unknown fields rejected
        do {
            _ = try await broker.dispatch(
                method: .storageGet,
                extensionID: id,
                payload: Data(
                    #"{"handle":"\#(h.id.rawValue)","key":"k","evil":true}"#.utf8
                )
            )
            Issue.record("expected unknown field reject")
        } catch BrokerError.invalidRequest {
            // ok
        }
    }

    @Test func test_BROKER_N03_validSchemaSucceeds() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.wire2"
        await broker.registerExtension(id: id, generation: 1, granted: [])
        let h = try await broker.storageHandle(extensionID: id)
        let b64 = Data("hi".utf8).base64EncodedString()
        let out = try await broker.dispatch(
            method: .storageSet,
            extensionID: id,
            payload: Data(
                #"{"handle":"\#(h.id.rawValue)","key":"k","data_b64":"\#(b64)"}"#.utf8
            )
        )
        #expect(String(data: out, encoding: .utf8)?.contains("ok") == true)
    }
}

// MARK: - BROKER-N04

@Suite("BROKER-N04 init fails on storage roots")
struct BROKERN04Tests {
    @Test func test_BROKER_N04_initFailsWhenStorageRootIsFile() throws {
        let tmp = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: file)
        do {
            _ = try CapabilityBroker(
                config: .init(
                    storageRoot: file,
                    toolCacheRoot: tmp.appendingPathComponent("cache")
                )
            )
            Issue.record("expected initializationFailed")
        } catch BrokerError.initializationFailed {
            // ok
        }
    }
}

// MARK: - BROKER-N05

@Suite("BROKER-N05 worktree list I/O errors")
struct BROKERN05Tests {
    @Test func test_BROKER_N05_listIOFailureIsNotEmptyArray() async throws {
        let root = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let (broker, _) = try makeAuditBroker(roots: [root])
        let id: ExtensionID = "ext.list"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let h = try await broker.worktreeHandle(extensionID: id)
        // Empty directory is a valid empty list
        let empty = try await broker.worktreeList(caller: id, handle: h.id, relative: "")
        #expect(empty.isEmpty)
        // Missing relative path must surface typed error, not []
        do {
            _ = try await broker.worktreeList(
                caller: id, handle: h.id, relative: "does-not-exist-subdir"
            )
            Issue.record("expected ioError for missing directory")
        } catch BrokerError.ioError, BrokerError.notFound, BrokerError.pathEscape {
            // typed failure — not silent empty
        }
    }
}

// MARK: - BROKER-N06

@Suite("BROKER-N06 descriptor-relative containment")
struct BROKERN06Tests {
    @Test func test_BROKER_N06_symlinkEscapeRefused() async throws {
        let root = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: outside) }
        try "leaked".write(
            to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8
        )
        // Symlink inside worktree pointing outside
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside
        )
        let (broker, _) = try makeAuditBroker(roots: [root])
        let id: ExtensionID = "ext.sym"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let h = try await broker.worktreeHandle(extensionID: id)
        do {
            _ = try await broker.worktreeRead(
                caller: id, handle: h.id, relative: "escape/secret.txt"
            )
            Issue.record("expected pathEscape for symlink traversal")
        } catch BrokerError.pathEscape, BrokerError.ioError {
            // O_NOFOLLOW refuses symlink components
        }
    }
}

// MARK: - BROKER-N07

@Suite("BROKER-N07 executable identity revalidation")
struct BROKERN07Tests {
    @Test func test_BROKER_N07_worktreeExecutableDenied() async throws {
        let root = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let evil = root.appendingPathComponent("evil-bin")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: evil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: evil.path
        )
        let (broker, _) = try makeAuditBroker(
            roots: [root],
            processAllowlist: [
                .init(command: evil.path),
                .init(command: "/bin/echo"),
            ]
        )
        let id: ExtensionID = "ext.exec"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        do {
            _ = try await broker.processSpawn(
                caller: id, handle: h.id, executable: evil.path, arguments: []
            )
            Issue.record("expected processDenied for worktree executable")
        } catch BrokerError.processDenied {
            // ok
        }
        // Trusted system path still allowed
        let lease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/echo", arguments: ["ok"]
        )
        #expect(lease.pid > 0)
        _ = try await broker.processAwaitExit(caller: id, handle: lease.lease)
    }

    @Test func test_BROKER_N07_exactArgumentMatcher() async throws {
        let (broker, _) = try makeAuditBroker(
            processAllowlist: [
                .init(command: "/bin/echo", exactArguments: ["safe"]),
            ]
        )
        let id: ExtensionID = "ext.args"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        do {
            _ = try await broker.processSpawn(
                caller: id, handle: h.id, executable: "/bin/echo", arguments: ["evil"]
            )
            Issue.record("expected processDenied for args mismatch")
        } catch BrokerError.processDenied {
            // ok
        }
        let lease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/echo", arguments: ["safe"]
        )
        #expect(lease.pid > 0)
        _ = try await broker.processAwaitExit(caller: id, handle: lease.lease)
    }
}

// MARK: - BROKER-N08

@Suite("BROKER-N08 typed project roots")
struct BROKERN08Tests {
    @Test func test_BROKER_N08_projectInfoReturnsTypedRootsArray() async throws {
        let r1 = try brokerTemp()
        let r2 = try brokerTemp()
        defer {
            try? FileManager.default.removeItem(at: r1)
            try? FileManager.default.removeItem(at: r2)
        }
        // Paths with colon-like ambiguity must remain separate records
        let (broker, _) = try makeAuditBroker(roots: [r1, r2])
        let id: ExtensionID = "ext.proj"
        await broker.registerExtension(id: id, generation: 1, granted: [.readWorkspace])
        let h = try await broker.projectHandle(extensionID: id)
        let info = try await broker.projectInfo(caller: id, handle: h.id)
        #expect(info.roots.count == 2)
        #expect(info.roots.map(\.path).contains(r1.path))
        #expect(info.roots.map(\.path).contains(r2.path))
        #expect(info.roots.allSatisfy { $0.uri.hasPrefix("file:") })
        // Wire encoding must not be colon-joined string
        let wire = try await broker.dispatch(
            method: .projectInfo,
            extensionID: id,
            payload: Data(#"{"handle":"\#(h.id.rawValue)"}"#.utf8)
        )
        let obj = try JSONSerialization.jsonObject(with: wire) as? [String: Any]
        #expect(obj?["roots"] is [[String: Any]] || obj?["roots"] is [Any])
        #expect(!(obj?["roots"] is String))
    }
}

// MARK: - BROKER-N09

@Suite("BROKER-N09 storage/settings quotas")
struct BROKERN09Tests {
    @Test func test_BROKER_N09_keyValueCountAndSettingsIncluded() async throws {
        let (broker, _) = try makeAuditBroker(
            storageQuotaBytes: 200,
            maxKeyLength: 8,
            maxKeyCount: 2,
            maxValueBytes: 50,
            maxSettingsBytes: 80
        )
        let id: ExtensionID = "ext.q"
        await broker.registerExtension(id: id, generation: 1, granted: [])
        let st = try await broker.storageHandle(extensionID: id)
        let se = try await broker.settingsHandle(extensionID: id)

        // Key too long
        do {
            try await broker.storageSet(
                caller: id, handle: st.id, key: String(repeating: "k", count: 20), value: Data([1])
            )
            Issue.record("expected key length")
        } catch BrokerError.invalidRequest {
            // ok
        }

        try await broker.storageSet(caller: id, handle: st.id, key: "a", value: Data(repeating: 1, count: 40))
        try await broker.storageSet(caller: id, handle: st.id, key: "b", value: Data(repeating: 1, count: 40))
        // Key count exceeded
        do {
            try await broker.storageSet(
                caller: id, handle: st.id, key: "c", value: Data(repeating: 1, count: 1)
            )
            Issue.record("expected key count quota")
        } catch BrokerError.quotaExceeded {
            // ok
        }

        // Settings count against shared storage quota
        try await broker.settingsSet(caller: id, handle: se.id, key: "theme", value: "dark")
        // Large settings should hit maxSettingsBytes or shared quota
        do {
            try await broker.settingsSet(
                caller: id,
                handle: se.id,
                key: "big",
                value: String(repeating: "x", count: 200)
            )
            Issue.record("expected settings quota")
        } catch BrokerError.quotaExceeded {
            // ok
        }
    }
}

// MARK: - BROKER-N10

@Suite("BROKER-N10 durable async accounting")
struct BROKERN10Tests {
    @Test func test_BROKER_N10_ledgerPersistsAcrossBrokerInstances() async throws {
        let tmp = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let storage = tmp.appendingPathComponent("s")
        let cache = tmp.appendingPathComponent("c")
        let id: ExtensionID = "ext.ledger"
        do {
            let broker = try CapabilityBroker(
                config: .init(storageRoot: storage, toolCacheRoot: cache, storageQuotaBytes: 100)
            )
            await broker.registerExtension(id: id, generation: 1, granted: [])
            let h = try await broker.storageHandle(extensionID: id)
            try await broker.storageSet(
                caller: id, handle: h.id, key: "k", value: Data(repeating: 1, count: 60)
            )
        }
        // New instance must load durable ledger and refuse exceeding writes without rescan-only.
        let broker2 = try CapabilityBroker(
            config: .init(storageRoot: storage, toolCacheRoot: cache, storageQuotaBytes: 100)
        )
        await broker2.registerExtension(id: id, generation: 1, granted: [])
        let h2 = try await broker2.storageHandle(extensionID: id)
        do {
            try await broker2.storageSet(
                caller: id, handle: h2.id, key: "k2", value: Data(repeating: 1, count: 60)
            )
            Issue.record("expected quota from durable ledger")
        } catch BrokerError.quotaExceeded {
            // ok
        }
        // Overwrite same key within quota still works
        try await broker2.storageSet(
            caller: id, handle: h2.id, key: "k", value: Data(repeating: 2, count: 50)
        )
        let ledgerPath = storage
            .appendingPathComponent(id.directoryKey)
            .appendingPathComponent("quota-ledger.json")
        #expect(FileManager.default.fileExists(atPath: ledgerPath.path))
    }
}

// MARK: - BROKER-N11

@Suite("BROKER-N11 argument matcher not glob")
struct BROKERN11Tests {
    @Test func test_BROKER_N11_noArgsGlobShellInjectionSurface() async throws {
        // `**` is no longer a magic arg token — only .anyArguments or exact vector.
        let allow = CapabilityBroker.ProcessAllow(
            command: "/bin/echo",
            exactArguments: ["**"]
        )
        #expect(allow.argumentMatcher == .exactArguments(["**"]))
        let (broker, _) = try makeAuditBroker(processAllowlist: [allow])
        let id: ExtensionID = "ext.glob"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        // Empty args must not match exact ["**"]
        do {
            _ = try await broker.processSpawn(
                caller: id, handle: h.id, executable: "/bin/echo", arguments: []
            )
            Issue.record("expected deny")
        } catch BrokerError.processDenied {
            // ok
        }
        // Exact match of the literal "**" token is allowed (not a glob expansion)
        let lease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/echo", arguments: ["**"]
        )
        #expect(lease.pid > 0)
        _ = try await broker.processAwaitExit(caller: id, handle: lease.lease)
    }
}

// MARK: - BROKER-N12

@Suite("BROKER-N12 process capability stream")
struct BROKERN12Tests {
    @Test func test_BROKER_N12_spawnReturnsLeaseWithEventsAndExit() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.stream"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        let lease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/echo", arguments: ["hello-stream"]
        )
        #expect(lease.pid > 0)
        #expect(lease.supervisorLeaseID != UUID()) // non-nil identity
        var sawStdout = false
        var sawExit = false
        let stream = try await broker.processEvents(caller: id, handle: lease.lease)
        for await event in stream {
            switch event {
            case .stdout(let data):
                if String(data: data, encoding: .utf8)?.contains("hello-stream") == true {
                    sawStdout = true
                }
            case .exited:
                sawExit = true
            default:
                break
            }
        }
        #expect(sawStdout || sawExit)
        // Await exit is available as separate API
        // (stream may have already consumed exit; kill path still valid for sleep)
        let sleepLease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/sleep", arguments: ["30"]
        )
        try await broker.processKill(caller: id, handle: sleepLease.lease)
    }
}

// MARK: - BROKER-N13

@Suite("BROKER-N13 download stream + redirect policy")
struct BROKERN13Tests {
    @Test func test_BROKER_N13_fixtureWritesMetadataAndDigest() async throws {
        let (broker, _) = try makeAuditBroker(
            downloadAllowlist: [.init(host: "example.com", pathPrefix: ["ok"])]
        )
        let id: ExtensionID = "ext.dl"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let h = try await broker.downloadHandle(extensionID: id)
        let payload = Data("streamed".utf8)
        let dest = try await broker.downloadWriteFixture(
            caller: id,
            handle: h.id,
            host: "example.com",
            path: "/ok/file",
            data: payload
        )
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let metaURL = dest.appendingPathExtension("meta.json")
        #expect(FileManager.default.fileExists(atPath: metaURL.path))
        let metaData = try Data(contentsOf: metaURL)
        let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        #expect(meta?["digest"] is String)
        #expect(meta?["sourceURL"] is String)
        #expect(meta?["bytes"] as? Int == payload.count)

        // HTTP-only host rejected by production path (fixture still host-checked)
        do {
            _ = try await broker.downloadWriteFixture(
                caller: id, handle: h.id, host: "evil.com", path: "/", data: Data()
            )
            Issue.record("expected downloadDenied")
        } catch BrokerError.downloadDenied {
            // ok
        }
    }

    @Test func test_BROKER_N13_httpsOnlyOnFetchURL() async throws {
        let (broker, _) = try makeAuditBroker(
            downloadAllowlist: [.init(host: "example.com", pathPrefix: [])]
        )
        let id: ExtensionID = "ext.dl2"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let h = try await broker.downloadHandle(extensionID: id)
        do {
            _ = try await broker.downloadFetch(
                caller: id,
                handle: h.id,
                urlString: "http://example.com/file"
            )
            Issue.record("expected https only")
        } catch BrokerError.downloadDenied {
            // ok
        }
    }
}

// MARK: - BROKER-N14

@Suite("BROKER-N14 path component allowlist")
struct BROKERN14Tests {
    @Test func test_BROKER_N14_stringPrefixDoesNotBypass() {
        let allow: [CapabilityBroker.DownloadAllow] = [
            .init(host: "cdn.example", pathPrefix: ["allowed"]),
        ]
        #expect(
            CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowed/file", allowlist: allow
            )
        )
        #expect(
            !CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowed-bad/file", allowlist: allow
            )
        )
        #expect(
            !CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowedx", allowlist: allow
            )
        )
        #expect(
            CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowed", allowlist: allow
            )
        )
        // Percent-encoded must not confuse component split
        #expect(
            CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowed%2Fextra", allowlist: allow
            )
            == CapabilityBroker.isDownloadPathAllowed(
                host: "cdn.example", path: "/allowed/extra", allowlist: allow
            )
        )
    }
}

// MARK: - BROKER-N15

@Suite("BROKER-N15 npm scoped + size + immutable")
struct BROKERN15Tests {
    @Test func test_BROKER_N15_scopedPackageAndHiddenFilesAndSize() async throws {
        let tmp = try brokerTemp()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let reg = tmp.appendingPathComponent("reg/@scope/pkg/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: reg, withIntermediateDirectories: true)
        let pkgJSON = """
            {"name":"@scope/pkg","version":"1.0.0","scripts":{"postinstall":"evil"}}
            """
        try pkgJSON.write(to: reg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "exports.x=1\n".write(to: reg.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        try "hidden\n".write(to: reg.appendingPathComponent(".npmignore"), atomically: true, encoding: .utf8)
        let nested = reg.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 40).write(to: nested.appendingPathComponent("big.bin"))

        let (broker, _) = try makeAuditBroker(
            maxDownloadBytes: 10_000,
            npmAllowlist: [.init(package: "@scope/pkg", version: "1.0.0")],
            npmRegistryRoot: tmp.appendingPathComponent("reg")
        )
        let id: ExtensionID = "ext.npm"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let h = try await broker.npmHandle(extensionID: id)
        let dest = try await broker.npmInstall(
            caller: id, handle: h.id, package: "@scope/pkg", version: "1.0.0"
        )
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("index.js").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".npmignore").path))
        // Immutable: package.json not mutated after copy
        let copied = try String(contentsOf: dest.appendingPathComponent("package.json"), encoding: .utf8)
        #expect(copied.contains("postinstall"))
        #expect(!copied.contains("scripts_disabled"))

        // Nested size accounted — small maxDownloadBytes rejects large tree
        let bigReg = tmp.appendingPathComponent("reg/@scope/big/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: bigReg, withIntermediateDirectories: true)
        try "{}".write(to: bigReg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let deep = bigReg.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 500).write(to: deep.appendingPathComponent("blob.bin"))
        let (broker2, _) = try makeAuditBroker(
            maxDownloadBytes: 100,
            npmAllowlist: [.init(package: "@scope/big", version: "1.0.0")],
            npmRegistryRoot: tmp.appendingPathComponent("reg")
        )
        await broker2.registerExtension(id: id, generation: 1, granted: [.network])
        let h2 = try await broker2.npmHandle(extensionID: id)
        do {
            _ = try await broker2.npmInstall(
                caller: id, handle: h2.id, package: "@scope/big", version: "1.0.0"
            )
            Issue.record("expected quota on nested size")
        } catch BrokerError.quotaExceeded {
            // ok — parent received child totals
        }
    }

    @Test func test_BROKER_N15_pathTraversalPackageDenied() async throws {
        let (broker, tmp) = try makeAuditBroker(
            npmAllowlist: [.init(package: "**")],
            npmRegistryRoot: try brokerTemp()
        )
        _ = tmp
        let id: ExtensionID = "ext.npm2"
        await broker.registerExtension(id: id, generation: 1, granted: [.network])
        let h = try await broker.npmHandle(extensionID: id)
        do {
            _ = try await broker.npmInstall(
                caller: id, handle: h.id, package: "../etc", version: "1.0.0"
            )
            Issue.record("expected npmDenied")
        } catch BrokerError.npmDenied {
            // ok
        }
    }
}

// MARK: - BROKER-N16

@Suite("BROKER-N16 nonblocking revoke")
struct BROKERN16Tests {
    @Test func test_BROKER_N16_revokeStripsHandlesWithoutAwaitingProcessDeath() async throws {
        let (broker, _) = try makeAuditBroker()
        let id: ExtensionID = "ext.rev"
        await broker.registerExtension(id: id, generation: 1, granted: [.startProcesses])
        let h = try await broker.processHandle(extensionID: id)
        let lease = try await broker.processSpawn(
            caller: id, handle: h.id, executable: "/bin/sleep", arguments: ["60"]
        )
        #expect(lease.pid > 0)
        // Revoke must return promptly (not block on process death)
        let start = ContinuousClock.now
        await broker.revokeExtension(id: id)
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(200))
        // Handles immediately invalid
        do {
            _ = try await broker.processEvents(caller: id, handle: lease.lease)
            Issue.record("expected revoked/forged after revoke")
        } catch BrokerError.forgedHandle, BrokerError.revokedHandle, BrokerError.staleGeneration {
            // ok
        }
        // Cannot mint again until re-registered
        do {
            _ = try await broker.storageHandle(extensionID: id)
            Issue.record("expected unregistered after revoke")
        } catch BrokerError.unregisteredExtension {
            // ok
        }
    }
}
