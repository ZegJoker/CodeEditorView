import CodeEditorWorkspace
import Foundation

// MARK: - Lifecycle

/// Explicit workbench session lifecycle.
public enum WorkbenchLifecyclePhase: String, Sendable, Hashable, Codable, CaseIterable {
    case creating
    case active
    case background
    case restoring
    case tearingDown
}

// MARK: - Focus

/// Focus targets for command routing and keyboard navigation.
public enum WorkbenchFocusTarget: String, Sendable, Hashable, Codable, CaseIterable {
    case editor
    case navigator
    case inspector
    case utility
    case commandPalette
    case openQuickly
    case toolbar
}

// MARK: - Multi-window

public struct WorkbenchWindowID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Chrome + selection state for one workbench window (scene).
public struct WorkbenchWindowState: Codable, Sendable, Hashable {
    public var id: WorkbenchWindowID
    public var title: String
    public var isNavigatorVisible: Bool
    public var isInspectorVisible: Bool
    public var isUtilityVisible: Bool
    public var activeNavigatorID: String?
    public var activeUtilityID: String?
    public var utilityHeight: Double
    public var focusedTarget: WorkbenchFocusTarget
    public var statusMessage: String

    public init(
        id: WorkbenchWindowID = WorkbenchWindowID(),
        title: String = "Workbench",
        isNavigatorVisible: Bool = true,
        isInspectorVisible: Bool = false,
        isUtilityVisible: Bool = false,
        activeNavigatorID: String? = nil,
        activeUtilityID: String? = nil,
        utilityHeight: Double = 180,
        focusedTarget: WorkbenchFocusTarget = .editor,
        statusMessage: String = ""
    ) {
        self.id = id
        self.title = title
        self.isNavigatorVisible = isNavigatorVisible
        self.isInspectorVisible = isInspectorVisible
        self.isUtilityVisible = isUtilityVisible
        self.activeNavigatorID = activeNavigatorID
        self.activeUtilityID = activeUtilityID
        self.utilityHeight = utilityHeight
        self.focusedTarget = focusedTarget
        self.statusMessage = statusMessage
    }
}

// MARK: - Restoration

public struct WorkbenchRestorationState: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var lifecyclePhase: WorkbenchLifecyclePhase
    public var windows: [WorkbenchWindowState]
    public var focusedWindowID: WorkbenchWindowID?
    public var workspace: WorkspaceRestorationState?
    /// Contribution ids that were active (best-effort restore of selection).
    public var registeredContributionIDs: [String]
    public var toolingSurfaces: [WorkbenchToolingSurfaceSnapshot]

    public init(
        schemaVersion: Int = WorkbenchRestorationState.currentSchemaVersion,
        lifecyclePhase: WorkbenchLifecyclePhase = .active,
        windows: [WorkbenchWindowState] = [],
        focusedWindowID: WorkbenchWindowID? = nil,
        workspace: WorkspaceRestorationState? = nil,
        registeredContributionIDs: [String] = [],
        toolingSurfaces: [WorkbenchToolingSurfaceSnapshot] = []
    ) {
        self.schemaVersion = schemaVersion
        self.lifecyclePhase = lifecyclePhase
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        self.workspace = workspace
        self.registeredContributionIDs = registeredContributionIDs
        self.toolingSurfaces = toolingSurfaces
    }
}

public enum WorkbenchRestorationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptPayload(String)
}

public enum WorkbenchRestoration {
    /// Migrate known older schemas. **Rejects** unknown future schemas (audit §8.9).
    public static func migrate(_ state: WorkbenchRestorationState) throws -> WorkbenchRestorationState {
        if state.schemaVersion > WorkbenchRestorationState.currentSchemaVersion {
            throw WorkbenchRestorationError.unsupportedSchemaVersion(
                found: state.schemaVersion,
                supported: WorkbenchRestorationState.currentSchemaVersion
            )
        }
        if state.schemaVersion < 1 {
            throw WorkbenchRestorationError.unsupportedSchemaVersion(
                found: state.schemaVersion,
                supported: WorkbenchRestorationState.currentSchemaVersion
            )
        }
        // v1 is baseline; future versions migrate stepwise here.
        return state
    }

    public static func encode(_ state: WorkbenchRestorationState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(try migrate(state))
    }

    public static func decode(_ data: Data) throws -> WorkbenchRestorationState {
        let decoder = JSONDecoder()
        do {
            let state = try decoder.decode(WorkbenchRestorationState.self, from: data)
            return try migrate(state)
        } catch let error as WorkbenchRestorationError {
            throw error
        } catch {
            throw WorkbenchRestorationError.corruptPayload(String(describing: error))
        }
    }
}

// MARK: - Window registry

@MainActor
public final class WorkbenchWindowRegistry {
    public private(set) var windows: [WorkbenchWindowID: WorkbenchWindowState] = [:]
    public private(set) var focusedWindowID: WorkbenchWindowID?
    public private(set) var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public func create(title: String = "Workbench", from template: WorkbenchWindowState? = nil) -> WorkbenchWindowState
    {
        var state = template ?? WorkbenchWindowState(title: title)
        state.id = WorkbenchWindowID()
        state.title = title
        windows[state.id] = state
        focusedWindowID = state.id
        revision &+= 1
        return state
    }

    public func update(_ state: WorkbenchWindowState) {
        windows[state.id] = state
        revision &+= 1
    }

    public func focus(_ id: WorkbenchWindowID) {
        guard windows[id] != nil else { return }
        focusedWindowID = id
        revision &+= 1
    }

    public func close(_ id: WorkbenchWindowID) {
        windows.removeValue(forKey: id)
        if focusedWindowID == id {
            focusedWindowID = windows.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }).first
        }
        revision &+= 1
    }

    public func allWindows() -> [WorkbenchWindowState] {
        windows.values.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    public func focused() -> WorkbenchWindowState? {
        guard let focusedWindowID else { return windows.values.first }
        return windows[focusedWindowID]
    }

    public func applyRestoration(_ state: WorkbenchRestorationState) {
        windows = Dictionary(uniqueKeysWithValues: state.windows.map { ($0.id, $0) })
        focusedWindowID = state.focusedWindowID ?? state.windows.first?.id
        revision &+= 1
    }

    public func capture() -> (windows: [WorkbenchWindowState], focused: WorkbenchWindowID?) {
        (allWindows(), focusedWindowID)
    }
}
