import SwiftUI
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
}

@MainActor
public protocol WorkbenchContribution: AnyObject, Identifiable {
    var id: String { get }
    var slot: WorkbenchSlot { get }
    var priority: Int { get }
    var title: String { get }
    func makeBody(context: WorkbenchContributionContext) -> AnyView
}

@MainActor
public final class WorkbenchContributionRegistry {
    private struct Entry {
        var contribution: any WorkbenchContribution
        var tokenID: UUID
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    @discardableResult
    public func register(_ contribution: any WorkbenchContribution) -> any CommandDisposable {
        let tokenID = UUID()
        entries[contribution.id] = Entry(contribution: contribution, tokenID: tokenID)
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                if self?.entries[contribution.id]?.tokenID == tokenID {
                    self?.entries.removeValue(forKey: contribution.id)
                }
            }
        }
    }

    public func unregister(id: String) {
        entries.removeValue(forKey: id)
    }

    public func contributions(for slot: WorkbenchSlot) -> [any WorkbenchContribution] {
        entries.values
            .map(\.contribution)
            .filter { $0.slot == slot }
            .sorted { $0.priority > $1.priority }
    }

    public func allContributions() -> [any WorkbenchContribution] {
        entries.values.map(\.contribution)
    }
}
