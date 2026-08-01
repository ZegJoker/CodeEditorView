import CodeEditorCore
import Foundation
import Testing

@Suite("Phase 15 profile matrix")
struct Phase15ProfileMatrixTests {
    private static var matrixURL: URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Profiles/matrix.json")
        return source
    }

    @Test func allShippingPresetsMatchFixtureMatrix() throws {
        let data = try Data(contentsOf: Self.matrixURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let profiles = json["profiles"] as! [String: [String: String]]

        let mapping: [(ShippingProfileID, PlatformCapabilityProfile)] = [
            (.directMacOS, .directMacOS),
            (.macAppStore, .macAppStore),
            (.iOS, .iOS),
            (.enterprise, .enterprise),
            (.test, .test),
        ]
        for (id, profile) in mapping {
            let expected = profiles[id.rawValue]!
            let actual = profile.matrixSnapshot()
            for (kind, exp) in expected {
                #expect(actual[kind] == exp, "\(id.rawValue).\(kind): got \(actual[kind] ?? "nil") want \(exp)")
            }
            #expect(profile.shippingProfileID == id)
        }
    }

    @Test func enterpriseDiffersFromDirectMacOS() {
        #expect(PlatformCapabilityProfile.enterprise.enterpriseOptions != nil)
        #expect(PlatformCapabilityProfile.directMacOS.enterpriseOptions == nil)
        #expect(PlatformCapabilityProfile.enterprise.enterpriseOptions?.managedRegistryOnly == true)
        #expect(PlatformCapabilityProfile.enterprise.enterpriseOptions?.requireSignedNativeHelpers == true)
    }

    @Test func iOSLanguageServerIsRemoteNotLocal() {
        #expect(throws: CodeEditorPlatformError.self) {
            try PlatformCapabilityProfile.iOS.requireLocal(.localLanguageServerProcess)
        }
        if case .remote = PlatformCapabilityProfile.iOS.availability(for: .localLanguageServerProcess) {
            // ok
        } else {
            Issue.record("expected remote LS")
        }
        #expect(PlatformCapabilityProfile.iOS.remoteToolingAvailable)
    }

    @Test func shippingFactoryResolvesPresets() {
        #expect(PlatformCapabilityProfile.shipping(.macAppStore).name == "mac-app-store")
        #expect(PlatformCapabilityProfile.shipping(.iOS).name == "ios")
    }
}
