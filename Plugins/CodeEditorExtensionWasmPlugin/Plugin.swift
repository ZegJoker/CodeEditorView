import PackagePlugin
import Foundation

/// Build tool plugin: records Wasm repro metadata next to package artifacts when present.
@main
struct CodeEditorExtensionWasmPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let out = context.pluginWorkDirectoryURL.appending(path: "wasm-repro.json")
        let pinURL = context.package.directoryURL
            .appending(path: "Docs/Architecture/WASI-SDK.pin")
        let pin = (try? String(contentsOf: pinURL, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init)
            .first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "unknown"
        let json = """
        {
          "plugin": "CodeEditorExtensionWasmPlugin",
          "swift_sdk_pin": "\(pin)",
          "note": "Run scripts/build-wasm-extension.sh to produce extension.wasm"
        }
        """
        try json.write(to: out, atomically: true, encoding: .utf8)
        print("Wrote \(out.path)")
    }
}
