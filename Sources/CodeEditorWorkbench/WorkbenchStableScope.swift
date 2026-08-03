import Foundation

/// Bounded Stable 1.0 workbench feature scope (WB-N07).
///
/// Documents what the shell ships versus Xcode-class gaps that remain on the
/// roadmap. Empty navigator/utility models are valid empty states — not fake
/// panels populated with demo data pretending to be full IDE surfaces.
public struct WorkbenchStableScope: Sendable, Hashable {
    public var version: String
    /// Features included in Stable 1.0 (honest shell + service wiring).
    public var included: [String]
    /// Explicit Xcode-class gaps **not** claimed by Stable 1.0.
    public var excludedXcodeClassGaps: [String]
    /// Must remain empty: production must not register fake/demo panels as real features.
    public var fakePanelIDs: [String]
    public var claimsFullXcodeParity: Bool

    public init(
        version: String,
        included: [String],
        excludedXcodeClassGaps: [String],
        fakePanelIDs: [String] = [],
        claimsFullXcodeParity: Bool = false
    ) {
        self.version = version
        self.included = included
        self.excludedXcodeClassGaps = excludedXcodeClassGaps
        self.fakePanelIDs = fakePanelIDs
        self.claimsFullXcodeParity = claimsFullXcodeParity
    }

    /// Stable 1.0 workbench product scope.
    public static let v1 = WorkbenchStableScope(
        version: "1.0",
        included: [
            "Multi-pane editor area with tabs, preview, and pin semantics",
            "Navigator activity modes (files, symbols, search, issues, tests, debug, SCM, breakpoints)",
            "Utility panels (output, problems, terminal) with real service bindings when host provides them",
            "Open Quickly (file/symbol/command) with background file-tree index",
            "Command palette and workbench chrome commands",
            "Scheme/destination model wired to TaskService when bound",
            "SCM status model wired to SourceControlService when bound",
            "Problems bridge from task matchers",
            "Layout-based editor reveal navigation",
            "Multi-window chrome state + restoration schema",
            "Contribution registry with error presentation (trusted in-process / declarative untrusted)",
            "TaskBag lifecycle scopes per window and workbench",
            "Accessibility hierarchy, keyboard focus, reduce-motion-aware animation",
        ],
        excludedXcodeClassGaps: [
            "project/build graph and target model",
            "Full schemes/configurations/destinations/environment override IDE",
            "Structured build logs and result bundles",
            "Test plans, coverage navigation, rerun-failures UI",
            "Diff/merge/conflict editor",
            "Breakpoint conditions/actions navigator depth",
            "Variables, watch expressions, memory view, debugger console, source mapping",
            "Preview/canvas plugin providers",
            "Package/dependency navigator",
            "Inspectors and settings editors (host-owned beyond shell slots)",
            "SCM branches/remotes/auth/conflict resolution UI",
            "Multi-window state migration beyond schema v1",
            "Symbol/call/type hierarchy",
            "Find navigator replacement preview conflicts",
            "Profiling/instrumentation hooks",
            "Device/simulator/destination abstraction",
            "Signing/capability/provisioning integrations",
        ],
        fakePanelIDs: [],
        claimsFullXcodeParity: false
    )
}
