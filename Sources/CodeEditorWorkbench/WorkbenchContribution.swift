import CodeEditorCommands
import CodeEditorWorkspace
import Observation
import SwiftUI

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

/// Trust boundary for contributions (WB-N01).
///
/// - ``trustedInProcess``: first-party / host Swift code that may construct native views.
///   These run in-process and are **not** security- or crash-isolated.
/// - ``declarativeUntrusted``: extension/data contributions that only supply declarative
///   view models; the host owns rendering over the capability boundary.
public enum WorkbenchContributionTrust: String, Sendable, Hashable, Codable {
    case trustedInProcess
    case declarativeUntrusted
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
    public var trust: WorkbenchContributionTrust

    public init(
        id: String,
        slot: WorkbenchSlot,
        priority: Int,
        title: String,
        systemImage: String = "square.grid.2x2",
        providerID: String,
        availability: WorkbenchContributionAvailability = .available,
        faultMessage: String? = nil,
        trust: WorkbenchContributionTrust = .trustedInProcess
    ) {
        self.id = id
        self.slot = slot
        self.priority = priority
        self.title = title
        self.systemImage = systemImage
        self.providerID = providerID
        self.availability = availability
        self.faultMessage = faultMessage
        self.trust = trust
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
///
/// **Not isolated:** `makeBody` runs in-process. Crashes, hangs, and privilege abuse
/// are not contained by error-presentation wrappers (WB-N01).
@MainActor
public protocol WorkbenchContribution: AnyObject, Identifiable {
    var id: String { get }
    var slot: WorkbenchSlot { get }
    var priority: Int { get }
    var title: String { get }
    /// SF Symbol used in activity bar / utility tabs (Xcode-like mode switcher).
    var systemImage: String { get }
    var providerID: String { get }
    /// Trust level. Defaults to trusted in-process native code.
    var trust: WorkbenchContributionTrust { get }
    func makeBody(context: WorkbenchContributionContext) -> AnyView
}

extension WorkbenchContribution {
    public var systemImage: String { "square.grid.2x2" }
    public var providerID: String { id }
    public var trust: WorkbenchContributionTrust { .trustedInProcess }

    public func descriptor(
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
            faultMessage: faultMessage,
            trust: trust
        )
    }
}

// MARK: - Declarative untrusted contributions (WB-N01)

/// One row in a host-rendered declarative panel.
public struct WorkbenchDeclarativeRow: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var detail: String?

    public init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

/// Declarative view model for untrusted extensions (data only — no View construction).
public struct WorkbenchDeclarativeContributionViewModel: Identifiable, Sendable, Hashable {
    public var id: String
    public var slot: WorkbenchSlot
    public var priority: Int
    public var title: String
    public var systemImage: String
    public var providerID: String
    public var rows: [WorkbenchDeclarativeRow]
    public var trust: WorkbenchContributionTrust { .declarativeUntrusted }

    public init(
        id: String,
        slot: WorkbenchSlot,
        priority: Int,
        title: String,
        systemImage: String = "puzzlepiece.extension",
        providerID: String,
        rows: [WorkbenchDeclarativeRow] = []
    ) {
        self.id = id
        self.slot = slot
        self.priority = priority
        self.title = title
        self.systemImage = systemImage
        self.providerID = providerID
        self.rows = rows
    }
}

/// Host-owned renderer for declarative contribution view models.
@MainActor
public enum WorkbenchDeclarativeContributionRenderer {
    public static func makeBody(viewModel: WorkbenchDeclarativeContributionViewModel) -> AnyView {
        AnyView(DeclarativeContributionListView(viewModel: viewModel))
    }
}

@MainActor
struct DeclarativeContributionListView: View {
    let viewModel: WorkbenchDeclarativeContributionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(viewModel.title, systemImage: viewModel.systemImage)
                    .font(.headline)
                Spacer()
                Text("Declarative")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if viewModel.rows.isEmpty {
                ContentUnavailableView(
                    "No items",
                    systemImage: viewModel.systemImage,
                    description: Text("Extension provided no rows.")
                )
            } else {
                List(viewModel.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .accessibilityIdentifier("workbench.declarative.\(viewModel.id)")
    }
}

/// Host wrapper that presents a declarative view model as a ``WorkbenchContribution``.
@MainActor
public final class DeclarativeWorkbenchContribution: WorkbenchContribution {
    public let id: String
    public let slot: WorkbenchSlot
    public let priority: Int
    public let title: String
    public let systemImage: String
    public let providerID: String
    public let trust: WorkbenchContributionTrust = .declarativeUntrusted
    private let viewModel: WorkbenchDeclarativeContributionViewModel

    public init(viewModel: WorkbenchDeclarativeContributionViewModel) {
        self.viewModel = viewModel
        self.id = viewModel.id
        self.slot = viewModel.slot
        self.priority = viewModel.priority
        self.title = viewModel.title
        self.systemImage = viewModel.systemImage
        self.providerID = viewModel.providerID
    }

    public func makeBody(context: WorkbenchContributionContext) -> AnyView {
        WorkbenchDeclarativeContributionRenderer.makeBody(viewModel: viewModel)
    }
}

/// Result of rendering a contribution for status/diagnostics.
public enum WorkbenchContributionRender: Sendable {
    case view
    case error(message: String)
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
    /// Errors recorded when contribution rendering fails (per-contribution error presentation).
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
        // Dispose unregisters synchronously on MainActor (CMD-N03 pattern).
        return RegistrationToken { [weak self] in
            guard let self else { return }
            if self.entries[contribution.id]?.tokenID == tokenID {
                self.entries.removeValue(forKey: contribution.id)
                self.faults.removeValue(forKey: contribution.id)
                self.revision &+= 1
            }
        }
    }

    /// Register a declarative (untrusted) contribution; host owns the view (WB-N01).
    @discardableResult
    public func registerDeclarative(
        _ viewModel: WorkbenchDeclarativeContributionViewModel
    ) -> any CommandDisposable {
        register(DeclarativeWorkbenchContribution(viewModel: viewModel))
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

    /// Error-presentation wrapper for contribution bodies (WB-N01).
    ///
    /// Displays a host-owned fallback when a contribution is marked failed.
    /// This is **not** crash, hang, memory, or security isolation — only UI error presentation
    /// for ordinary failure states recorded via ``markFailed(id:message:)``.
    public func makeBodyWithErrorPresentation(
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
            return AnyView(ContributionErrorPresentationView(title: contribution.title, message: fault))
        }
        return AnyView(
            ContributionBodyContainer(contribution: contribution, context: context)
        )
    }
}

/// Host container for a contribution body (no isolation claims).
@MainActor
struct ContributionBodyContainer: View {
    let contribution: any WorkbenchContribution
    let context: WorkbenchContributionContext

    var body: some View {
        contribution.makeBody(context: context)
    }
}

/// Error-presentation UI when a contribution is marked failed (WB-N01).
@MainActor
struct ContributionErrorPresentationView: View {
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
