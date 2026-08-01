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
    /// When true, issue a workspace/applyEdit server request after initialize.
    public var requestApplyEditAfterInit = false
    /// When true, send $/progress after initialize.
    public var sendProgressAfterInit = false
    /// Track cancelled request IDs.
    public private(set) var cancelledIDs: [Any] = []
    public private(set) var receivedMethods: [String] = []

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

        receivedMethods.append(method)
        switch method {
        case "initialize":
            initializeCount += 1
            if let id {
                await respond(
                    id: id,
                    result: [
                        "capabilities": [
                            "textDocumentSync": [
                                "openClose": true,
                                "change": 2,
                                "save": ["includeText": true],
                            ] as [String: Any],
                            "completionProvider": ["triggerCharacters": ["."], "resolveProvider": true],
                            "hoverProvider": true,
                            "definitionProvider": true,
                            "declarationProvider": true,
                            "implementationProvider": true,
                            "referencesProvider": true,
                            "documentFormattingProvider": true,
                            "documentRangeFormattingProvider": true,
                            "renameProvider": true,
                            "documentSymbolProvider": true,
                            "workspaceSymbolProvider": true,
                            "codeActionProvider": ["resolveProvider": true],
                            "signatureHelpProvider": ["triggerCharacters": ["(", ","]],
                            "inlayHintProvider": true,
                            "foldingRangeProvider": true,
                            "documentLinkProvider": true,
                            "colorProvider": true,
                            "documentHighlightProvider": true,
                            "typeHierarchyProvider": true,
                            "callHierarchyProvider": true,
                            "executeCommandProvider": ["commands": ["mock.cmd"]],
                            "diagnosticProvider": ["interFileDependencies": false, "workspaceDiagnostics": false],
                            "semanticTokensProvider": [
                                "legend": [
                                    "tokenTypes": ["function", "keyword"],
                                    "tokenModifiers": [],
                                ],
                                "full": ["delta": true],
                                "range": true,
                            ] as [String: Any],
                            "workspace": [
                                "workspaceFolders": ["supported": true]
                            ],
                        ] as [String: Any],
                        "serverInfo": ["name": "MockLanguageServer", "version": "1.0"],
                    ])
            }
        case "initialized":
            if sendProgressAfterInit {
                await notify(
                    method: "$/progress",
                    params: [
                        "token": "t1",
                        "value": ["kind": "begin", "title": "Indexing", "percentage": 0],
                    ])
                await notify(
                    method: "$/progress",
                    params: [
                        "token": "t1",
                        "value": ["kind": "end"],
                    ])
            }
            if requestApplyEditAfterInit {
                await request(
                    id: "server-apply-1",
                    method: "workspace/applyEdit",
                    params: [
                        "edit": [
                            "changes": [
                                "inmemory:x": [
                                    [
                                        "range": [
                                            "start": ["line": 0, "character": 0],
                                            "end": ["line": 0, "character": 0],
                                        ],
                                        "newText": "// applied\n",
                                    ] as [String: Any]
                                ]
                            ] as [String: Any]
                        ] as [String: Any]
                    ]
                )
            }
        case "exit":
            break
        case "shutdown":
            if let id {
                await respond(id: id, result: NSNull())
            }
        case "$/cancelRequest":
            if let cancelID = params["id"] {
                cancelledIDs.append(cancelID)
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
                await respond(
                    id: id,
                    result: [
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
                            ] as [String: Any]
                        ],
                    ] as [String: Any])
            }
        case "textDocument/hover":
            if let id {
                await respond(
                    id: id,
                    result: [
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
                await respond(
                    id: id,
                    result: [
                        "uri": uri,
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 4],
                        ],
                    ] as [String: Any])
            }
        case "textDocument/formatting":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 0],
                            ],
                            "newText": "// formatted\n",
                        ] as [String: Any]
                    ])
            }
        case "textDocument/rename":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                let newName = params["newName"] as? String ?? "renamed"
                await respond(
                    id: id,
                    result: [
                        "changes": [
                            uri: [
                                [
                                    "range": [
                                        "start": ["line": 0, "character": 0],
                                        "end": ["line": 0, "character": 4],
                                    ],
                                    "newText": newName,
                                ] as [String: Any]
                            ]
                        ] as [String: Any]
                    ])
            }
        case "textDocument/documentSymbol":
            if let id {
                await respond(
                    id: id,
                    result: [
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
                        ] as [String: Any]
                    ])
            }
        case "textDocument/semanticTokens/full", "textDocument/semanticTokens/range":
            if let id {
                // one token: line 0, char 0, length 4, type 0, mods 0
                await respond(
                    id: id,
                    result: [
                        "data": [0, 0, 4, 0, 0]
                    ] as [String: Any])
            }
        case "textDocument/declaration", "textDocument/implementation":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(
                    id: id,
                    result: [
                        "uri": uri,
                        "range": [
                            "start": ["line": 0, "character": 0],
                            "end": ["line": 0, "character": 4],
                        ],
                    ] as [String: Any])
            }
        case "textDocument/references":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(
                    id: id,
                    result: [
                        [
                            "uri": uri,
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 4],
                            ],
                        ] as [String: Any]
                    ])
            }
        case "textDocument/documentHighlight":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 4],
                            ],
                            "kind": 2,
                        ] as [String: Any]
                    ])
            }
        case "textDocument/rangeFormatting":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 0],
                            ],
                            "newText": "// range\n",
                        ] as [String: Any]
                    ])
            }
        case "textDocument/codeAction":
            if let id {
                await respond(
                    id: id,
                    result: [
                        ["title": "Mock fix", "kind": "quickfix", "isPreferred": true] as [String: Any]
                    ])
            }
        case "textDocument/signatureHelp":
            if let id {
                await respond(
                    id: id,
                    result: [
                        "signatures": [
                            [
                                "label": "mock(x: Int)",
                                "parameters": [["label": "x: Int"]],
                            ] as [String: Any]
                        ],
                        "activeSignature": 0,
                        "activeParameter": 0,
                    ] as [String: Any])
            }
        case "textDocument/inlayHint":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "position": ["line": 0, "character": 4],
                            "label": ": Int",
                            "kind": 1,
                        ] as [String: Any]
                    ])
            }
        case "textDocument/foldingRange":
            if let id {
                await respond(
                    id: id,
                    result: [
                        ["startLine": 0, "endLine": 2, "kind": "region"] as [String: Any]
                    ])
            }
        case "textDocument/documentLink":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(
                    id: id,
                    result: [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 4],
                            ],
                            "target": uri,
                        ] as [String: Any]
                    ])
            }
        case "textDocument/documentColor":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 7],
                            ],
                            "color": ["red": 1.0, "green": 0.0, "blue": 0.0, "alpha": 1.0],
                        ] as [String: Any]
                    ])
            }
        case "textDocument/prepareTypeHierarchy":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(
                    id: id,
                    result: [
                        [
                            "name": "MockType",
                            "kind": 5,
                            "uri": uri,
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 8],
                            ],
                            "selectionRange": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 8],
                            ],
                        ] as [String: Any]
                    ])
            }
        case "textDocument/prepareCallHierarchy":
            if let id {
                let uri = (params["textDocument"] as? [String: Any])?["uri"] as? String ?? "inmemory:x"
                await respond(
                    id: id,
                    result: [
                        [
                            "name": "mockFn",
                            "kind": 12,
                            "uri": uri,
                            "range": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 6],
                            ],
                            "selectionRange": [
                                "start": ["line": 0, "character": 0],
                                "end": ["line": 0, "character": 6],
                            ],
                        ] as [String: Any]
                    ])
            }
        case "textDocument/diagnostic":
            if let id {
                await respond(
                    id: id,
                    result: [
                        "kind": "full",
                        "resultId": "1",
                        "items": [
                            [
                                "range": [
                                    "start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 1],
                                ],
                                "severity": 2,
                                "message": "pull mock",
                                "source": "mock",
                            ] as [String: Any]
                        ],
                    ] as [String: Any])
            }
        case "workspace/symbol":
            if let id {
                await respond(
                    id: id,
                    result: [
                        [
                            "name": "mockWS",
                            "kind": 12,
                            "location": [
                                "uri": "inmemory:x",
                                "range": [
                                    "start": ["line": 0, "character": 0],
                                    "end": ["line": 0, "character": 4],
                                ],
                            ] as [String: Any],
                        ] as [String: Any]
                    ])
            }
        case "workspace/executeCommand":
            if let id {
                await respond(id: id, result: ["ok": true])
            }
        case "client/registerCapability":
            // echoed by client as response; mock may request registration
            if let id {
                await respond(id: id, result: NSNull())
            }
        default:
            if let id {
                await respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    /// Issues a server→client request.
    public func request(id: Any, method: String, params: [String: Any]) async {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? await transport.send(LSPMessageFraming.encode(body))
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
                ] as [String: Any]
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
