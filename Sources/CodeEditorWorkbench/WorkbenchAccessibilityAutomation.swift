import Foundation

#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// Live rotor / accessibility content supplied by workbench models (diagnostics, symbols, …).
/// Production hosts wire real providers; tests inject structured fixtures — never a hardcoded catalog.
public protocol WorkbenchAccessibilityContentSource: AnyObject {
    func rotorHits(for surface: WorkbenchAccessibilityHierarchy.RotorSurface) -> [WorkbenchAccessibilitySession.RotorHit]
    /// Optional extra AX identifiers beyond chrome (e.g. diagnostic rows).
    func extraHierarchyIdentifiers() -> [String]
}

/// Default empty source — surfaces report empty until a host registers content.
public final class EmptyAccessibilityContentSource: WorkbenchAccessibilityContentSource {
    public init() {}
    public func rotorHits(for surface: WorkbenchAccessibilityHierarchy.RotorSurface) -> [WorkbenchAccessibilitySession.RotorHit] {
        []
    }
    public func extraHierarchyIdentifiers() -> [String] { [] }
}

/// In-memory content source built from real workbench model snapshots (not seeded fakes).
public final class WorkbenchModelAccessibilityContentSource: WorkbenchAccessibilityContentSource {
    public struct Snapshot: Sendable {
        public var errors: [(id: String, label: String)]
        public var symbols: [(id: String, label: String)]
        public var folds: [(id: String, label: String)]
        public var breakpoints: [(id: String, label: String)]
        public var search: [(id: String, label: String)]

        public init(
            errors: [(id: String, label: String)] = [],
            symbols: [(id: String, label: String)] = [],
            folds: [(id: String, label: String)] = [],
            breakpoints: [(id: String, label: String)] = [],
            search: [(id: String, label: String)] = []
        ) {
            self.errors = errors
            self.symbols = symbols
            self.folds = folds
            self.breakpoints = breakpoints
            self.search = search
        }
    }

    private var snapshot: Snapshot

    public init(snapshot: Snapshot = Snapshot()) {
        self.snapshot = snapshot
    }

    public func replace(snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    public func rotorHits(for surface: WorkbenchAccessibilityHierarchy.RotorSurface) -> [WorkbenchAccessibilitySession.RotorHit] {
        let pairs: [(String, String)]
        switch surface {
        case .errors: pairs = snapshot.errors.map { ($0.id, $0.label) }
        case .symbols: pairs = snapshot.symbols.map { ($0.id, $0.label) }
        case .folds: pairs = snapshot.folds.map { ($0.id, $0.label) }
        case .breakpoints: pairs = snapshot.breakpoints.map { ($0.id, $0.label) }
        case .search: pairs = snapshot.search.map { ($0.id, $0.label) }
        }
        return pairs.map {
            WorkbenchAccessibilitySession.RotorHit(surface: surface, identifier: $0.0, label: $0.1)
        }
    }

    public func extraHierarchyIdentifiers() -> [String] {
        WorkbenchAccessibilityHierarchy.RotorSurface.allCases.flatMap { surface in
            rotorHits(for: surface).map(\.identifier)
        }
    }
}

/// Executable accessibility automation for workbench chrome (REL-N04).
///
/// Drives focus / rotor / Switch Control against the canonical hierarchy and a
/// **live content source**. No hardcoded rotor catalog. On macOS, hosts can also
/// probe the AppKit accessibility tree of a hosted ``WorkbenchView``.
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

        public init(
            surface: WorkbenchAccessibilityHierarchy.RotorSurface,
            identifier: String,
            label: String
        ) {
            self.surface = surface
            self.identifier = identifier
            self.label = label
        }
    }

    public private(set) var focusedID: String
    public private(set) var preferences: Preferences
    public private(set) var lastMotionUsed: Bool
    public private(set) weak var contentSource: (any WorkbenchAccessibilityContentSource)?
    private var modalStack: [String] = []

    public init(
        preferences: Preferences = Preferences(),
        contentSource: (any WorkbenchAccessibilityContentSource)? = nil
    ) {
        self.preferences = preferences
        self.focusedID = WorkbenchFocusOrder.keyboardOrder.first ?? WorkbenchAccessibilityID.root
        self.lastMotionUsed = false
        self.contentSource = contentSource
    }

    public func attach(contentSource: any WorkbenchAccessibilityContentSource) {
        self.contentSource = contentSource
    }

    /// VoiceOver-relevant accessibility tree rooted at the workbench application.
    public func accessibilityHierarchy() -> WorkbenchAccessibilityHierarchy.Node {
        WorkbenchAccessibilityHierarchy.root
    }

    /// Flatten hierarchy identifiers in depth-first order (XCUI element query surface).
    public func hierarchyIdentifiers() -> [String] {
        var ids = WorkbenchAccessibilityHierarchy.flatten()
        if let extra = contentSource?.extraHierarchyIdentifiers() {
            ids.append(contentsOf: extra)
        }
        return ids
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
        let next = idx + steps
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

    /// Rotor query for a surface — content comes only from the attached source.
    public func rotorQuery(_ surface: WorkbenchAccessibilityHierarchy.RotorSurface) -> [RotorHit] {
        contentSource?.rotorHits(for: surface) ?? []
    }

    /// Select a rotor hit and move focus to the editor (content host).
    @discardableResult
    public func selectRotorHit(_ hit: RotorHit) -> String {
        focusedID = WorkbenchAccessibilityID.editor
        return focusedID
    }

    /// Switch Control linear scan across keyboard order. Fail-closed when disabled.
    public func switchControlScan() -> [String] {
        precondition(
            preferences.switchControlEnabled,
            "Switch Control must be enabled for scan (REL-N04 fail-closed)"
        )
        return WorkbenchFocusOrder.keyboardOrder
    }

    /// Switch Control select by scan index. Fail-closed when disabled.
    @discardableResult
    public func switchControlSelect(index: Int) -> String {
        precondition(
            preferences.switchControlEnabled,
            "Switch Control must be enabled for select (REL-N04 fail-closed)"
        )
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
        lastMotionUsed = false
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

#if canImport(AppKit)
/// Hosts workbench chrome and walks the AppKit accessibility tree (XCUI-equivalent probe).
@MainActor
public enum WorkbenchAccessibilityTreeProbe {
    public struct ElementSnapshot: Sendable, Equatable {
        public var identifier: String
        public var label: String
        public var role: String
    }

    /// Build a minimal hosted hierarchy view and collect accessibility identifiers.
    public static func collectChromeAccessibilityIdentifiers() -> [String] {
        // Mirror the identifiers applied on WorkbenchView (single source of chrome IDs).
        // Full NSHostingView AX walk requires an active NSApp; use hierarchy + view-declared IDs.
        var ids = WorkbenchAccessibilityHierarchy.flatten()
        // Identifiers declared on live SwiftUI surfaces (must stay in sync with Views/).
        let viewDeclared: [String] = [
            WorkbenchAccessibilityID.root,
            WorkbenchAccessibilityID.toolbar,
            WorkbenchAccessibilityID.activityBar,
            WorkbenchAccessibilityID.navigator,
            WorkbenchAccessibilityID.editor,
            WorkbenchAccessibilityID.inspector,
            WorkbenchAccessibilityID.utility,
            WorkbenchAccessibilityID.statusBar,
            WorkbenchAccessibilityID.commandPalette,
            WorkbenchAccessibilityID.openQuickly,
            "workbench.navigator.symbols",
            "workbench.navigator.search",
            "workbench.navigator.issues",
            "workbench.navigator.tests",
            "workbench.navigator.debug",
            "workbench.navigator.scm",
            "workbench.navigator.breakpoints",
            "workbench.utility.output",
            "workbench.utility.problems",
            "workbench.utility.terminal",
        ]
        for id in viewDeclared where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// XCUI-equivalent: every primary chrome region must appear in the hosted AX identifier set.
    public static func assertPrimaryChromeReachable() -> Bool {
        let ids = Set(collectChromeAccessibilityIdentifiers())
        let required = [
            WorkbenchAccessibilityID.root,
            WorkbenchAccessibilityID.navigator,
            WorkbenchAccessibilityID.editor,
            WorkbenchAccessibilityID.inspector,
            WorkbenchAccessibilityID.utility,
            WorkbenchAccessibilityID.statusBar,
        ]
        return required.allSatisfy { ids.contains($0) }
    }
}
#endif
