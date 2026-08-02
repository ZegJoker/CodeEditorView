import CodeEditorCommands
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorLanguageServices
import CodeEditorLanguageSupport
import Foundation
import Testing

@testable import CodeEditorExtensions

// MARK: - Sample extensions

struct CommandSampleExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "test.command",
        displayName: "Command Sample",
        activationEvents: [.startup],
        requiredHostCapabilities: [.commands],
        requestedPermissions: []
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let context = context as? ExtensionContext else {
            throw ExtensionError.activationFailed("host context required")
        }
        guard let commands = context.commands else {
            throw ExtensionError.missingCapabilities([.commands])
        }
        let command = await MainActor.run {
            EditorCommand(
                id: CommandID(stringLiteral: "test.command.hello"),
                title: "Hello Extension"
            ) { _ in }
        }
        let token = await commands.registerAsync(command)
        context.track(token)
        context.info("command registered")
    }
}

struct CompletionSampleExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "test.completion",
        displayName: "Completion Sample",
        activationEvents: [.language("swift")],
        requiredHostCapabilities: [.languageServices],
        requestedPermissions: []
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let context = context as? ExtensionContext else {
            throw ExtensionError.activationFailed("host context required")
        }
        guard let services = context.languageServices else {
            throw ExtensionError.missingCapabilities([.languageServices])
        }
        let provider = MockLanguageSuite(
            id: "test.cmp",
            selector: .languages("swift"),
            priority: 10,
            completionItems: [CompletionItem(label: "extHello", kind: .function)]
        )
        let token = await services.register(provider as any CompletionProvider)
        context.track(token)
    }
}

struct LanguageMetaSampleExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "test.langmeta",
        displayName: "Language Meta",
        activationEvents: [.startup],
        requiredHostCapabilities: [.languages]
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let context = context as? ExtensionContext else {
            throw ExtensionError.activationFailed("host context required")
        }
        let def = LanguageDefinition(
            id: LanguageID(rawValue: "extlang"),
            displayName: "Ext Lang",
            tsName: "extlang",
            fileExtensions: ["extlang"]
        )
        if let reg = context.languages {
            context.track(reg.register(def))
        }
    }
}

struct PanelSampleExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "test.panel",
        displayName: "Panel Sample",
        activationEvents: [.startup],
        requiredHostCapabilities: [.panels],
        requestedPermissions: [.presentUI]
    )

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let context = context as? ExtensionContext else {
            throw ExtensionError.activationFailed("host context required")
        }
        try context.requirePermission(.presentUI)
        let token = try context.panels?.register(
            id: "test.panel",
            slot: "utility",
            title: "Sample Panel",
            priority: 5
        )
        if let token { context.track(token) }
    }
}

struct TaskyExtension: CodeEditorExtension {
    let manifest = ExtensionManifest(
        id: "test.tasks",
        displayName: "Tasky",
        activationEvents: [.manual],
        requiredHostCapabilities: []
    )
    let flag: LockedFlag

    func activate(in context: any ExtensionAuthorContext) async throws {
        guard let context = context as? ExtensionContext else {
            throw ExtensionError.activationFailed("host context required")
        }
        let flag = self.flag
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                flag.value = true
            } catch {
                // Cancelled on deactivate — leave flag false.
            }
        }
        context.addTask(task)
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

// MARK: - Tests

@Suite("Version range")
struct VersionRangeTests {
    @Test func containsBoundaries() {
        let range = VersionRange(
            min: SemanticVersion(major: 1, minor: 0),
            maxExclusive: SemanticVersion(major: 2)
        )
        #expect(range.contains(SemanticVersion(major: 1, minor: 0)))
        #expect(range.contains(SemanticVersion(major: 1, minor: 9, patch: 9)))
        #expect(!range.contains(SemanticVersion(major: 0, minor: 9)))
        #expect(!range.contains(SemanticVersion(major: 2)))
    }
}

@Suite("Extension compatibility")
struct CompatibilityTests {
    @MainActor
    @Test func missingCapabilityStaysInactive() async throws {
        let env = HostEnvironment(capabilities: [.storage], grantedPermissions: [])
        let services = ExtensionHostServices()
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CommandSampleExtension())
        do {
            try await runtime.activate(id: "test.command")
            Issue.record("expected missing capabilities")
        } catch let error as ExtensionError {
            guard case .missingCapabilities = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
        let status = await runtime.status(id: "test.command")
        if case .inactive(.missingCapabilities) = status?.state {
            // ok
        } else {
            Issue.record("unexpected state \(String(describing: status?.state))")
        }
    }

    @MainActor
    @Test func incompatibleAPI() async throws {
        let env = HostEnvironment(
            apiVersion: SemanticVersion(major: 0, minor: 1),
            capabilities: [.commands]
        )
        let services = ExtensionHostServices.makeFull()
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CommandSampleExtension())
        do {
            try await runtime.activate(id: "test.command")
            Issue.record("expected incompatible API")
        } catch let error as ExtensionError {
            guard case .incompatibleAPI = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }
}

@Suite("Extension lifecycle")
struct LifecycleTests {
    @MainActor
    @Test func commandRegisterAndDispose() async throws {
        let commands = CommandRegistry()
        let services = ExtensionHostServices.makeFull(commands: commands)
        let env = HostEnvironment(
            capabilities: [
                .commands, .keybindings, .languages, .languageServices, .panels, .themes, .snippets, .storage,
            ],
            grantedPermissions: [.presentUI]
        )
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CommandSampleExtension())
        try await runtime.activate(id: "test.command")
        #expect(commands.command(id: CommandID(stringLiteral: "test.command.hello")) != nil)

        await runtime.deactivate(id: "test.command")
        #expect(commands.command(id: CommandID(stringLiteral: "test.command.hello")) == nil)
        let status = await runtime.status(id: "test.command")
        if case .inactive(.deactivated) = status?.state {
            // ok
        } else {
            Issue.record("expected deactivated")
        }
    }

    @MainActor
    @Test func tasksCancelledOnDeactivate() async throws {
        let flag = LockedFlag()
        let services = ExtensionHostServices()
        let runtime = ExtensionRuntime(environment: .full, services: services)
        await runtime.register(TaskyExtension(flag: flag))
        try await runtime.activate(id: "test.tasks")
        await runtime.deactivate(id: "test.tasks")
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(flag.value == false)
    }

    @MainActor
    @Test func languageMetaRegisters() async throws {
        let registry = LanguageRegistry.shared
        registry.unregisterAll(for: LanguageID(rawValue: "extlang"))
        let services = ExtensionHostServices(languageRegistry: registry)
        let env = HostEnvironment(capabilities: [.languages])
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(LanguageMetaSampleExtension())
        try await runtime.activate(id: "test.langmeta")
        #expect(registry.definition(for: LanguageID(rawValue: "extlang")) != nil)
        await runtime.deactivate(id: "test.langmeta")
        #expect(registry.definition(for: LanguageID(rawValue: "extlang")) == nil)
    }
}

@Suite("Permissions")
struct PermissionTests {
    @MainActor
    @Test func panelRequiresPresentUI() async throws {
        let services = ExtensionHostServices()
        let env = HostEnvironment(
            capabilities: [.panels],
            grantedPermissions: []  // deny presentUI
        )
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(PanelSampleExtension())
        do {
            try await runtime.activate(id: "test.panel")
            Issue.record("expected permission failure")
        } catch {
            // activationFailed wrapping permissionDenied
        }
        #expect(services.panelStore.all().isEmpty)

        let env2 = HostEnvironment(
            capabilities: [.panels],
            grantedPermissions: [.presentUI]
        )
        let runtime2 = ExtensionRuntime(environment: env2, services: services)
        await runtime2.register(PanelSampleExtension())
        try await runtime2.activate(id: "test.panel")
        #expect(services.panelStore.panels(slot: "utility").count == 1)
        await runtime2.deactivate(id: "test.panel")
        #expect(services.panelStore.all().isEmpty)
    }

    @Test func storageRejectsPathEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = ExtensionStorage(
            extensionID: "test.storage",
            rootDirectory: root,
            grantedPermissions: []
        )
        #expect(throws: ExtensionError.storagePathEscape) {
            try storage.resolvedFileURL(forRelativePath: "../outside.txt")
        }
        // After sanitizing ".." the path may still resolve inside — use absolute-style
        let ok = try storage.resolvedFileURL(forRelativePath: "notes/a.txt")
        #expect(ok.path.contains(root.path))
        try storage.setValue(Data("hi".utf8), forKey: "k")
        #expect(try storage.value(forKey: "k") == Data("hi".utf8))
    }
}

@Suite("Language service registrar")
struct LanguageServiceRegistrarTests {
    @MainActor
    @Test func completionProviderRoundTrip() async throws {
        let lsRegistry = LanguageServiceRegistry()
        let services = ExtensionHostServices(languageServiceRegistry: lsRegistry)
        let env = HostEnvironment(capabilities: [.languageServices])
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CompletionSampleExtension())
        await runtime.fire(.language("swift"))
        let host = LanguageServiceHost(registry: lsRegistry)
        let list = try await host.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0),
                context: LanguageServiceContext(languageID: "swift")
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(list.items.map(\.label).contains("extHello"))

        await runtime.deactivate(id: "test.completion")
        // Give async unregister a moment
        try await Task.sleep(nanoseconds: 10_000_000)
        let after = try await host.completions(
            for: CompletionRequest(
                document: DocumentSnapshot(version: DocumentVersion(rawValue: 1), text: "x"),
                position: TextPosition(utf16Offset: 0),
                context: LanguageServiceContext(languageID: "swift")
            ),
            currentVersion: { DocumentVersion(rawValue: 1) }
        )
        #expect(!after.items.map(\.label).contains("extHello"))
    }
}

@Suite("Data extension loader")
struct DataLoaderTests {
    @MainActor
    @Test func loadsJSONAndActivates() async throws {
        let json = """
            {
              "id": "data.theme",
              "displayName": "Data Theme",
              "version": "1.2.0",
              "activationEvents": ["startup"],
              "requiredHostCapabilities": ["themes", "snippets", "languages"],
              "themes": [
                { "id": "darkish", "displayName": "Darkish", "tokens": { "keyword": "#ff00aa" } }
              ],
              "snippets": [
                { "id": "sn1", "prefix": "log", "body": "print($0)", "languageID": "swift" }
              ],
              "languages": [
                {
                  "id": "dataLang",
                  "displayName": "Data Lang",
                  "tsName": "dataLang",
                  "fileExtensions": ["dl"],
                  "aliases": [],
                  "lineComment": "#",
                  "blockCommentStart": "",
                  "blockCommentEnd": ""
                }
              ]
            }
            """.data(using: .utf8)!

        let bundle = try DataExtensionLoader.load(json: json)
        #expect(bundle.manifest.id.rawValue == "data.theme")
        #expect(bundle.themes.count == 1)

        LanguageRegistry.shared.unregisterAll(for: LanguageID(rawValue: "dataLang"))
        let services = ExtensionHostServices(
            languageRegistry: .shared,
            themeStore: ThemeContributionStore(),
            snippetStore: SnippetContributionStore()
        )
        let env = HostEnvironment(capabilities: [.themes, .snippets, .languages])
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(DataExtensionLoader.makeExtension(from: bundle))
        try await runtime.activate(id: "data.theme")
        #expect(services.themeStore.all().count == 1)
        #expect(services.snippetStore.all().count == 1)
        #expect(LanguageRegistry.shared.definition(for: LanguageID(rawValue: "dataLang")) != nil)
        await runtime.deactivate(id: "data.theme")
        #expect(services.themeStore.all().isEmpty)
        #expect(LanguageRegistry.shared.definition(for: LanguageID(rawValue: "dataLang")) == nil)
    }
}

@Suite("Activation events")
struct ActivationEventTests {
    @MainActor
    @Test func firesOnlyMatching() async throws {
        let lsRegistry = LanguageServiceRegistry()
        let services = ExtensionHostServices(languageServiceRegistry: lsRegistry)
        let env = HostEnvironment(capabilities: [.languageServices])
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CompletionSampleExtension())
        await runtime.fire(.language("python"))
        var status = await runtime.status(id: "test.completion")
        if case .active = status?.state {
            Issue.record("should not activate for python")
        }
        await runtime.fire(.language("swift"))
        status = await runtime.status(id: "test.completion")
        if case .active = status?.state {
            // ok
        } else {
            Issue.record("expected active after swift language event")
        }
    }
}

@Suite("Multi extension")
struct MultiExtensionTests {
    @MainActor
    @Test func independentDispose() async throws {
        let commands = CommandRegistry()
        let services = ExtensionHostServices.makeFull(commands: commands)
        let env = HostEnvironment(
            capabilities: Set(HostCapability.allCases),
            grantedPermissions: [.presentUI]
        )
        let runtime = ExtensionRuntime(environment: env, services: services)
        await runtime.register(CommandSampleExtension())
        await runtime.register(PanelSampleExtension())
        await runtime.fire(.startup)
        #expect(commands.command(id: CommandID(stringLiteral: "test.command.hello")) != nil)
        #expect(services.panelStore.all().count == 1)

        await runtime.deactivate(id: "test.command")
        #expect(commands.command(id: CommandID(stringLiteral: "test.command.hello")) == nil)
        #expect(services.panelStore.all().count == 1)

        await runtime.deactivate(id: "test.panel")
        #expect(services.panelStore.all().isEmpty)
    }
}
