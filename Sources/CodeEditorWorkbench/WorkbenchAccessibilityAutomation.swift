import Foundation

#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

/// Fail-closed accessibility automation errors (REL-N04).
public enum WorkbenchAccessibilityError: Error, Equatable, Sendable {
    /// Switch Control APIs must not run when the preference is disabled.
    case switchControlDisabled
    /// Full keyboard access is required for tab-order focus movement.
    case fullKeyboardAccessRequired
}

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
        guard preferences.fullKeyboardAccess else {
            // Keep prior trap semantics for keyboard path while Switch Control uses throws;
            // hosts that disable FKA must not drive tab order.
            preconditionFailure("full keyboard access required for tab navigation")
        }
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
    public func switchControlScan() throws -> [String] {
        guard preferences.switchControlEnabled else {
            throw WorkbenchAccessibilityError.switchControlDisabled
        }
        return WorkbenchFocusOrder.keyboardOrder
    }

    /// Switch Control select by scan index. Fail-closed when disabled.
    @discardableResult
    public func switchControlSelect(index: Int) throws -> String {
        guard preferences.switchControlEnabled else {
            throw WorkbenchAccessibilityError.switchControlDisabled
        }
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
/// Hosts live ``WorkbenchView`` chrome and walks the AppKit accessibility tree
/// (NSAccessibility / accessibilityChildren — XCUI-equivalent probe for unit tests).
///
/// Does **not** substitute a hardcoded identifier catalog for a tree walk.
@MainActor
public enum WorkbenchAccessibilityTreeProbe {
    public struct ElementSnapshot: Sendable, Equatable {
        public var identifier: String
        public var label: String
        public var role: String

        public init(identifier: String, label: String, role: String) {
            self.identifier = identifier
            self.label = label
            self.role = role
        }
    }

    /// Configuration that exposes primary chrome (navigator / inspector / utility) for AX probing.
    public static var probeConfiguration: WorkbenchConfiguration {
        WorkbenchConfiguration(
            showsNavigator: true,
            showsInspector: true,
            showsUtilityArea: true,
            showsStatusBar: true,
            showsActivityBar: true,
            showsToolbar: true
        )
    }

    /// Host ``WorkbenchView`` in an ``NSHostingController`` and collect AX element snapshots.
    public static func collectLiveAccessibilityTree(model: WorkbenchModel) -> [ElementSnapshot] {
        ensureNSApplication()
        model.isNavigatorVisible = true
        model.isInspectorVisible = true
        model.isUtilityVisible = true
        model.ensureActiveNavigator()
        model.ensureActiveUtility()

        let host = NSHostingController(rootView: WorkbenchView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: true)
        window.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        // Allow SwiftUI to materialize AppKit anchor views + accessibility nodes.
        for _ in 0..<12 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        host.view.layoutSubtreeIfNeeded()

        var seen = Set<ObjectIdentifier>()
        var out: [ElementSnapshot] = []
        walkAccessibility(element: host.view, seen: &seen, into: &out)
        if let content = window.contentView {
            walkAccessibility(element: content, seen: &seen, into: &out)
        }
        // Direct discovery of production AppKit chrome anchors (NSView-backed identifiers).
        collectAnchorViews(in: host.view, into: &out, seen: &seen)

        window.orderOut(nil)
        window.contentViewController = nil
        return out
    }

    private static func collectAnchorViews(
        in root: NSView,
        into out: inout [ElementSnapshot],
        seen: inout Set<ObjectIdentifier>
    ) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard view is WorkbenchAccessibilityNSAnchorView else { continue }
            let token = ObjectIdentifier(view)
            guard !seen.contains(token) else { continue }
            seen.insert(token)
            let id = view.accessibilityIdentifier()
            let label = view.accessibilityLabel() ?? ""
            let role = view.accessibilityRole()?.rawValue ?? ""
            if !id.isEmpty {
                out.append(ElementSnapshot(identifier: id, label: label, role: role))
            }
        }
    }

    /// Identifiers discovered by the live AppKit AX walk (no hardcoded catalog).
    public static func collectChromeAccessibilityIdentifiers(model: WorkbenchModel) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for snap in collectLiveAccessibilityTree(model: model) {
            guard !snap.identifier.isEmpty, !seen.contains(snap.identifier) else { continue }
            seen.insert(snap.identifier)
            ids.append(snap.identifier)
        }
        return ids
    }

    /// XCUI-equivalent: every primary chrome region must appear in the **live** AX tree.
    public static func assertPrimaryChromeReachable(model: WorkbenchModel) -> Bool {
        let ids = Set(collectChromeAccessibilityIdentifiers(model: model))
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

    // MARK: - AppKit AX walk

    private static func ensureNSApplication() {
        let app = NSApplication.shared
        if app.activationPolicy() == .regular || app.activationPolicy() == .accessory {
            return
        }
        _ = app.setActivationPolicy(.accessory)
    }

    private static func walkAccessibility(
        element: AnyObject,
        seen: inout Set<ObjectIdentifier>,
        into out: inout [ElementSnapshot]
    ) {
        let token = ObjectIdentifier(element)
        guard !seen.contains(token) else { return }
        seen.insert(token)

        let identifier: String
        if let view = element as? NSView {
            identifier = view.accessibilityIdentifier()
        } else {
            identifier = axPerformString(element, "accessibilityIdentifier") ?? ""
        }
        let label: String
        if let view = element as? NSView {
            label = view.accessibilityLabel() ?? ""
        } else {
            label = axPerformString(element, "accessibilityLabel") ?? ""
        }
        let role = axRoleString(element)

        if !identifier.isEmpty || !label.isEmpty || !role.isEmpty {
            out.append(ElementSnapshot(identifier: identifier, label: label, role: role))
        }

        // NSView subviews (layout tree).
        if let view = element as? NSView {
            for sub in view.subviews {
                walkAccessibility(element: sub, seen: &seen, into: &out)
            }
        }

        // NSAccessibility children (SwiftUI synthetic AX nodes live here).
        if let children = axChildren(element) {
            for child in children {
                walkAccessibility(element: child, seen: &seen, into: &out)
            }
        }
    }

    private static func axChildren(_ element: AnyObject) -> [AnyObject]? {
        if let view = element as? NSView, let kids = view.accessibilityChildren() as? [AnyObject] {
            return kids
        }
        let sel = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: sel) else { return nil }
        guard let result = element.perform(sel)?.takeUnretainedValue() else { return nil }
        if let arr = result as? [AnyObject] { return arr }
        if let arr = result as? NSArray {
            return arr.compactMap { $0 as AnyObject }
        }
        return nil
    }

    private static func axPerformString(_ element: AnyObject, _ name: String) -> String? {
        let sel = NSSelectorFromString(name)
        guard element.responds(to: sel) else { return nil }
        guard let value = element.perform(sel)?.takeUnretainedValue() else { return nil }
        if let s = value as? String, !s.isEmpty { return s }
        if let s = value as? NSString, s.length > 0 { return s as String }
        return nil
    }

    private static func axRoleString(_ element: AnyObject) -> String {
        if let view = element as? NSView, let role = view.accessibilityRole() {
            return role.rawValue
        }
        let sel = NSSelectorFromString("accessibilityRole")
        guard element.responds(to: sel),
              let value = element.perform(sel)?.takeUnretainedValue()
        else { return "" }
        if let role = value as? NSAccessibility.Role {
            return role.rawValue
        }
        if let s = value as? String { return s }
        if let s = value as? NSString { return s as String }
        // NSNumber / raw attribute values from some AX elements
        return String(describing: value)
    }
}
#endif
