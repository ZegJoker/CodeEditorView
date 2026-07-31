import Foundation
import CodeEditorExtensionAPI

@main
struct CodeEditorExtensionCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(2)
        }
        do {
            switch command {
            case "validate":
                guard args.count >= 2 else { fail("validate requires a package path") }
                try validate(path: args[1])
            case "digest":
                guard args.count >= 2 else { fail("digest requires a package path") }
                try digest(path: args[1])
            case "migrate":
                try migrate(args: Array(args.dropFirst()))
            case "help", "-h", "--help":
                printUsage()
            default:
                fail("unknown command \(command)")
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print(
            """
            codeeditor-extension — CodeEditorView extension packaging tools

            Usage:
              codeeditor-extension validate <package-dir>
              codeeditor-extension digest <package-dir>
              codeeditor-extension migrate --from extension.json --to extension.toml [--dir <package-dir>] [--report <file>] [--swift-template]
            """
        )
    }

    static func fail(_ message: String) -> Never {
        fputs("error: \(message)\n", stderr)
        printUsage()
        exit(2)
    }

    static func validate(path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let plan = try ExtensionPackageLoader.load(directory: url)
        print("ok: \(plan.packageID.rawValue)@\(plan.version) format=\(plan.sourceFormat.rawValue)")
        print("digest: \(plan.digest ?? "n/a")")
        print("parity: \(plan.parityProfile)")
        print(
            "themes=\(plan.themes.count) snippets=\(plan.snippets.count) languages=\(plan.languages.count) icons=\(plan.iconThemes.count) grammars=\(plan.grammars.count) queries=\(plan.queries.count)"
        )
        if !plan.unsupportedFields.isEmpty {
            print("unsupported_fields: \(plan.unsupportedFields.joined(separator: ", "))")
        }
        for d in plan.diagnostics {
            let path = d.path.map { " (\($0))" } ?? ""
            print("\(d.severity.rawValue): [\(d.code)] \(d.message)\(path)")
        }
        if plan.hasErrors { exit(1) }
    }

    static func digest(path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let digest = try ExtensionPackageDigest.compute(packageRoot: url)
        print(digest)
    }

    static func migrate(args: [String]) throws {
        var from = "extension.json"
        var to = "extension.toml"
        var dir = FileManager.default.currentDirectoryPath
        var reportPath: String?
        var swiftTemplate = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--from":
                i += 1
                guard i < args.count else { fail("--from requires a value") }
                from = args[i]
            case "--to":
                i += 1
                guard i < args.count else { fail("--to requires a value") }
                to = args[i]
            case "--dir":
                i += 1
                guard i < args.count else { fail("--dir requires a value") }
                dir = args[i]
            case "--report":
                i += 1
                guard i < args.count else { fail("--report requires a value") }
                reportPath = args[i]
            case "--swift-template":
                swiftTemplate = true
            default:
                fail("unknown migrate flag \(args[i])")
            }
            i += 1
        }
        guard from.hasSuffix(".json"), to.hasSuffix(".toml") else {
            fail("migrate currently supports JSON → TOML only")
        }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let result = try ExtensionMigration.migrateJSONToTOML(
            directory: root,
            writeSwiftTemplate: swiftTemplate
        )
        if let reportPath {
            try result.report.write(to: URL(fileURLWithPath: reportPath), atomically: true, encoding: .utf8)
        } else {
            let defaultReport = root.appendingPathComponent("MIGRATION-REPORT.md")
            try result.report.write(to: defaultReport, atomically: true, encoding: .utf8)
        }
        print("migrated \(result.packageID.rawValue) → extension.toml")
        print("parity: \(result.plan.parityProfile)")
        print("digest: \(result.plan.digest ?? "n/a")")
        for todo in result.todos {
            print("todo: \(todo)")
        }
    }
}
