import Foundation

public struct TerminalSessionID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct TerminalConfiguration: Sendable, Hashable {
    public var shell: URL?
    public var arguments: [String]
    public var cwd: URL?
    public var environment: [String: String]
    public var cols: Int
    public var rows: Int

    public init(
        shell: URL? = URL(fileURLWithPath: "/bin/sh"),
        arguments: [String] = ["-i"],
        cwd: URL? = nil,
        environment: [String: String] = [:],
        cols: Int = 80,
        rows: Int = 24
    ) {
        self.shell = shell
        self.arguments = arguments
        self.cwd = cwd
        self.environment = environment
        self.cols = cols
        self.rows = rows
    }
}

public enum TerminalOutputEvent: Sendable, Hashable {
    case data(session: TerminalSessionID, bytes: Data)
    case exited(session: TerminalSessionID, code: Int32)
}

public struct TerminalSessionHandle: Sendable, Hashable {
    public var id: TerminalSessionID
    public init(id: TerminalSessionID = TerminalSessionID()) {
        self.id = id
    }
}

public struct TerminalSession: Sendable, Hashable, Identifiable {
    public var id: TerminalSessionID
    public var title: String
    public var configuration: TerminalConfiguration
    public var isRunning: Bool

    public init(
        id: TerminalSessionID = TerminalSessionID(),
        title: String = "Terminal",
        configuration: TerminalConfiguration = TerminalConfiguration(),
        isRunning: Bool = false
    ) {
        self.id = id
        self.title = title
        self.configuration = configuration
        self.isRunning = isRunning
    }
}

/// UI-free descriptor for host/workbench panel mapping.
public struct TerminalPanelDescriptor: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var sessionID: TerminalSessionID

    public init(id: String, title: String, sessionID: TerminalSessionID) {
        self.id = id
        self.title = title
        self.sessionID = sessionID
    }
}

public enum TerminalError: Error, Sendable, Equatable {
    case notRunning
    case startFailed(String)
    case sessionNotFound
}
