/// Fixture entry for real sourcekit-lsp integration (LSP-N13).
public func greet(_ name: String) -> String {
    return "hello, \(name)"
}

let message = greet("world")
print(message)
