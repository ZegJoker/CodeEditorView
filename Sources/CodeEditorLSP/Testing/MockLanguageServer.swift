import Foundation

/// Scriptable in-process language server for tests.
public actor MockLanguageServer {
    private let transport: LSPTestTransport
    private let decoder = LSPMessageFraming.Decoder()
    private var readerTask: Task<Void, Never>?
    private var openText: [String: String] = [:]
    private var changeLog: [(uri: String, version: Int)] = []

    public private(set) var initializeCount = 0
    public private(set) var openCount = 0
    public private(set) var changeCount = 0
    public private(set) var closeCount = 0

    /// When true, publish a warning diagnostic on didOpen/didChange.
    public var publishDiagnosticsOnChange = true
    /// Artificial delay for completion responses (stale-version tests).
    public var completionDelayNanoseconds: UInt64 = 0

    public init(transport: LSPTestTransport) {
        self.transport = transport
    }

    public var recordedChanges: [(uri: String, version: Int)] {
        changeLog
    }

    public func start() {
        guard readerTask == nil else { return }
        let stream = transport.inbound
        readerTask = Task {
            for await chunk in stream {
                await self.handleChunk(chunk)
            }
        }
    }

    public func stop() async {
        readerTask?.cancel()
        readerTask = nil
        await transport.close()
    }

    private func handleChunk(_ chunk: Data) async {
        let messages = decoder.append(chunk)
        for body in messages {
            await handleMessage(body)
        }
    }

    private func handleMessage(_ body: Data) async {
        guard
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = obj["method"] as? String
        else { return }

        let id = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            initializeCount += 1
            if let id {
                await respond(id: id, result: [
                    "capabilities": [
                        "textDocumentSync": [
                            "openClose": true,
                            "change": 2,
                            "save": ["includeText": true],
                        ] as [String: Any],
                        "completionProvider": ["triggerCharacters": ["."]],
                        "hoverProvider": true,
                        "definitionProvider": true,
                        "documentFormattingProvider": true,
                        "renameProvider": true,
                        "documentSymbolProvider": true,
                        "semanticTokensProvider": [
                            "legend": [
                                "tokenTypes": ["function", "keyword"],
                                "tokenModifiers": [],
                            ],
                            "full": true,
                        ] as [String: Any],
                    ] as [String: Any],
                    "serverInfo": ["name": "MockLanguageServer", "version": "1.0"],
                ])
            }
        case "initialized", "exit":
            break
        case "shutdown":
            if let id {
                await respond(id: id, result: NSNull())
            }
        case "textDocument/didOpen":
            openCount += 1
            if let doc = params["textDocument"] as? [String: Any],
               let uri = doc["uri"] as? String,
               let text = doc["text"] as? String
            {
                openText[uri] = text
                if publishDiagnosticsOnChange {
                    await publishDiagnostics(uri: uri, version: doc["version"] as? Int, text: text)
                }
            }
        case "textDocument/didChange":
            changeCount += 1
            if let doc = params["textDocument"] as? [String: Any],
               let uri = doc["uri"] as? String,
               let version = doc["version"] as? Int
            {
                changeLog.append((uri, version))
                if let changes = params["contentChanges"] as? [[String: Any]],
                   let last = changes.last,
                   let text = last["text"] as? String,
                   last["range"] == nil
                {
                    openText[uri] = text
                }
                if publishDiagnosticsOnChange {
                    await publishDiagnostics(uri: uri, version: version, text: openText[uri] ?? "")
                }
            }
        case "textDocument/didClose":
            closeCount += 1
            if let doc = params["textDocument"] as? [String: Any],
               let uri = doc["uri"] as? String
            {
                openText[uri] = nil
            }
        case "textDocument/didSave":
            break
        case "textDocument/completion":
            if completionDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: completionDelayNanoseconds)
            }
            if let id {
                await respond(id: id, result: [
                    "isIncomplete": false,
                    "items": [
                        [
                            "label": "mockComplete",
                            "kind": 3,
                            "detail": "Mock",
                            "insertText": "mockComplete()",
                            "textEdit": [
                                "range": [
                                    "start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 0],
                                ],
                                "newText": "mockComplete()",
                            ] as [String: Any],
                        ] as [String: Any],
                    ],
                ] as [String: Any])
            }
        case "textDocument/hover":
            if let id {
                await respond(id: id, result: [
                    "contents": ["kind": "markdown", "value": "**mock** hover"],
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 4],
                    ],
                ] as [String: Any])
            }
        case "textDocument/definition":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(id: id, result: [
                    "uri": uri,
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 4],
                    ],
                ] as [String: Any])
            }
        case "textDocument/formatting":
            if let id {
                await respond(id: id, result: [
                    [
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 0],
                        ],
                        "newText": "// formatted\n",
                    ] as [String: Any],
                ])
            }
        case "textDocument/rename":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                let newName = params["newName"] as? String ?? "renamed"
                await respond(id: id, result: [
                    "changes": [
                        uri: [
                            [
                                "range": [
                                    "start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 4],
                                ],
                                "newText": newName,
                            ] as [String: Any],
                        ],
                    ] as [String: Any],
                ])
            }
        case "textDocument/documentSymbol":
            if let id {
                await respond(id: id, result: [
                    [
                        "name": "mockSymbol",
                        "kind": 12,
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 10],
                        ],
                        "selectionRange": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 10],
                        ],
                    ] as [String: Any],
                ])
            }
        case "textDocument/semanticTokens/full":
            if let id {
                // one token: line 0, char 0, length 4, type 0, mods 0
                await respond(id: id, result: [
                    "data": [0, 0, 4, 0, 0],
                ] as [String: Any])
            }
        default:
            if let id {
                await respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func publishDiagnostics(uri: String, version: Int?, text: String) async {
        _ = text
        var params: [String: Any] = [
            "uri": uri,
            "diagnostics": [
                [
                    "range": [
                        "start": ["line": 0, "character": 0],
                        "end": ["line": 0, "character": 1],
                    ],
                    "severity": 2,
                    "source": "mock",
                    "message": "mock warning",
                    "code": "M001",
                ] as [String: Any],
            ],
        ]
        if let version {
            params["version"] = version
        }
        await notify(method: "textDocument/publishDiagnostics", params: params)
    }

    private func respond(id: Any, result: Any) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await transport.send(LSPMessageFraming.encode(body))
    }

    private func respondError(id: Any, code: Int, message: String) async {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? await transport.send(LSPMessageFraming.encode(body))
    }

    private func notify(method: String, params: [String: Any]) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await transport.send(LSPMessageFraming.encode(body))
    }
}
