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
        // Constructing a host registry must not auto-bootstrap or mutate shared.
        let probe = LanguageID(rawValue: "lang.n07.side-effect.probe.\(UUID().uuidString)")
        #expect(LanguageRegistry.shared.definition(for: probe) == nil)

        let registry = LanguageRegistry()
        #expect(registry.snapshot().definitions.isEmpty)
        #expect(registry.currentGeneration == 0)
        #expect(registry.snapshot().generation == 0)
        #expect(registry.snapshot().languageIDsWithParsers.isEmpty)
        #expect(registry.snapshot().languageIDsWithQueries.isEmpty)

        // Host mutation stays isolated: shared never gains this definition.
        let result = registry.register(
            LanguageDefinition(id: probe, displayName: "Probe", tsName: "probe"),
            owner: .host,
            priority: 1
        )
        #expect(result.didBecomeEffective)
        #expect(registry.currentGeneration > 0)
        #expect(registry.definition(for: probe) != nil)
        #expect(LanguageRegistry.shared.definition(for: probe) == nil)
        #expect(LanguageRegistry.shared.snapshot().definitions.contains(where: {
            $0.id == probe
        }) == false)

        registry.removeAll()
        #expect(registry.definition(for: probe) == nil)
        #expect(registry.snapshot().definitions.isEmpty)
    }
}
