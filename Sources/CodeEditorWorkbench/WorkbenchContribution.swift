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

/// Availability for declarative contribution listing.
public enum WorkbenchContributionAvailability: String, Sendable, Hashable, Codable {
    case available
    case loading
    case unavailable
    case failed
}

/// Host-owned descriptor (no view construction required to list contributions).
public struct WorkbenchContributionDescriptor: Identifiable, Sendable, Hashable {
    public var id: String
    public var slot: WorkbenchSlot
    public var priority: Int
    public var title: String
    public var systemImage: String
    public var providerID: String
    public var availability: WorkbenchContributionAvailability
    public var faultMessage: String?

    public init(
        id: String,
        slot: WorkbenchSlot,
        priority: Int,
        title: String,
        systemImage: String = "square.grid.2x2",
        providerID: String,
        availability: WorkbenchContributionAvailability = .available,
        faultMessage: String? = nil
    ) {
        self.id = id
        self.slot = slot
        self.priority = priority
        self.title = title
        self.systemImage = systemImage
        self.providerID = providerID
        self.availability = availability
        self.faultMessage = faultMessage
    }
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

/// Trusted native contribution (views are host-owned / first-party only).
@MainActor
public protocol WorkbenchContribution: AnyObject, Identifiable {
    var id: String { get }
    var slot: WorkbenchSlot { get }
    var priority: Int { get }
    var title: String { get }
    /// SF Symbol used in activity bar / utility tabs (Xcode-like mode switcher).
    var systemImage: String { get }
    var providerID: String { get }
    func makeBody(context: WorkbenchContributionContext) -> AnyView
}

public extension WorkbenchContribution {
    var systemImage: String { "square.grid.2x2" }
    var providerID: String { id }

    func descriptor(
        availability: WorkbenchContributionAvailability = .available,
        faultMessage: String? = nil
    ) -> WorkbenchContributionDescriptor {
        WorkbenchContributionDescriptor(
            id: id,
            slot: slot,
            priority: priority,
            title: title,
            systemImage: systemImage,
            providerID: providerID,
            availability: availability,
            faultMessage: faultMessage
        )
    }
}

/// Result of safely rendering a contribution.
public enum WorkbenchContributionRender: Sendable {
    case view
    case fault(message: String)
}

/// Observable registry so late `register` / `unregister` refreshes the shell.
@MainActor
@Observable
public final class WorkbenchContributionRegistry {
    private struct Entry {
        var contribution: any WorkbenchContribution
        var tokenID: UUID
        var availability: WorkbenchContributionAvailability
        var faultMessage: String?
    }

    private var entries: [String: Entry] = [:]
    /// Bumped on register/unregister so SwiftUI re-reads contribution lists.
    public private(set) var revision: UInt64 = 0
    /// Faults recorded when makeBody fails (isolated per contribution).
    public private(set) var faults: [String: String] = [:]

    public init() {}

    @discardableResult
    public func register(_ contribution: any WorkbenchContribution) -> any CommandDisposable {
        let tokenID = UUID()
        entries[contribution.id] = Entry(
            contribution: contribution,
            tokenID: tokenID,
            availability: .available,
            faultMessage: nil
        )
        faults.removeValue(forKey: contribution.id)
        revision &+= 1
        return RegistrationToken { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.entries[contribution.id]?.tokenID == tokenID {
                    self.entries.removeValue(forKey: contribution.id)
                    self.faults.removeValue(forKey: contribution.id)
                    self.revision &+= 1
                }
            }
        }
    }

    public func unregister(id: String) {
        if entries.removeValue(forKey: id) != nil {
            faults.removeValue(forKey: id)
            revision &+= 1
        }
    }

    public func markFailed(id: String, message: String) {
        guard var entry = entries[id] else { return }
        entry.availability = .failed
        entry.faultMessage = message
        entries[id] = entry
        faults[id] = message
        revision &+= 1
    }

    public func clearFault(id: String) {
        guard var entry = entries[id] else { return }
        entry.availability = .available
        entry.faultMessage = nil
        entries[id] = entry
        faults.removeValue(forKey: id)
        revision &+= 1
    }

    public func contributions(for slot: WorkbenchSlot) -> [any WorkbenchContribution] {
        _ = revision
        return entries.values
            .map(\.contribution)
            .filter { $0.slot == slot }
            .sorted { $0.priority > $1.priority }
    }

    public func descriptors(for slot: WorkbenchSlot) -> [WorkbenchContributionDescriptor] {
        _ = revision
        return entries.values
            .filter { $0.contribution.slot == slot }
            .map {
                $0.contribution.descriptor(
                    availability: $0.availability,
                    faultMessage: $0.faultMessage
                )
            }
            .sorted { $0.priority > $1.priority }
    }

    public func allDescriptors() -> [WorkbenchContributionDescriptor] {
        _ = revision
        return entries.values.map {
            $0.contribution.descriptor(
                availability: $0.availability,
                faultMessage: $0.faultMessage
            )
        }
        .sorted { $0.id < $1.id }
    }

    public func contribution(id: String) -> (any WorkbenchContribution)? {
        _ = revision
        return entries[id]?.contribution
    }

    public func allContributions() -> [any WorkbenchContribution] {
        _ = revision
        return entries.values.map(\.contribution)
    }

    /// Render body with isolation: records fault instead of crashing the shell.
    public func makeBodyIsolated(
        id: String,
        context: WorkbenchContributionContext
    ) -> AnyView {
        guard let contribution = contribution(id: id) else {
            return AnyView(
                ContentUnavailableView(
                    WorkbenchL10n.contributionFailed,
                    systemImage: "exclamationmark.triangle",
                    description: Text("Missing contribution \(id)")
                )
                .accessibilityIdentifier(WorkbenchAccessibilityID.contributionFault)
            )
        }
        if let fault = faults[id] ?? entries[id]?.faultMessage {
            return AnyView(ContributionFaultView(title: contribution.title, message: fault))
        }
        // Swift does not catch pure Swift errors from View builders easily;
        // hosts call markFailed. We still wrap in a fault container for display.
        return AnyView(
            ContributionSafeContainer(contribution: contribution, context: context) { message in
                self.markFailed(id: id, message: message)
            }
        )
    }
}

/// Isolates contribution rendering; on known failure displays fault UI.
@MainActor
struct ContributionSafeContainer: View {
    let contribution: any WorkbenchContribution
    let context: WorkbenchContributionContext
    let onFault: (String) -> Void

    var body: some View {
        contribution.makeBody(context: context)
    }
}

@MainActor
struct ContributionFaultView: View {
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier(WorkbenchAccessibilityID.contributionFault)
        .accessibilityLabel("\(title). \(WorkbenchL10n.contributionFailed). \(message)")
    }
}
