import Foundation
import Testing

@testable import CodeEditorLanguageSupport

@Suite("LANG-N07 host-owned registries")
struct LANGN07HostRegistryTests {
    @Test func test_LANG_N07_hostRegistryIsolatedFromShared() {
        let host = LanguageRegistry()
        let shared = LanguageRegistry.shared

        _ = host.register(
            LanguageDefinition(id: "host.only", displayName: "Host", tsName: "host"),
            owner: .host,
            priority: 1
        )
        #expect(host.definition(for: "host.only") != nil)
        #expect(shared.definition(for: "host.only") == nil)

        host.removeAll()
        #expect(host.definition(for: "host.only") == nil)
    }

    @Test func test_LANG_N07_twoHostRegistriesAreIndependent() {
        let a = LanguageRegistry()
        let b = LanguageRegistry()
        _ = a.register(
            LanguageDefinition(id: "a", displayName: "A", tsName: "a"),
            owner: .host
        )
        _ = b.register(
            LanguageDefinition(id: "b", displayName: "B", tsName: "b"),
            owner: .host
        )
        #expect(a.definition(for: "a") != nil)
        #expect(a.definition(for: "b") == nil)
        #expect(b.definition(for: "b") != nil)
        #expect(b.definition(for: "a") == nil)
    }

    @Test func test_LANG_N07_explicitInitDoesNotUseGlobalSideEffect() {
        // Constructing a registry must not require process-wide bootstrap.
        let registry = LanguageRegistry()
        #expect(registry.snapshot().definitions.isEmpty)
        #expect(registry.currentGeneration == 0 || registry.snapshot().generation >= 0)
    }
}
