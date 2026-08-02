import CodeEditorLanguageSupport
import Foundation
import Testing

@testable import CodeEditorTreeSitter

@Suite("Phase6 LanguageDocumentActor")
struct Phase6LanguageDocumentActorTests {
    @Test func generationAdvancesAndStaleRejected() async throws {
        let actor = LanguageDocumentActor()
        // Without config, setText still advances generation.
        let g1 = try await actor.setText("let a = 1")
        let g2 = try await actor.setText("let a = 2")
        #expect(g2 > g1)
        #expect(await actor.isCurrent(generation: g2))
        #expect(await actor.isCurrent(generation: g1) == false)
    }

    @Test func queryWithoutConfigThrowsNotConfigured() async {
        let actor = LanguageDocumentActor()
        do {
            _ = try await actor.queryHighlights(in: NSRange(location: 0, length: 1))
            Issue.record("expected notConfigured")
        } catch let error as LanguageDocumentActor.EngineError {
            #expect(error == .notConfigured)
        } catch {
            Issue.record("wrong \(error)")
        }
    }

    @Test func actorIsNotMainActorIsolated() async throws {
        // Calling engine APIs from a background task must succeed (off-main isolation).
        let actor = LanguageDocumentActor()
        let gen = try await Task.detached {
            try await actor.setText("hello")
        }.value
        #expect(gen >= 1)
    }
}
