import Foundation
import CodeEditorExtensionAPI
import CodeEditorExtensions
import CodeEditorExtensionHost

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
                try validate(path: args[1], rest: Array(args.dropFirst(2)))
            case "digest":
                guard args.count >= 2 else { fail("digest requires a package path") }
                try digest(path: args[1])
            case "migrate":
                try migrate(args: Array(args.dropFirst()))
            case "gen-key":
                try genKey(args: Array(args.dropFirst()))
            case "sign":
                try sign(args: Array(args.dropFirst()))
            case "verify":
                try verify(args: Array(args.dropFirst()))
            case "sbom":
                try sbom(args: Array(args.dropFirst()))
            case "package":
                try packageCmd(args: Array(args.dropFirst()))
            case "install":
                try await install(args: Array(args.dropFirst()))
            case "update":
                try await update(args: Array(args.dropFirst()))
            case "rollback":
                try await rollback(args: Array(args.dropFirst()))
            case "list":
                try await list(args: Array(args.dropFirst()))
            case "recover":
                try await recover(args: Array(args.dropFirst()))
            case "revoke-check":
                try revokeCheck(args: Array(args.dropFirst()))
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
            codeeditor-extension — CodeEditorView extension packaging & store tools

            Usage:
              codeeditor-extension validate <package-dir> [--keyring PATH]
              codeeditor-extension digest <package-dir>
              codeeditor-extension migrate --from extension.json --to extension.toml [--dir <package-dir>] [--report <file>] [--swift-template]
              codeeditor-extension gen-key --out <dir> [--key-id ID]
              codeeditor-extension sign --dir <package-dir> --private-key <path> --key-id ID --subject NAME
              codeeditor-extension verify --dir <package-dir> [--keyring PATH]
              codeeditor-extension sbom --dir <package-dir> [--out PATH]
              codeeditor-extension package --dir <package-dir>  (checksums + sbom)
              codeeditor-extension install --dir <package-dir> --install-root <root>
              codeeditor-extension update --id ID --dir <package-dir> --install-root <root>
              codeeditor-extension rollback --id ID --install-root <root>
              codeeditor-extension list --install-root <root>
              codeeditor-extension recover --install-root <root>
              codeeditor-extension revoke-check --dir <package-dir> --revocation PATH
            """
        )
    }

    static func fail(_ message: String) -> Never {
        fputs("error: \(message)\n", stderr)
        printUsage()
        exit(2)
    }

    static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func validate(path: String, rest: [String]) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let plan = try ExtensionPackageLoader.load(directory: url)
        print("ok: \(plan.packageID.rawValue)@\(plan.version) format=\(plan.sourceFormat.rawValue)")
        print("digest: \(plan.digest ?? "n/a")")
        print("parity: \(plan.parityProfile)")
        if let keyringPath = flag(rest, "--keyring") {
            var policy = ExtensionTrustPolicy.strict
            policy.apply(keyring: try PublisherKeyring.load(from: URL(fileURLWithPath: keyringPath)))
            let trust = try ExtensionPackageVerifier.verify(packageRoot: url, policy: policy)
            print("trust: \(trust.rawValue)")
        }
        for d in plan.diagnostics {
            let path = d.path.map { " (\($0))" } ?? ""
            print("\(d.severity.rawValue): [\(d.code)] \(d.message)\(path)")
        }
        if plan.hasErrors { exit(1) }
    }

    static func digest(path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        print(try ExtensionPackageDigest.compute(packageRoot: url))
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
        let reportURL = reportPath.map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("MIGRATION-REPORT.md")
        try result.report.write(to: reportURL, atomically: true, encoding: .utf8)
        let tel = StoreTelemetrySink(fileURL: root.appendingPathComponent(".codeeditor/telemetry.ndjson"))
        tel.append(StoreTelemetryEvent(
            event: "migration.json_to_toml",
            packageID: result.packageID.rawValue,
            success: true,
            todos: result.todos.count
        ))
        print("migrated \(result.packageID.rawValue) → extension.toml")
        print("parity: \(result.plan.parityProfile)")
        print("digest: \(result.plan.digest ?? "n/a")")
        for todo in result.todos {
            print("todo: \(todo)")
        }
    }

    static func genKey(args: [String]) throws {
        guard let out = flag(args, "--out") else { fail("gen-key requires --out") }
        let keyID = flag(args, "--key-id") ?? UUID().uuidString
        let kp = try ExtensionPackageSigner.generateKeyPair(keyID: keyID)
        try ExtensionPackageSigner.writeKeyPair(kp, to: URL(fileURLWithPath: out, isDirectory: true))
        print("key_id: \(kp.keyID)")
        print("wrote keys to \(out)")
    }

    static func sign(args: [String]) throws {
        guard let dir = flag(args, "--dir"),
              let keyPath = flag(args, "--private-key"),
              let keyID = flag(args, "--key-id"),
              let subject = flag(args, "--subject")
        else { fail("sign requires --dir --private-key --key-id --subject") }
        let privateKey = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        try ExtensionPackageSigner.sign(
            packageRoot: URL(fileURLWithPath: dir, isDirectory: true),
            privateKeyRaw: privateKey,
            keyID: keyID,
            subject: subject
        )
        print("signed \(dir)")
    }

    static func verify(args: [String]) throws {
        guard let dir = flag(args, "--dir") else { fail("verify requires --dir") }
        var policy = ExtensionTrustPolicy.strict
        if let kr = flag(args, "--keyring") {
            policy.apply(keyring: try PublisherKeyring.load(from: URL(fileURLWithPath: kr)))
        } else {
            // CLI local verify of self-signed packages for authoring
            policy.allowUnknownSelfSigned = true
        }
        let report = try ExtensionPackageVerifier.verifyDetailed(
            packageRoot: URL(fileURLWithPath: dir, isDirectory: true),
            policy: policy
        )
        print("trust: \(report.trustClass.rawValue)")
        if let p = report.publisher { print("publisher: \(p)") }
        if let k = report.keyID { print("key_id: \(k)") }
    }

    static func sbom(args: [String]) throws {
        guard let dir = flag(args, "--dir") else { fail("sbom requires --dir") }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let plan = try ExtensionPackageLoader.load(directory: root, options: .init(computeDigest: false))
        let out = flag(args, "--out").map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("sbom.spdx.json")
        let doc = try PackageSBOM.generate(packageRoot: root, plan: plan)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(doc).write(to: out, options: .atomic)
        print("sbom: \(out.path) files=\(doc.files.count)")
    }

    static func packageCmd(args: [String]) throws {
        guard let dir = flag(args, "--dir") else { fail("package requires --dir") }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let plan = try ExtensionPackageLoader.load(directory: root, options: .init(computeDigest: false))
        _ = try ExtensionPackageSigner.writeChecksums(packageRoot: root)
        _ = try PackageSBOM.write(packageRoot: root, plan: plan)
        print("packaged \(plan.packageID.rawValue)@\(plan.version)")
    }

    static func installRoot(from args: [String]) -> URL {
        guard let p = flag(args, "--install-root") else { fail("requires --install-root") }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func install(args: [String]) async throws {
        guard let dir = flag(args, "--dir") else { fail("install requires --dir") }
        let root = installRoot(from: args)
        let manager = ExtensionPackageManager(
            installRoot: root,
            verifier: HostPackageVerifier(policy: .testing)
        )
        await manager.bootstrap()
        let plan = try await manager.install(from: URL(fileURLWithPath: dir, isDirectory: true))
        print("installed \(plan.packageID.rawValue)@\(plan.version)")
    }

    static func update(args: [String]) async throws {
        guard let id = flag(args, "--id"), let dir = flag(args, "--dir") else {
            fail("update requires --id --dir")
        }
        let root = installRoot(from: args)
        let manager = ExtensionPackageManager(
            installRoot: root,
            verifier: HostPackageVerifier(policy: .testing)
        )
        await manager.bootstrap()
        try await manager.update(id: ExtensionID(rawValue: id), from: URL(fileURLWithPath: dir, isDirectory: true))
        print("updated \(id)")
    }

    static func rollback(args: [String]) async throws {
        guard let id = flag(args, "--id") else { fail("rollback requires --id") }
        let root = installRoot(from: args)
        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()
        try await manager.rollback(id: ExtensionID(rawValue: id))
        print("rolled back \(id)")
    }

    static func list(args: [String]) async throws {
        let root = installRoot(from: args)
        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()
        for pkg in await manager.installedPackages() {
            let q = pkg.quarantined ? " quarantined" : ""
            print("\(pkg.plan.packageID.rawValue)@\(pkg.currentVersion) enabled=\(pkg.enabled)\(q)")
        }
    }

    static func recover(args: [String]) async throws {
        let root = installRoot(from: args)
        let manager = ExtensionPackageManager(installRoot: root)
        await manager.bootstrap()
        await manager.recoverCorruptedState()
        print("recovered \(root.path)")
    }

    static func revokeCheck(args: [String]) throws {
        guard let dir = flag(args, "--dir"), let rev = flag(args, "--revocation") else {
            fail("revoke-check requires --dir --revocation")
        }
        let plan = try ExtensionPackageLoader.load(
            directory: URL(fileURLWithPath: dir, isDirectory: true),
            options: .init(computeDigest: false)
        )
        let list = try JSONDecoder().decode(
            RevocationListDocument.self,
            from: Data(contentsOf: URL(fileURLWithPath: rev))
        )
        for entry in list.entries where entry.matches(packageID: plan.packageID.rawValue, version: plan.version.description) {
            print("REVOKED: \(entry.reason)")
            exit(1)
        }
        print("ok: not revoked")
    }
}
