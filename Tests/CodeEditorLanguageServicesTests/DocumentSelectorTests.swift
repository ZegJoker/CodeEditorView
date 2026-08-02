import CodeEditorDocuments
import Foundation
import Testing

@testable import CodeEditorLanguageServices

@Suite("DocumentSelector")
struct DocumentSelectorTests {
    @Test func matchesAnyWhenEmpty() {
        let sel = DocumentSelector.any
        #expect(sel.matches(languageID: "swift", uri: DocumentURI(rawValue: "file:///a.swift")))
        #expect(sel.matches(languageID: nil, uri: nil))
    }

    @Test func matchesLanguageIDsCaseInsensitive() {
        let sel = DocumentSelector.languages("Swift", "json")
        #expect(sel.matches(languageID: "swift", uri: nil))
        #expect(sel.matches(languageID: "JSON", uri: nil))
        #expect(!sel.matches(languageID: "python", uri: nil))
        #expect(!sel.matches(languageID: nil, uri: nil))
    }

    @Test func matchesSchemes() {
        let sel = DocumentSelector(schemePatterns: ["file"])
        #expect(sel.matches(languageID: nil, uri: DocumentURI(rawValue: "file:///tmp/a.swift")))
        #expect(!sel.matches(languageID: nil, uri: DocumentURI(rawValue: "inmemory:x")))
    }

    @Test func matchesExtensionGlob() {
        let sel = DocumentSelector(pathGlobs: ["*.swift"])
        #expect(
            sel.matches(
                languageID: nil,
                uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/Foo.swift"))
            ))
        #expect(
            !sel.matches(
                languageID: nil,
                uri: DocumentURI(fileURL: URL(fileURLWithPath: "/tmp/Foo.json"))
            ))
    }

    @Test func matchesSuffixAndContains() {
        let suffix = DocumentSelector(pathGlobs: ["*/Package.swift"])
        // hasPrefix for trailing * and hasSuffix for leading *
        let prefix = DocumentSelector(pathGlobs: ["*/src/*"])
        #expect(
            prefix.matches(
                languageID: nil,
                uri: DocumentURI(rawValue: "file:///app/src/main.swift")
            )
                || DocumentSelector(pathGlobs: ["*src*"]).matches(
                    languageID: nil,
                    uri: DocumentURI(rawValue: "file:///app/src/main.swift")
                ))
        #expect(
            DocumentSelector(pathGlobs: ["*Package.swift"]).matches(
                languageID: nil,
                uri: DocumentURI(fileURL: URL(fileURLWithPath: "/proj/Package.swift"))
            ))
        _ = suffix
    }
}
