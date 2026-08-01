import CodeEditorCore
import CodeEditorDocuments
import CodeEditorExtensions
import CodeEditorLanguageServices
import Foundation

/// Peer-side server for out-of-process (or mock) extensions.
public actor RemoteExtensionServer {
    private let ext: any CodeEditorExtension
    private let transport: any RemoteExtensionTransport
    private var connection: ExtensionRPCConnection?
    private var activated = false
    /// Optional delay for timeout tests.
    public var completionDelayNanoseconds: UInt64 = 0
    public var completionItems: [CompletionItem]
    public var oversizedResponse: Bool = false

    public init(
        extension ext: any CodeEditorExtension,
        transport: any RemoteExtensionTransport,
        completionItems: [CompletionItem] = [
            CompletionItem(label: "remoteHello", kind: .function, insertText: "remoteHello()")
        ]
    ) {
        self.ext = ext
        self.transport = transport
        self.completionItems = completionItems
    }

    public func setCompletionDelayNanoseconds(_ value: UInt64) {
        completionDelayNanoseconds = value
    }

    public func setOversizedResponse(_ value: Bool) {
        oversizedResponse = value
    }

    public func run() async {
        let connection = ExtensionRPCConnection(transport: transport)
        self.connection = connection
        await connection.start()
        await connection.setEnvelopeHandler { [weak self] envelope in
            await self?.handle(envelope)
        }
        // Initiate handshake
        let handshake = ExtensionRPCHandshake(
            protocolVersion: .current,
            extensionManifest: ext.manifest,
            processID: ProcessInfo.processInfo.processIdentifier
        )
        try? await connection.send(.handshake(handshake))
    }

    public func stop() async {
        await connection?.close()
        connection = nil
    }

    private func handle(_ envelope: ExtensionRPCEnvelope) async {
        switch envelope {
        case .handshakeResult(let result):
            if !result.accepted {
                await connection?.close()
            }
        case .request(let req):
            await handleRequest(req)
        case .cancel:
            break
        default:
            break
        }
    }

    private func handleRequest(_ req: ExtensionRPCRequest) async {
        guard let connection else { return }
        do {
            let data: Data
            switch req.method {
            case .ping:
                data = Data(#"{"ok":true}"#.utf8)
            case .activate:
                activated = true
                data = Data()
            case .deactivate:
                activated = false
                data = Data()
            case .completion:
                if completionDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: completionDelayNanoseconds)
                }
                if oversizedResponse {
                    // Force host limit failure by returning huge payload
                    data = Data(repeating: 0x41, count: 5 * 1024 * 1024)
                } else {
                    let list = CompletionList(items: completionItems)
                    data = try ExtensionRPCCodec.encodePayload(list)
                }
            case .hover:
                let hover = Hover(sections: [HoverSection(content: .markdown("**remote** hover"))])
                data = try ExtensionRPCCodec.encodePayload(hover)
            case .definition:
                let uri = DocumentURI(rawValue: "inmemory:remote")
                let range = CodeEditorCore.TextRange(location: 0, length: 1)
                let links = [
                    LocationLink(targetURI: uri, targetRange: range, targetSelectionRange: range)
                ]
                data = try ExtensionRPCCodec.encodePayload(links)
            case .diagnostics:
                data = try ExtensionRPCCodec.encodePayload([LanguageDiagnostic]())
            }
            try await connection.send(.response(ExtensionRPCResponse(id: req.id, result: data)))
        } catch {
            try? await connection.send(
                .response(
                    ExtensionRPCResponse(
                        id: req.id,
                        error: ExtensionRPCErrorPayload(code: -32000, message: String(describing: error))
                    )
                )
            )
        }
    }
}

// CompletionList etc. already Codable in LanguageServices
