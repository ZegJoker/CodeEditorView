import CoreGraphics
import Foundation

/// Visual and interaction configuration for ``CodeEditor`` / ``EditorController``.
///
/// Prefer nested sections (`appearance`, `behavior`, `layout`, `peripherals`) for new code.
/// Flat properties remain as convenience accessors for existing call sites.
public struct EditorConfiguration: Equatable {
    public var appearance: Appearance
    public var behavior: Behavior
    public var layout: Layout
    public var peripherals: Peripherals

    public init(
        appearance: Appearance = Appearance(),
        behavior: Behavior = Behavior(),
        layout: Layout = Layout(),
        peripherals: Peripherals = Peripherals()
    ) {
        self.appearance = appearance
        self.behavior = behavior
        self.layout = layout
        self.peripherals = peripherals
    }

    /// Backward-compatible flat initializer.
    public init(
        font: PlatformFont = PlatformDefaults.monospacedFont,
        textColor: PlatformColor = PlatformDefaults.textColor,
        caretColor: PlatformColor = PlatformDefaults.caretColor,
        selectionColor: PlatformColor = PlatformDefaults.selectionColor,
        emphasisFillColor: PlatformColor = PlatformDefaults.selectionColor,
        emphasisStrokeColor: PlatformColor = PlatformDefaults.caretColor,
        lineHeightMultiplier: CGFloat = 1.0,
        wrapLines: Bool = true,
        isEditable: Bool = true,
        isSelectable: Bool = true,
        letterSpacing: CGFloat = 1.0,
        edgeInsets: HorizontalEdgeInsets = HorizontalEdgeInsets(leading: 4, trailing: 4),
        lineBreakStrategy: LineBreakStrategy = .word,
        showInvisibleCharacters: Bool = false,
        theme: EditorTheme = .default,
        useThemeBackground: Bool = true,
        tabWidth: Int = 4,
        bracketPairEmphasis: BracketPairEmphasis? = .flash,
        indentOption: IndentOption = .spaces(count: 4),
        reformatAtColumn: Int = 80,
        showGutter: Bool = true,
        showMinimap: Bool = false,
        showReformattingGuide: Bool = false,
        showFoldingRibbon: Bool = false
    ) {
        var theme = theme
        // Align theme chrome with explicit colors when using the flat API.
        theme.text = .init(color: textColor)
        theme.insertionPoint = caretColor
        theme.selection = selectionColor
        self.appearance = Appearance(
            theme: theme,
            useThemeBackground: useThemeBackground,
            font: font,
            lineHeightMultiple: lineHeightMultiplier,
            letterSpacing: letterSpacing,
            wrapLines: wrapLines,
            tabWidth: tabWidth,
            bracketPairEmphasis: bracketPairEmphasis,
            emphasisFillColor: emphasisFillColor,
            emphasisStrokeColor: emphasisStrokeColor
        )
        self.behavior = Behavior(
            isEditable: isEditable,
            isSelectable: isSelectable,
            indentOption: indentOption,
            reformatAtColumn: reformatAtColumn
        )
        self.layout = Layout(
            contentInsets: edgeInsets,
            lineBreakStrategy: lineBreakStrategy
        )
        self.peripherals = Peripherals(
            showGutter: showGutter,
            showMinimap: showMinimap,
            showReformattingGuide: showReformattingGuide,
            showFoldingRibbon: showFoldingRibbon,
            showInvisibleCharacters: showInvisibleCharacters
        )
    }

    // MARK: - Flat convenience accessors

    public var font: PlatformFont {
        get { appearance.font }
        set { appearance.font = newValue }
    }

    public var textColor: PlatformColor {
        get { appearance.theme.text.color }
        set { appearance.theme.text.color = newValue }
    }

    public var caretColor: PlatformColor {
        get { appearance.theme.insertionPoint }
        set { appearance.theme.insertionPoint = newValue }
    }

    public var selectionColor: PlatformColor {
        get { appearance.theme.selection }
        set { appearance.theme.selection = newValue }
    }

    public var emphasisFillColor: PlatformColor {
        get { appearance.emphasisFillColor }
        set { appearance.emphasisFillColor = newValue }
    }

    public var emphasisStrokeColor: PlatformColor {
        get { appearance.emphasisStrokeColor }
        set { appearance.emphasisStrokeColor = newValue }
    }

    public var lineHeightMultiplier: CGFloat {
        get { appearance.lineHeightMultiple }
        set { appearance.lineHeightMultiple = newValue }
    }

    public var wrapLines: Bool {
        get { appearance.wrapLines }
        set { appearance.wrapLines = newValue }
    }

    public var isEditable: Bool {
        get { behavior.isEditable }
        set { behavior.isEditable = newValue }
    }

    public var isSelectable: Bool {
        get { behavior.isSelectable }
        set { behavior.isSelectable = newValue }
    }

    public var letterSpacing: CGFloat {
        get { appearance.letterSpacing }
        set { appearance.letterSpacing = newValue }
    }

    public var edgeInsets: HorizontalEdgeInsets {
        get { layout.contentInsets }
        set { layout.contentInsets = newValue }
    }

    public var lineBreakStrategy: LineBreakStrategy {
        get { layout.lineBreakStrategy }
        set { layout.lineBreakStrategy = newValue }
    }

    public var showInvisibleCharacters: Bool {
        get { peripherals.showInvisibleCharacters }
        set { peripherals.showInvisibleCharacters = newValue }
    }

    public var theme: EditorTheme {
        get { appearance.theme }
        set { appearance.theme = newValue }
    }

    public var typingAttributes: [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: appearance.font,
            .foregroundColor: appearance.theme.text.color,
        ]
        if appearance.letterSpacing != 1.0 {
            let width = (" " as NSString).size(withAttributes: [.font: appearance.font]).width
            attrs[.kern] = width * (appearance.letterSpacing - 1.0)
        }
        return attrs
    }

    /// Estimated advance of one column in the configured monospaced font (for the column guide).
    ///
    /// Uses the digit `"0"` (more stable than a space for some fonts) and applies letter-spacing
    /// so the guide lines up with typeset columns.
    public var characterWidth: CGFloat {
        let font = appearance.font
        let base = ("0" as NSString).size(withAttributes: [.font: font]).width
        let spaced = base * max(appearance.letterSpacing, 0.01)
        return max(spaced, 1)
    }
}

// MARK: - Appearance

extension EditorConfiguration {
    public struct Appearance: Equatable {
        public var theme: EditorTheme
        public var useThemeBackground: Bool
        public var font: PlatformFont
        public var lineHeightMultiple: CGFloat
        public var letterSpacing: CGFloat
        public var wrapLines: Bool
        public var tabWidth: Int
        public var bracketPairEmphasis: BracketPairEmphasis?
        public var emphasisFillColor: PlatformColor
        public var emphasisStrokeColor: PlatformColor

        public init(
            theme: EditorTheme = .default,
            useThemeBackground: Bool = true,
            font: PlatformFont = PlatformDefaults.monospacedFont,
            lineHeightMultiple: CGFloat = 1.0,
            letterSpacing: CGFloat = 1.0,
            wrapLines: Bool = true,
            tabWidth: Int = 4,
            bracketPairEmphasis: BracketPairEmphasis? = .flash,
            emphasisFillColor: PlatformColor = PlatformDefaults.selectionColor,
            emphasisStrokeColor: PlatformColor = PlatformDefaults.caretColor
        ) {
            self.theme = theme
            self.useThemeBackground = useThemeBackground
            self.font = font
            self.lineHeightMultiple = lineHeightMultiple
            self.letterSpacing = letterSpacing
            self.wrapLines = wrapLines
            self.tabWidth = max(1, tabWidth)
            self.bracketPairEmphasis = bracketPairEmphasis
            self.emphasisFillColor = emphasisFillColor
            self.emphasisStrokeColor = emphasisStrokeColor
        }
    }
}

// MARK: - Behavior

extension EditorConfiguration {
    public struct Behavior: Equatable {
        public var isEditable: Bool
        public var isSelectable: Bool
        public var indentOption: IndentOption
        public var reformatAtColumn: Int

        public init(
            isEditable: Bool = true,
            isSelectable: Bool = true,
            indentOption: IndentOption = .spaces(count: 4),
            reformatAtColumn: Int = 80
        ) {
            self.isEditable = isEditable
            self.isSelectable = isSelectable
            self.indentOption = indentOption
            self.reformatAtColumn = max(1, reformatAtColumn)
        }
    }
}

// MARK: - Layout

extension EditorConfiguration {
    public struct Layout: Equatable {
        /// Padding around text content (gutter width is applied separately when shown).
        public var contentInsets: HorizontalEdgeInsets
        public var lineBreakStrategy: LineBreakStrategy

        public init(
            contentInsets: HorizontalEdgeInsets = HorizontalEdgeInsets(leading: 4, trailing: 4),
            lineBreakStrategy: LineBreakStrategy = .word
        ) {
            self.contentInsets = contentInsets
            self.lineBreakStrategy = lineBreakStrategy
        }
    }
}

// MARK: - Peripherals

extension EditorConfiguration {
    public struct Peripherals: Equatable {
        public var showGutter: Bool
        public var showMinimap: Bool
        public var showReformattingGuide: Bool
        public var showFoldingRibbon: Bool
        public var showInvisibleCharacters: Bool

        public init(
            showGutter: Bool = true,
            showMinimap: Bool = false,
            showReformattingGuide: Bool = false,
            showFoldingRibbon: Bool = false,
            showInvisibleCharacters: Bool = false
        ) {
            self.showGutter = showGutter
            self.showMinimap = showMinimap
            self.showReformattingGuide = showReformattingGuide
            self.showFoldingRibbon = showFoldingRibbon
            self.showInvisibleCharacters = showInvisibleCharacters
        }
    }
}

extension EditorConfiguration: @unchecked Sendable {}
extension EditorConfiguration.Appearance: @unchecked Sendable {}
extension EditorConfiguration.Behavior: @unchecked Sendable {}
extension EditorConfiguration.Layout: @unchecked Sendable {}
extension EditorConfiguration.Peripherals: @unchecked Sendable {}
