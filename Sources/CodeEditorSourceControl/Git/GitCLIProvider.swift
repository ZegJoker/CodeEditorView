import Foundation
import CodeEditorDocuments

/// Source-control provider backed by the `git` CLI.
public struct GitCLIProvider: SourceControlProvider {
    public let id = "git"
    public var repositoryRoot: URL
    public var executable: URL

    public init(
        repositoryRoot: URL,
        executable: URL = URL(fileURLWithPath: "/usr/bin/git")
    ) {
        self.repositoryRoot = repositoryRoot
        self.executable = executable
    }

    public func status() async throws -> [SCMFileStatus] {
        let output = try await run(["status", "--porcelain=v1", "-uall"])
        return GitPorcelain.parseStatus(output, repositoryRoot: repositoryRoot)
    }

    public func branches() async throws -> SCMBranchList {
        let output = try await run(["branch", "--list"])
        var branches: [SCMBranch] = []
        var current: String?
        for line in output.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("* ") {
                let name = String(s.dropFirst(2))
                current = name
                branches.append(SCMBranch(name: name, isCurrent: true))
            } else if !s.isEmpty {
                branches.append(SCMBranch(name: s, isCurrent: false))
            }
        }
        return SCMBranchList(branches: branches, current: current)
    }

    public func diff(uri: DocumentURI) async throws -> String {
        let path = uri.fileURL?.path ?? uri.rawValue
        let rel: String
        let rootPath = repositoryRoot.path
        if path.hasPrefix(rootPath) {
            rel = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            rel = path
        }
        return try await run(["diff", "--", rel])
    }

    public func stage(uris: [DocumentURI]) async throws {
        let paths = uris.compactMap { relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths)
    }

    public func unstage(uris: [DocumentURI]) async throws {
        let paths = uris.compactMap { relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await run(["restore", "--staged", "--"] + paths)
    }

    public func commit(message: String) async throws {
        _ = try await run(["commit", "-m", message])
    }

    public func discard(uris: [DocumentURI]) async throws {
        let paths = uris.compactMap { relativePath(for: $0) }
        guard !paths.isEmpty else { return }
        _ = try await run(["checkout", "--"] + paths)
    }

    private func relativePath(for uri: DocumentURI) -> String? {
        guard let path = uri.fileURL?.path else { return nil }
        let root = repositoryRoot.path
        if path.hasPrefix(root) {
            return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return path
    }

    private func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = repositoryRoot
            let pipe = Pipe()
            let err = Pipe()
            process.standardOutput = pipe
            process.standardError = err
            do {
                try process.run()
            } catch {
                cont.resume(throwing: SCMError.failed(String(describing: error)))
                return
            }
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    let e = String(data: errData, encoding: .utf8) ?? out
                    if e.lowercased().contains("not a git repository") {
                        cont.resume(throwing: SCMError.notARepository)
                    } else {
                        cont.resume(throwing: SCMError.failed(e))
                    }
                    return
                }
                cont.resume(returning: out)
            }
        }
    }
}
