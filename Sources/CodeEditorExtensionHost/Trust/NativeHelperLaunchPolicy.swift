import Foundation
import CodeEditorCore
import CodeEditorExtensionAPI

/// Central native helper launch/install decision (Phase 15 — no soft path).
public enum NativeHelperLaunchPolicy {
    public struct Decision: Sendable, Hashable {
        public var allowed: Bool
        public var reasons: [String]

        public init(allowed: Bool, reasons: [String] = []) {
            self.allowed = allowed
            self.reasons = reasons
        }
    }

    public static func evaluate(
        trustClass: ExtensionTrustClass,
        origin: ExtensionArtifactOrigin,
        policy: ExtensionExecutionPolicy
    ) -> Decision {
        var reasons: [String] = []
        if !policy.platformAllowsNativeProcess {
            reasons.append("platformAllowsNativeProcess=false")
        }
        if !policy.platformProfile.availability(for: .nativeExtensionProcess).isLocallyAvailable {
            reasons.append("nativeExtensionProcess not local on \(policy.platformProfile.name)")
        }
        switch policy.hostProfile.executableExtensionPolicy {
        case .trustedNativeAndWasm:
            break
        case .bundledWasmOnly, .remoteOnly, .dataAndBuiltInOnly:
            reasons.append(
                "executableExtensionPolicy=\(policy.hostProfile.executableExtensionPolicy.rawValue) denies native"
            )
        }
        if origin == .workspaceDev,
           policy.hostProfile.enterpriseOptions?.requireSignedNativeHelpers == true {
            reasons.append("enterprise requires signed native helpers")
        }
        switch trustClass {
        case .trustedSigned:
            break
        case .workspaceDev:
            if !policy.trust.allowWorkspaceDevNative {
                reasons.append("workspaceDev native not allowed by trust policy")
            }
        case .untrusted:
            if !policy.trust.allowUntrustedNative {
                reasons.append("untrusted native not allowed")
            }
        }
        return Decision(allowed: reasons.isEmpty, reasons: reasons)
    }

    public static func evaluateInstall(
        hasNativeExecutable: Bool,
        hasWasm: Bool,
        isDataOnly: Bool,
        origin: ExtensionArtifactOrigin,
        installPolicy: ShippingInstallPolicy
    ) -> Decision {
        var reasons: [String] = []
        switch installPolicy.dynamicInstallation {
        case .disabled:
            reasons.append("dynamicInstallation=disabled")
        case .bundledOnly:
            if origin != .bundled {
                reasons.append("only bundled installs allowed")
            }
        case .dataOnly:
            if hasNativeExecutable || (hasWasm && origin != .bundled) {
                reasons.append("dataOnly install policy rejects executable artifacts")
            }
        case .full:
            break
        }
        if hasNativeExecutable && !installPolicy.allowNativeHelpers {
            reasons.append("native helpers not allowed on \(installPolicy.shippingProfileID.rawValue)")
        }
        if hasWasm && origin != .bundled && !installPolicy.allowDownloadableWasm {
            reasons.append("downloadable Wasm not allowed on \(installPolicy.shippingProfileID.rawValue)")
        }
        if installPolicy.dataOnlyOnly && !isDataOnly && hasNativeExecutable {
            reasons.append("profile is data-only for marketplace packages")
        }
        return Decision(allowed: reasons.isEmpty, reasons: reasons)
    }
}
