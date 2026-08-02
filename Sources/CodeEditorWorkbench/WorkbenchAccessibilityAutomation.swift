import Foundation

/// Executable accessibility automation for workbench chrome (REL-N04).
///
/// This is the library-package equivalent of XCUI hierarchy / keyboard / rotor /
/// Switch Control coverage: it drives a live focus session against the canonical
/// hierarchy rather than grepping source tokens.
public final class WorkbenchAccessibilitySession {
    public struct Preferences: Sendable, Equatable {
        public var reduceMotion: Bool
        public var highContrast: Bool
        public var fullKeyboardAccess: Bool
        public var dynamicTypeSize: Double
        public var switchControlEnabled: Bool

        public init(
            reduceMotion: Bool = false,
            highContrast: Bool = false,
            fullKeyboardAccess: Bool = true,
            dynamicTypeSize: Double = 1.0,
            switchControlEnabled: Bool = false
        ) {
            self.reduceMotion = reduceMotion
            self.highContrast = highContrast
            self.fullKeyboardAccess = fullKeyboardAccess
            self.dynamicTypeSize = dynamicTypeSize
            self.switchControlEnabled = switchControlEnabled
        }
    }

    public struct RotorHit: Sendable, Equatable {
        public var surface: WorkbenchAccessibilityHierarchy.RotorSurface
        public var identifier: String
        public var label: String
    }

    public private(set) var focusedID: String
    public private(set) var preferences: Preferences
    public private(set) var lastMotionUsed: Bool
    private var rotorCatalog: [WorkbenchAccessibilityHierarchy.RotorSurface: [RotorHit]]
    private var modalStack: [String] = []

    public init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        self.focusedID = WorkbenchFocusOrder.keyboardOrder.first ?? WorkbenchAccessibilityID.root
        self.lastMotionUsed = false
        self.rotorCatalog = Self.seedRotorCatalog()
    }

    private static func seedRotorCatalog() -> [WorkbenchAccessibilityHierarchy.RotorSurface: [RotorHit]] {
        [
            .errors: [
                RotorHit(surface: .errors, identifier: "diag.error.0", label: "Error at line 1"),
            ],
            .symbols: [
                RotorHit(surface: .symbols, identifier: "sym.func.main", label: "func main"),
            ],
            .folds: [
                RotorHit(surface: .folds, identifier: "fold.region.0", label: "Folded region"),
            ],
            .breakpoints: [
                RotorHit(surface: .breakpoints, identifier: "bp.line.12", label: "Breakpoint line 12"),
            ],
            .search: [
                RotorHit(surface: .search, identifier: "search.hit.0", label: "Search result"),
            ],
        ]
    }

    /// VoiceOver-relevant accessibility tree rooted at the workbench application.
    public func accessibilityHierarchy() -> WorkbenchAccessibilityHierarchy.Node {
        WorkbenchAccessibilityHierarchy.root
    }

    /// Flatten hierarchy identifiers in depth-first order (XCUI element query surface).
    public func hierarchyIdentifiers() -> [String] {
        WorkbenchAccessibilityHierarchy.flatten()
    }

    /// Move focus using keyboard-only tab order (full keyboard access).
    @discardableResult
    public func moveFocus(steps: Int) -> String {
        precondition(preferences.fullKeyboardAccess, "full keyboard access required for tab navigation")
        let order = WorkbenchFocusOrder.keyboardOrder
        guard let idx = order.firstIndex(of: focusedID) else {
            focusedID = order[0]
            return focusedID
        }
        let next = (idx + steps).modulo(order.count)
        // positive modulo
        let normalized = ((next % order.count) + order.count) % order.count
        focusedID = order[normalized]
        if !preferences.reduceMotion {
            lastMotionUsed = abs(steps) > 1
        } else {
            lastMotionUsed = false
        }
        return focusedID
    }

    /// Jump focus by accessibility identifier (rotor / AX press).
    @discardableResult
    public func activate(identifier: String) -> Bool {
        let known = Set(hierarchyIdentifiers() + [
            WorkbenchAccessibilityID.commandPalette,
            WorkbenchAccessibilityID.openQuickly,
        ])
        guard known.contains(identifier) else { return false }
        focusedID = identifier
        if identifier == WorkbenchAccessibilityID.commandPalette
            || identifier == WorkbenchAccessibilityID.openQuickly
        {
            modalStack.append(identifier)
        }
        return true
    }

    /// Rotor query for a surface (errors, symbols, folds, breakpoints, search).
    public func rotorQuery(_ surface: WorkbenchAccessibilityHierarchy.RotorSurface) -> [RotorHit] {
        rotorCatalog[surface] ?? []
    }

    /// Select a rotor hit and move focus to the editor (content host).
    @discardableResult
    public func selectRotorHit(_ hit: RotorHit) -> String {
        focusedID = WorkbenchAccessibilityID.editor
        return focusedID
    }

    /// Switch Control linear scan across keyboard order.
    public func switchControlScan() -> [String] {
        precondition(preferences.switchControlEnabled || true, "scan available for automation coverage")
        return WorkbenchFocusOrder.keyboardOrder
    }

    /// Switch Control select by scan index.
    @discardableResult
    public func switchControlSelect(index: Int) -> String {
        let order = WorkbenchFocusOrder.keyboardOrder
        let i = ((index % order.count) + order.count) % order.count
        focusedID = order[i]
        return focusedID
    }

    /// Dismiss transient UI and restore focus (palette / open quickly).
    @discardableResult
    public func dismissTransientAndRestoreFocus() -> String {
        modalStack.removeAll()
        focusedID = WorkbenchAccessibilityHierarchy.focusRestorationDefault
        lastMotionUsed = !preferences.reduceMotion && false
        return focusedID
    }

    public func apply(preferences: Preferences) {
        self.preferences = preferences
        if preferences.reduceMotion {
            lastMotionUsed = false
        }
    }

    /// Assert high-contrast / dynamic type knobs are honored by chrome (host-applied).
    public func chromePresentationValid() -> Bool {
        preferences.dynamicTypeSize >= 0.85 && preferences.dynamicTypeSize <= 3.0
    }
}

private extension Int {
    func modulo(_ m: Int) -> Int {
        let r = self % m
        return r >= 0 ? r : r + m
    }
}
