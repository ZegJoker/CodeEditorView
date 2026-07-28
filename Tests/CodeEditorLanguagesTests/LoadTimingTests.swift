import Testing
import Foundation
@testable import CodeEditorLanguages

@Suite("Load timing")
struct LoadTimingTests {
    @Test func dartConfigDoesNotHang() throws {
        let t0 = Date()
        let config = try CodeLanguages.languageConfiguration(for: .dart)
        let ms = Date().timeIntervalSince(t0) * 1000
        #expect(config != nil)
        #expect(ms < 5000, "Dart config took \(ms)ms")
        print("dart config \(ms)ms")
    }

    @Test func severalConfigs() throws {
        for lang in [CodeLanguage.dart, .swift, .c, .cpp, .rust, .typescript] {
            let t0 = Date()
            let config = try CodeLanguages.languageConfiguration(for: lang)
            let ms = Date().timeIntervalSince(t0) * 1000
            print("\(lang.displayName): \(String(format: "%.1f", ms))ms nil=\(config == nil)")
            #expect(config != nil)
        }
    }
}
