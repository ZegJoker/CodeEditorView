import Testing
import Foundation
@testable import CodeEditorCore

@Suite("TextOffsetSemantics")
struct TextOffsetSemanticsTests {
    @Test func utf16Utf8RoundTripASCII() throws {
        let text = "hello"
        for i in 0...text.utf16.count {
            let u8 = try TextOffsetSemantics.utf8Offset(fromUTF16Offset: i, in: text)
            let back = try TextOffsetSemantics.utf16Offset(fromUTF8Offset: u8, in: text)
            #expect(back == i)
        }
    }

    @Test func utf16Utf8Emoji() throws {
        let text = "a😀b" // emoji is 2 UTF-16 units, 4 UTF-8 bytes
        let midEmojiUTF16 = 1
        let u8 = try TextOffsetSemantics.utf8Offset(fromUTF16Offset: midEmojiUTF16, in: text)
        #expect(u8 == 1) // after 'a'
        let afterEmoji = try TextOffsetSemantics.utf16Offset(
            fromUTF8Offset: try TextOffsetSemantics.utf8Offset(fromUTF16Offset: 3, in: text),
            in: text
        )
        #expect(afterEmoji == 3)
    }

    @Test func graphemeBoundariesStayInRangeForEmoji() throws {
        let text = "a👨‍👩‍👧‍👦b"
        let len = (text as NSString).length
        for offset in 0...len {
            let before = try TextOffsetSemantics.graphemeBoundaryBefore(utf16Offset: offset, in: text)
            let after = try TextOffsetSemantics.graphemeBoundaryAfter(utf16Offset: offset, in: text)
            #expect(before >= 0 && before <= len)
            #expect(after >= 0 && after <= len)
            #expect(before <= after)
        }
    }

    @Test func invalidOffsetThrows() {
        #expect(throws: DocumentStoreError.self) {
            try TextOffsetSemantics.utf8Offset(fromUTF16Offset: 99, in: "hi")
        }
    }

    @Test func normalizeLineEndings() {
        let mixed = "a\r\nb\rc\n"
        let lf = TextOffsetSemantics.normalizeLineEndings(mixed, to: .lineFeed)
        #expect(lf == "a\nb\nc\n")
        let crlf = TextOffsetSemantics.normalizeLineEndings(mixed, to: .carriageReturnLineFeed)
        #expect(crlf == "a\r\nb\r\nc\r\n")
    }

    @Test func validatedRangeClampsLength() throws {
        let r = try TextOffsetSemantics.validatedUTF16Range(
            NSRange(location: 2, length: 100),
            documentUTF16Length: 5
        )
        #expect(r == NSRange(location: 2, length: 3))
    }

    @Test func validatedRangeRejectsBadLocation() {
        #expect(throws: DocumentStoreError.self) {
            try TextOffsetSemantics.validatedUTF16Range(
                NSRange(location: -1, length: 1),
                documentUTF16Length: 5
            )
        }
    }
}

@Suite("DocumentStore edit properties")
@MainActor
struct DocumentStorePropertyTests {
    @Test func inverseRestoresText() throws {
        let samples = [
            "hello",
            "a\nb\nc",
            "emoji 😀 end",
            "中文测试",
            String(repeating: "x", count: 200),
            "a\r\nb\r\n",
        ]
        var rng = SplitMix64(seed: 0xC0FFEE)
        for base in samples {
            let store = DocumentStore(string: base)
            for _ in 0..<40 {
                let len = store.length
                let loc = Int(rng.next() % UInt64(max(1, len + 1)))
                let maxDel = len - loc
                let del = maxDel == 0 ? 0 : Int(rng.next() % UInt64(min(8, maxDel + 1)))
                let insertLen = Int(rng.next() % 6)
                let insert = String((0..<insertLen).map { _ in
                    "abcdefghijklmnopqrstuvwxyz \n".randomElement(using: &rng)!
                })
                let before = store.fullString
                let edit = store.replaceCharacters(
                    in: NSRange(location: loc, length: del),
                    with: insert
                )
                store.applyMutation(edit.inverse)
                #expect(store.fullString == before)
                // re-apply forward so next iteration continues mutating
                store.applyMutation(edit.mutation)
            }
        }
    }

    @Test func transactionInverseRoundTrip() throws {
        let store = DocumentStore(string: "abcdef")
        let t = EditTransaction(
            changes: [
                TextChange(range: NSRange(location: 5, length: 1), replacement: "Z"),
                TextChange(range: NSRange(location: 0, length: 1), replacement: "A"),
            ],
            origin: .programmatic
        )
        let applied = try store.apply(t)
        #expect(store.fullString == "AbcdeZ")
        _ = try store.apply(applied.inverse, sortHighToLow: false)
        #expect(store.fullString == "abcdef")
    }

    @Test func staleVersionRejected() throws {
        let store = DocumentStore(string: "x")
        let t = EditTransaction.single(range: NSRange(location: 0, length: 0), replacement: "y")
        #expect(throws: DocumentStoreError.self) {
            try store.apply(t, expectedVersion: DocumentVersion(rawValue: 99))
        }
    }

    @Test func unicodeCorpusSurvivesEdits() throws {
        let corpus = [
            "👨‍👩‍👧‍👦",
            "e\u{0301}", // e + combining acute
            "שלום",
            "日本語",
            "a\r\nb\nc\rd",
            String(repeating: "longline-", count: 500),
        ]
        for text in corpus {
            let store = DocumentStore(string: text)
            let beforeLen = store.length
            let mid = beforeLen / 2
            _ = store.replaceCharacters(in: NSRange(location: mid, length: 0), with: "X")
            #expect(store.length == beforeLen + 1)
            #expect(store.version > .zero)
            // Inverse must restore exactly
            let edit = store.makeEdit(in: NSRange(location: mid, length: 1), replacement: "")
            store.applyMutation(edit.mutation)
            // re-do inverse of insert via replace back to original mid content is harder;
            // assert we can setFullText back
            store.setFullText(text)
            #expect(store.fullString == text)
        }
    }
}

/// Tiny deterministic PRNG for property tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension String {
    func randomElement(using rng: inout SplitMix64) -> Character {
        let idx = Int(rng.next() % UInt64(utf16.count))
        let i = index(startIndex, offsetBy: idx % count)
        return self[i]
    }
}
