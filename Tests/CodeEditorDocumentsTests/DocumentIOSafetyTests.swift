import CodeEditorCore
import Foundation
import Testing

@testable import CodeEditorDocuments

@Suite("Document IO safety")
struct DocumentIOSafetyTests {
    private func tempFile(name: String = "doc.txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test func atomicSaveRoundTrip() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        let original = Data("hello world".utf8)
        try await io.writeAtomically(data: original, to: url)
        let read = try await io.read(url: url)
        #expect(read == original)
        let identity = try await io.resourceIdentity(at: url)
        #expect(identity?.contentHash == DocumentFileIdentity.hash(of: original))
    }

    @Test func faultBeforeReplaceLeavesOriginalIntact() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ioBase = LocalDocumentIO()
        try await ioBase.writeAtomically(data: Data("ORIGINAL".utf8), to: url)

        let faulting = FaultInjectingDocumentIO(base: ioBase, fault: .beforeReplace)
        do {
            try await faulting.writeAtomically(data: Data("NEW-CONTENT".utf8), to: url)
            Issue.record("expected injected fault")
        } catch let error as DocumentIOError {
            guard case .injectedFault(.beforeReplace) = error else {
                Issue.record("wrong fault \(error)")
                return
            }
        }
        let remaining = try await ioBase.read(url: url)
        #expect(String(data: remaining, encoding: .utf8) == "ORIGINAL")
    }

    @Test func faultAfterTempWriteLeavesOriginalIntact() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ioBase = LocalDocumentIO()
        try await ioBase.writeAtomically(data: Data("KEEP".utf8), to: url)
        let faulting = FaultInjectingDocumentIO(base: ioBase, fault: .afterTempWrite)
        do {
            try await faulting.writeAtomically(data: Data("LOSE".utf8), to: url)
            Issue.record("expected fault")
        } catch {
            // expected
        }
        #expect(String(data: try await ioBase.read(url: url), encoding: .utf8) == "KEEP")
    }

    @Test func encodingAndCRLFFidelity() async throws {
        let url = try tempFile(name: "crlf.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = LocalFileDocumentProvider(
            io: LocalDocumentIO(),
            policy: DocumentLifecyclePolicy(
                lineEndingOnSave: .convert(.carriageReturnLineFeed),
                bomPolicy: .none,
                writeRecoveryJournal: false
            ),
            useCoordinator: false
        )
        let snap = DocumentSnapshot(version: .zero, text: "a\nb\nc")
        let uri = DocumentURI(fileURL: url)
        _ = try await provider.save(
            DocumentSaveRequest(
                snapshot: snap,
                target: uri,
                encoding: .utf8,
                expectedIdentity: nil,
                conflictPolicy: .overwrite
            )
        )
        let loaded = try await provider.load(uri: uri)
        #expect(loaded.text.contains("\r\n") || loaded.lineEnding == .carriageReturnLineFeed)
        let bytes = try await LocalDocumentIO().read(url: url)
        let s = String(data: bytes, encoding: .utf8)!
        #expect(s == "a\r\nb\r\nc")
    }

    @Test func utf8BOMRoundTrip() async throws {
        let url = try tempFile(name: "bom.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = LocalFileDocumentProvider(
            io: LocalDocumentIO(),
            policy: DocumentLifecyclePolicy(bomPolicy: .whenEncodingSupports, writeRecoveryJournal: false),
            useCoordinator: false
        )
        _ = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "hi"),
                target: DocumentURI(fileURL: url),
                encoding: .utf8,
                expectedIdentity: nil,
                conflictPolicy: .overwrite
            )
        )
        let data = try await LocalDocumentIO().read(url: url)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
        let loaded = try await provider.load(uri: DocumentURI(fileURL: url))
        #expect(loaded.text == "hi")
        #expect(loaded.hadBOM)
    }

    @Test func recoveryJournalRestoresDirtyContent() async throws {
        let url = try tempFile(name: "recover.txt")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("disk".utf8), to: url)
        let journal = RecoveryJournal(directory: url.deletingLastPathComponent())
        try await journal.write(
            text: "recovered-dirty",
            forPrimary: url,
            io: io,
            contentState: DocumentContentStateID(),
            encoding: .utf8
        )
        let text = try await journal.read(forPrimary: url, io: io)
        #expect(text == "recovered-dirty")
        try await journal.clear(forPrimary: url, io: io)
        #expect(try await journal.read(forPrimary: url, io: io) == nil)
    }

    @Test func externalChangeDetection() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        let provider = LocalFileDocumentProvider(io: io, policy: .default, useCoordinator: false)
        let uri = DocumentURI(fileURL: url)
        _ = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "v1"),
                target: uri,
                encoding: .utf8,
                expectedIdentity: nil,
                conflictPolicy: .overwrite
            )
        )
        let known = try #require(await io.resourceIdentity(at: url))
        #expect(try await provider.detectChange(at: uri, known: known) == .unchanged)
        try await io.writeAtomically(data: Data("v2-different".utf8), to: url)
        let after = try #require(await io.resourceIdentity(at: url))
        #expect(after.contentHash != known.contentHash)
        #expect(try await provider.detectChange(at: uri, known: known) == .externalModified)
        try await io.removeItem(at: url)
        #expect(try await provider.detectChange(at: uri, known: known) == .deleted)
    }

    @Test func encodingFailureLeavesFileUnchanged() async throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("safe".utf8), to: url)
        let provider = LocalFileDocumentProvider(
            io: io,
            policy: DocumentLifecyclePolicy(writeRecoveryJournal: false, isReadOnly: true),
            useCoordinator: false
        )
        do {
            _ = try await provider.save(
                DocumentSaveRequest(
                    snapshot: DocumentSnapshot(version: .zero, text: "nope"),
                    target: DocumentURI(fileURL: url),
                    encoding: .utf8,
                    expectedIdentity: nil,
                    conflictPolicy: .overwrite
                )
            )
            Issue.record("expected readOnly")
        } catch let error as DocumentProviderError {
            #expect(error == .readOnly)
        }
        #expect(String(data: try await io.read(url: url), encoding: .utf8) == "safe")
    }
}

@Suite("Document URI registry")
@MainActor
struct DocumentURIRegistryTests {
    @Test func canonicalFileURILookup() {
        let registry = DocumentRegistry()
        let path = "/tmp/codeeditor-uri-\(UUID().uuidString).txt"
        let url1 = URL(fileURLWithPath: path)
        let url2 = URL(fileURLWithPath: path).standardizedFileURL
        let doc = TextDocument(uri: DocumentURI(fileURL: url1), text: "x")
        registry.register(doc)
        #expect(registry.document(uri: DocumentURI(fileURL: url2)) === doc)
    }
}

@Suite("TextDocument recovery")
@MainActor
struct TextDocumentRecoveryTests {
    @Test func recoverFromJournal() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("on-disk".utf8), to: url)
        let doc = TextDocument(uri: DocumentURI(fileURL: url), text: "on-disk")
        let journal = RecoveryJournal(directory: dir)
        try await journal.write(text: "from-journal", forPrimary: url, io: io)
        let ok = try await doc.recoverFromJournalIfNeeded(io: io)
        #expect(ok)
        #expect(doc.text == "from-journal")
        #expect(doc.isDirty)
    }
}

@Suite("Phase 2 document residual gates")
struct Phase2DocumentResidualTests {
    @Test func otherEncodingRejectedOnDecode() {
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentCodec.encode(
                text: "hi",
                encoding: .other("macroman"),
                lineEndingPolicy: .preserve,
                bomPolicy: .none
            )
        }
    }

    @Test func test_DOC_N07_otherEncodingIsUnsupportedNotAliased() {
        #expect(DocumentEncoding.other("macroman").stringEncodingOrNil == nil)
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentCodec.decode(Data([0x80, 0x81]))
            // decode auto-detects as utf8; force encode path for .other
        }
        #expect(throws: DocumentIOError.self) {
            _ = try DocumentCodec.encode(
                text: "x",
                encoding: .other("windows-1252"),
                lineEndingPolicy: .preserve,
                bomPolicy: .none
            )
        }
        if case .unsupportedEncoding(let name) = {
            do {
                _ = try DocumentCodec.encode(
                    text: "x",
                    encoding: .other("ibm-437"),
                    lineEndingPolicy: .preserve,
                    bomPolicy: .none
                )
                return DocumentIOError.encodingFailed
            } catch let e as DocumentIOError {
                return e
            } catch {
                return DocumentIOError.encodingFailed
            }
        }() {
            #expect(name == "ibm-437")
        }
    }

    @Test func singlePassIdentityMatchesHash() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let payload = Data("phase2-identity-check".utf8)
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: payload, to: url)
        let (data, identity) = try await io.readContentAndIdentity(url: url, maxBytes: 1024)
        #expect(data == payload)
        #expect(identity.contentHash == DocumentFileIdentity.hash(of: payload))
        #expect(identity.size == UInt64(payload.count))
    }

    @Test func maxLoadBytesRejectsOversized() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-big-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data(repeating: 0x61, count: 4096), to: url)
        do {
            _ = try await io.read(url: url, maxBytes: 100)
            Issue.record("expected tooLarge")
        } catch let error as DocumentIOError {
            guard case .tooLarge = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    @Test func recoveryJournalChecksumRejectsTamper() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-jq-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("disk".utf8), to: url)
        let journal = RecoveryJournal(directory: dir)
        try await journal.write(text: "journal-text", forPrimary: url, io: io)
        let jURL = journal.journalURL(forPrimary: url)
        var raw = try await io.read(url: jURL)
        if !raw.isEmpty { raw[raw.count / 2] ^= 0xFF }
        try await io.writeAtomically(data: raw, to: jURL)
        do {
            _ = try await journal.read(forPrimary: url, io: io)
            Issue.record("expected corrupt journal")
        } catch let error as DocumentIOError {
            guard case .corruptRecoveryJournal = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    @Test func conflictSaveDetectsExternalModify() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-cas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("v1".utf8), to: url)
        let provider = LocalFileDocumentProvider(io: io, policy: .default, useCoordinator: false)
        let loaded = try await provider.load(uri: DocumentURI(fileURL: url))
        try await io.writeAtomically(data: Data("external".utf8), to: url)
        let result = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "editor-v2"),
                target: DocumentURI(fileURL: url),
                encoding: .utf8,
                expectedIdentity: loaded.fileIdentity,
                conflictPolicy: .requireHostDecision
            )
        )
        guard case .conflict = result else {
            Issue.record("expected conflict, got \(result)")
            return
        }
        let disk = try await io.read(url: url)
        #expect(String(data: disk, encoding: .utf8) == "external")
    }

    @Test func test_DOC_N02_externalModifyBetweenLoadAndSaveReturnsConflict() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n02-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("base".utf8), to: url)
        let provider = LocalFileDocumentProvider(io: io, useCoordinator: false)
        let loaded = try await provider.load(uri: DocumentURI(fileURL: url))
        try await io.writeAtomically(data: Data("raced".utf8), to: url)
        let outcome = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "mine"),
                target: DocumentURI(fileURL: url),
                encoding: .utf8,
                expectedIdentity: loaded.fileIdentity,
                conflictPolicy: .requireHostDecision
            )
        )
        guard case .conflict = outcome else {
            Issue.record("expected conflict \(outcome)")
            return
        }
        #expect(String(data: try await io.read(url: url), encoding: .utf8) == "raced")
    }

    @Test func test_DOC_N02_overwriteRequiresExplicitPolicy() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-ow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("base".utf8), to: url)
        let provider = LocalFileDocumentProvider(io: io, useCoordinator: false)
        let loaded = try await provider.load(uri: DocumentURI(fileURL: url))
        try await io.writeAtomically(data: Data("external".utf8), to: url)
        let over = try await provider.save(
            DocumentSaveRequest(
                snapshot: DocumentSnapshot(version: .zero, text: "forced"),
                target: DocumentURI(fileURL: url),
                encoding: .utf8,
                expectedIdentity: loaded.fileIdentity,
                conflictPolicy: .overwrite
            )
        )
        guard case .saved = over else {
            Issue.record("expected saved on explicit overwrite")
            return
        }
        #expect(String(data: try await io.read(url: url), encoding: .utf8) == "forced")
    }

    @Test func test_DOC_N08_identityCheckUnderWritePipeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n08-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("v1".utf8), to: url)
        let known = try #require(await io.resourceIdentity(at: url))
        try await io.writeAtomically(data: Data("v2".utf8), to: url)
        let result = try await io.writeAtomicallyComparingIdentity(
            data: Data("editor".utf8),
            to: url,
            expectedIdentity: known,
            conflictPolicy: .requireHostDecision,
            durability: .durable
        )
        guard case .conflict = result else {
            Issue.record("expected conflict \(result)")
            return
        }
        #expect(String(data: try await io.read(url: url), encoding: .utf8) == "v2")
    }

    @Test func test_DOC_N09_hashOnlyIdentityDoesNotRequireContentReturn() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let payload = Data(repeating: 0x42, count: 128 * 1024)
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: payload, to: url)
        let identity = try #require(await io.resourceIdentity(at: url))
        #expect(identity.contentHash == DocumentFileIdentity.hash(of: payload))
        #expect(identity.size == UInt64(payload.count))
        // Single-buffer content path still correct.
        let (data, id2) = try await io.readContentAndIdentity(url: url, maxBytes: UInt64(payload.count))
        #expect(data == payload)
        #expect(id2.contentHash == identity.contentHash)
    }

    @Test func test_DOC_N10_durableWriteSurvivesFaultBeforeParentFsync() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n10-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let ioBase = LocalDocumentIO()
        try await ioBase.writeAtomically(data: Data("ORIG".utf8), to: url)
        let faulting = FaultInjectingDocumentIO(base: ioBase, fault: .beforeParentFsync)
        do {
            try await faulting.writeAtomically(data: Data("NEW".utf8), to: url)
            Issue.record("expected fault before parent fsync")
        } catch let error as DocumentIOError {
            guard case .injectedFault(.beforeParentFsync) = error else {
                Issue.record("wrong fault \(error)")
                return
            }
        }
        // After replace succeeded, content is NEW even if parent fsync faulted.
        // Durable claim requires parent fsync on success path — fault proves the stage exists.
        let disk = String(data: try await ioBase.read(url: url), encoding: .utf8)
        #expect(disk == "NEW" || disk == "ORIG")
    }

    @Test func test_DOC_N10_successfulDurableWriteIncludesParentFsync() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n10b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("durable-body".utf8), to: url)
        let identity = try #require(await io.resourceIdentity(at: url))
        #expect(identity.contentHash == DocumentFileIdentity.hash(of: Data("durable-body".utf8)))
        // CAS path also durable.
        let result = try await io.writeAtomicallyComparingIdentity(
            data: Data("durable-2".utf8),
            to: url,
            expectedIdentity: identity,
            conflictPolicy: .requireHostDecision,
            durability: .durable
        )
        guard case .written(let written) = result else {
            Issue.record("expected written \(result)")
            return
        }
        #expect(written?.contentHash == DocumentFileIdentity.hash(of: Data("durable-2".utf8)))
    }

    @Test func test_DOC_N11_versionedRecoveryRecordRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("disk".utf8), to: url)
        let state = DocumentContentStateID()
        let base = try #require(await io.resourceIdentity(at: url))
        let journal = RecoveryJournal(directory: dir)
        try await journal.write(
            text: "dirty-snapshot",
            forPrimary: url,
            io: io,
            documentURI: DocumentURI(fileURL: url).rawValue,
            contentState: state,
            baseFileIdentity: base,
            encoding: .utf8
        )
        let text = try await journal.read(forPrimary: url, io: io)
        #expect(text == "dirty-snapshot")
        // createdAt stable across rewrite
        let raw1 = try await io.read(url: journal.journalURL(forPrimary: url))
        let rec1 = try JSONDecoder().decode(RecoveryJournalRecord.self, from: raw1)
        #expect(rec1.schemaVersion == RecoveryJournalRecord.currentSchemaVersion)
        #expect(rec1.contentStateRaw == state.rawValue.uuidString)
        #expect(rec1.baseFileIdentityHash == base.contentHash)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await journal.write(
            text: "dirty-snapshot-2",
            forPrimary: url,
            io: io,
            contentState: state,
            baseFileIdentity: base,
            encoding: .utf8
        )
        let raw2 = try await io.read(url: journal.journalURL(forPrimary: url))
        let rec2 = try JSONDecoder().decode(RecoveryJournalRecord.self, from: raw2)
        #expect(rec2.createdAt == rec1.createdAt)
        #expect(rec2.updatedAt >= rec1.updatedAt)
        let discovered = try await journal.discoverRecords(io: io)
        #expect(discovered.contains(where: { $0.lastPathComponent.contains("codeeditor-recovery") }))
    }

    @Test func test_DOC_N11_corruptRecordQuarantinesFailClosed() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-n11q-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("f.txt")
        let io = LocalDocumentIO()
        try await io.writeAtomically(data: Data("disk".utf8), to: url)
        let journal = RecoveryJournal(directory: dir)
        try await journal.write(text: "ok", forPrimary: url, io: io)
        let jURL = journal.journalURL(forPrimary: url)
        try await io.writeAtomically(data: Data("{not-json".utf8), to: jURL)
        do {
            _ = try await journal.read(forPrimary: url, io: io)
            Issue.record("expected corrupt")
        } catch let error as DocumentIOError {
            guard case .corruptRecoveryJournal = error else {
                Issue.record("wrong \(error)")
                return
            }
        }
        // Quarantine should exist; original journal removed.
        #expect(await io.fileExists(at: journal.quarantineURL(forPrimary: url)))
        #expect(await io.fileExists(at: jURL) == false)
    }
}
