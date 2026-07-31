import Testing
import CodeEditorCore

@Suite("Platform capabilities")
struct PlatformCapabilityTests {
    @Test func hostPlatformCurrentIsRecognized() {
        let current = HostPlatform.current
        #expect(HostPlatform.allCases.contains(current))
    }

    @Test func directMacOSAllowsLocalProcessTools() throws {
        let profile = PlatformCapabilityProfile.directMacOS
        try profile.requireLocal(.localProcess)
        try profile.requireLocal(.localGitCLI)
        try profile.requireLocal(.localLanguageServerProcess)
        try profile.requireLocal(.nativeExtensionProcess)
        try profile.requireLocal(.localPTY)
    }

    @Test func iOSDeniesLocalProcessTools() {
        let profile = PlatformCapabilityProfile.iOS
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.localProcess)
        }
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.localGitCLI)
        }
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.nativeExtensionProcess)
        }
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.localPTY)
        }
        // Language servers are remote-only on iOS — not local.
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.localLanguageServerProcess)
        }
        if case .remote = profile.availability(for: .localLanguageServerProcess) {
            // expected
        } else {
            Issue.record("iOS language server should be remote")
        }
    }

    @Test func macAppStoreDeniesNativeHelpersByDefault() {
        let profile = PlatformCapabilityProfile.macAppStore
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.nativeExtensionProcess)
        }
        #expect(throws: Never.self) {
            try profile.requireLocal(.localProcess)
        }
    }

    @Test func defaultMatchesOS() {
        let profile = PlatformCapabilityProfile.default()
        #if os(iOS)
        #expect(profile.name == PlatformCapabilityProfile.iOS.name)
        #elseif os(macOS)
        #expect(profile.name == PlatformCapabilityProfile.directMacOS.name)
        #endif
    }

    @Test func processUnavailableProfileFailsClosed() {
        let profile = PlatformCapabilityProfile.processUnavailable
        #expect(throws: CodeEditorPlatformError.self) {
            try profile.requireLocal(.localProcess)
        }
    }

    @Test func platformServicesRequireChecks() {
        let denied = PlatformServices(profile: .processUnavailable)
        #expect(throws: CodeEditorPlatformError.self) {
            try denied.process.requireProcessCapability()
        }
        #expect(throws: CodeEditorPlatformError.self) {
            try denied.pty.requirePTYCapability()
        }

        let allowed = PlatformServices(profile: .directMacOS)
        #expect(throws: Never.self) {
            try allowed.process.requireProcessCapability()
            try allowed.network.requireNetworkCapability()
            try allowed.filesystem.requireFilesystemCapability()
        }
    }

    @Test func enterprisePresetMirrorsDirectMacOSLocalSurface() throws {
        try PlatformCapabilityProfile.enterprise.requireLocal(.localProcess)
        try PlatformCapabilityProfile.test.requireLocal(.localGitCLI)
    }
}
