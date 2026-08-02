import Foundation
import Testing

@testable import CodeEditorLanguageSupport

@Suite("LANG-N01 language registration ownership")
struct LANGN01RegistrationTests {
    @Test func test_LANG_N01_unregisterOneOwnerDoesNotRemoveOtherReplacement() {
        let registry = LanguageRegistry()
        let defA = LanguageDefinition(
            id: "dsl",
            displayName: "DSL A",
            tsName: "dsl",
            fileExtensions: ["dsl"],
            detectionPriority: 10
        )
        let defB = LanguageDefinition(
            id: "dsl",
            displayName: "DSL B",
            tsName: "dsl",
            fileExtensions: ["dsl"],
            detectionPriority: 20
        )

        let a = registry.register(
            defA,
            owner: .extensionPackage("ext.a"),
            priority: 10
        )
        #expect(a.didBecomeEffective)
        #expect(registry.definition(for: "dsl")?.displayName == "DSL A")

        let b = registry.register(
            defB,
            owner: .extensionPackage("ext.b"),
            priority: 20
        )
        #expect(b.didBecomeEffective)
        #expect(registry.definition(for: "dsl")?.displayName == "DSL B")
        #expect(registry.allRecords(for: "dsl").count == 2)

        // Disposing the lower-priority original must not remove B's replacement.
        a.token.dispose()
        #expect(registry.definition(for: "dsl")?.displayName == "DSL B")
        #expect(registry.effectiveRecord(for: "dsl")?.owner == .extensionPackage("ext.b"))
        #expect(registry.record(for: a.record.tokenID) == nil)
        #expect(registry.record(for: b.record.tokenID) != nil)
    }

    @Test func test_LANG_N01_disposeWinnerPromotesRemainingOwner() {
        let registry = LanguageRegistry()
        let low = registry.register(
            LanguageDefinition(id: "x", displayName: "Low", tsName: "x"),
            owner: .extensionPackage("low"),
            priority: 1
        )
        let high = registry.register(
            LanguageDefinition(id: "x", displayName: "High", tsName: "x"),
            owner: .extensionPackage("high"),
            priority: 100
        )
        #expect(registry.definition(for: "x")?.displayName == "High")
        high.token.dispose()
        #expect(registry.definition(for: "x")?.displayName == "Low")
        #expect(registry.effectiveRecord(for: "x")?.tokenID == low.record.tokenID)
    }

    @Test func test_LANG_N01_registrationRecordHasOwnerGenerationToken() {
        let registry = LanguageRegistry()
        let result = registry.register(
            LanguageDefinition(id: "y", displayName: "Y", tsName: "y"),
            owner: .host,
            priority: 5
        )
        let record = result.record
        #expect(record.owner == .host)
        #expect(record.priority == 5)
        #expect(record.generation >= 1)
        #expect(record.tokenID == result.token.id)
        #expect(record.languageID == "y")
        #expect(record.descriptor.displayName == "Y")
        #expect(registry.snapshot().effectiveRecords.contains(where: { $0.tokenID == record.tokenID }))
    }

    @Test func test_LANG_N01_unregisterByOwnerRemovesOnlyThatOwner() {
        let registry = LanguageRegistry()
        _ = registry.register(
            LanguageDefinition(id: "z", displayName: "Host", tsName: "z"),
            owner: .host,
            priority: 1
        )
        _ = registry.register(
            LanguageDefinition(id: "z", displayName: "Ext", tsName: "z"),
            owner: .extensionPackage("e1"),
            priority: 50
        )
        #expect(registry.definition(for: "z")?.displayName == "Ext")
        registry.unregister(owner: .extensionPackage("e1"))
        #expect(registry.definition(for: "z")?.displayName == "Host")
        #expect(registry.allRecords(for: "z").count == 1)
    }

    @Test func test_LANG_N01_parserFactoryBoundToTokenSurvivesOtherUnregister() {
        let registry = LanguageRegistry()
        let lowBits: UInt = 0xBEEF
        let highBits: UInt = 0xCAFE
        let a = registry.register(
            LanguageDefinition(id: "p", displayName: "P", tsName: "p"),
            owner: .extensionPackage("a"),
            priority: 10,
            parserFactory: { OpaquePointer(bitPattern: lowBits) }
        )
        let b = registry.register(
            LanguageDefinition(id: "p", displayName: "P2", tsName: "p"),
            owner: .extensionPackage("b"),
            priority: 20,
            parserFactory: { OpaquePointer(bitPattern: highBits) }
        )
        #expect(registry.parser(for: "p") == OpaquePointer(bitPattern: highBits))
        a.token.dispose()
        #expect(registry.parser(for: "p") == OpaquePointer(bitPattern: highBits))
        b.token.dispose()
        #expect(registry.hasParser(for: "p") == false)
    }
}
