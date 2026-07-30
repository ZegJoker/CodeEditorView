import SwiftUI
import Observation
import CodeEditorCommands
import CodeEditorWorkspace

public enum WorkbenchSlot: String, Hashable, Sendable, CaseIterable {
    case navigator
    case inspector
    case utility
    case statusBar
    case activityBar
    case editorTopAccessory
    case tabAccessory
    case toolbar
    case menuCommands
}

@MainActor
public struct WorkbenchContributionContext {
    public let workspace: Workspace
    public let model: WorkbenchModel

    public init(workspace: Workspace, model: WorkbenchModel) {
        self.workspace = workspace
        self.model = model
    }
}

@MainActor
public protocol WorkbenchContribution: AnyObject, Identifiable {
    var id: String { get }
    var slot: WorkbenchSlot { get }
    var priority: Int { get }
    var title: String { get }
    /// SF Symbol used in activity bar / utility tabs (Xcode-like mode switcher).
    var systemImage: String { get }
    func makeBody(context: WorkbenchContributionContext) -> AnyView
}

public extension WorkbenchContribution {
    var systemImage: String { "square.grid.2x2" }
}

/// Observable registry so late `register` / `unregister` refreshes the shell.
@MainActor
@Observable
public final class WorkbenchContributionRegistry {
    private struct Entry {
        var contribution: any WorkbenchContribution
        var tokenID: UUID
    }

    private var entries: [String: Entry] = [:]
    /// Bumped on register/unregister so SwiftUI re-reads contribution lists.
    public private(set) var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public func register(_ contribution: any WorkbenchContribution) -> any CommandDisposable {
        let tokenID = UUID()
        entries[contribution.id] = Entry(contribution: contribution, tokenID: tokenID)
        revision &+= 1
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.entries[contribution.id]?.tokenID == tokenID {
                    self.entries.removeValue(forKey: contribution.id)
                    self.revision &+= 1
                }
            }
        }
    }

    public func unregister(id: String) {
        if entries.removeValue(forKey: id) != nil {
            revision &+= 1
        }
    }

    public func contributions(for slot: WorkbenchSlot) -> [any WorkbenchContribution] {
        _ = revision
        return entries.values
            .map(\.contribution)
            .filter { $0.slot == slot }
            .sorted { $0.priority > $1.priority }
    }

    public func contribution(id: String) -> (any WorkbenchContribution)? {
        _ = revision
        return entries[id]?.contribution
    }

    public func allContributions() -> [any WorkbenchContribution] {
        _ = revision
        return entries.values.map(\.contribution)
    }
}
