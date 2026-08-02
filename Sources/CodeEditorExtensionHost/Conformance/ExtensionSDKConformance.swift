import CodeEditorExtensionAPI
import CodeEditorExtensions
import Foundation

/// SDK conformance checklist for data-only and built-in Swift extension packages (EXT-016 / Phase 8 E18).
public enum ExtensionSDKConformance {
    public struct Result: Sendable, Equatable {
        public var checks: [String: Bool]
        public var passed: Bool { checks.values.allSatisfy { $0 } }
        public init(checks: [String: Bool]) { self.checks = checks }
    }

    /// Run structural + load checks against a package directory.
    public static func runDataOnlyPackage(at directory: URL) throws -> Result {
        var checks: [String: Bool] = [:]
        let toml = directory.appendingPathComponent("extension.toml")
        checks["has_extension_toml"] = FileManager.default.fileExists(atPath: toml.path)
        do {
            let plan = try ExtensionPackageLoader.load(directory: directory, options: .init(computeDigest: false))
            checks["loads_plan"] = true
            checks["valid_extension_id"] = (try? ExtensionID(validating: plan.packageID.rawValue)) != nil
            checks["has_version"] = plan.version.major >= 0
            // Data-only packages must not require process by default for conformance baseline.
            let perms = plan.manifest.requestedPermissions
            checks["no_implicit_process"] = !perms.contains(.startProcesses)
        } catch {
            checks["loads_plan"] = false
            checks["valid_extension_id"] = false
            checks["has_version"] = false
            checks["no_implicit_process"] = false
        }
        return Result(checks: checks)
    }

    /// Built-in Swift extension: manifest must declare runtime + valid ID.
    public static func runBuiltInManifest(_ manifest: ExtensionManifest) -> Result {
        var checks: [String: Bool] = [:]
        checks["valid_id"] = (try? ExtensionID(validating: manifest.id.rawValue)) != nil
        checks["has_display_name"] = !manifest.displayName.isEmpty
        checks["has_activation"] = !manifest.activationEvents.isEmpty
        return Result(checks: checks)
    }
}
