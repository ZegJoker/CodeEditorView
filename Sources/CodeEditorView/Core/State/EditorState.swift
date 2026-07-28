import CoreGraphics
import Foundation

/// Two-way editor UI state for bindings (cursors, scroll, find panel).
///
/// Optional fields let hosts publish only what changed; consumers treat `nil` as “leave unchanged”
/// when applying inbound state, and always publish concrete values outbound when known.
public struct EditorState: Equatable, Hashable, Sendable, Codable {
    public var cursorPositions: [CursorPosition]?
    public var scrollPosition: CGPoint?
    public var findText: String?
    public var replaceText: String?
    public var findPanelVisible: Bool?

    public init(
        cursorPositions: [CursorPosition]? = nil,
        scrollPosition: CGPoint? = nil,
        findText: String? = nil,
        replaceText: String? = nil,
        findPanelVisible: Bool? = nil
    ) {
        self.cursorPositions = cursorPositions
        self.scrollPosition = scrollPosition
        self.findText = findText
        self.replaceText = replaceText
        self.findPanelVisible = findPanelVisible
    }

    public static let empty = EditorState()
}

// CGPoint is Codable on Apple platforms via NSValue bridging in recent SDKs; provide fallback.
extension EditorState {
    enum CodingKeys: String, CodingKey {
        case cursorPositions
        case scrollX, scrollY
        case findText, replaceText, findPanelVisible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursorPositions = try container.decodeIfPresent([CursorPosition].self, forKey: .cursorPositions)
        if let x = try container.decodeIfPresent(CGFloat.self, forKey: .scrollX),
           let y = try container.decodeIfPresent(CGFloat.self, forKey: .scrollY) {
            scrollPosition = CGPoint(x: x, y: y)
        } else {
            scrollPosition = nil
        }
        findText = try container.decodeIfPresent(String.self, forKey: .findText)
        replaceText = try container.decodeIfPresent(String.self, forKey: .replaceText)
        findPanelVisible = try container.decodeIfPresent(Bool.self, forKey: .findPanelVisible)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cursorPositions, forKey: .cursorPositions)
        if let scrollPosition {
            try container.encode(scrollPosition.x, forKey: .scrollX)
            try container.encode(scrollPosition.y, forKey: .scrollY)
        }
        try container.encodeIfPresent(findText, forKey: .findText)
        try container.encodeIfPresent(replaceText, forKey: .replaceText)
        try container.encodeIfPresent(findPanelVisible, forKey: .findPanelVisible)
    }
}
