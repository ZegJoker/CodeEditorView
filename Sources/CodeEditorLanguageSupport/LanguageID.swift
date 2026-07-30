import Foundation

/// Open language identifier for built-in and host-defined languages.
///
/// Prefer this type for new APIs and custom language packs. Built-in constants
/// mirror ``TreeSitterLanguageID`` raw values for catalog compatibility.
public struct LanguageID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    // MARK: - Built-in constants

    public static let agda = LanguageID(rawValue: "agda")
    public static let bash = LanguageID(rawValue: "bash")
    public static let c = LanguageID(rawValue: "c")
    public static let cpp = LanguageID(rawValue: "cpp")
    public static let cSharp = LanguageID(rawValue: "cSharp")
    public static let css = LanguageID(rawValue: "css")
    public static let dart = LanguageID(rawValue: "dart")
    public static let dockerfile = LanguageID(rawValue: "dockerfile")
    public static let elixir = LanguageID(rawValue: "elixir")
    public static let go = LanguageID(rawValue: "go")
    public static let goMod = LanguageID(rawValue: "goMod")
    public static let haskell = LanguageID(rawValue: "haskell")
    public static let html = LanguageID(rawValue: "html")
    public static let java = LanguageID(rawValue: "java")
    public static let javascript = LanguageID(rawValue: "javascript")
    public static let jsdoc = LanguageID(rawValue: "jsdoc")
    public static let json = LanguageID(rawValue: "json")
    public static let jsx = LanguageID(rawValue: "jsx")
    public static let julia = LanguageID(rawValue: "julia")
    public static let kotlin = LanguageID(rawValue: "kotlin")
    public static let lua = LanguageID(rawValue: "lua")
    public static let markdown = LanguageID(rawValue: "markdown")
    public static let markdownInline = LanguageID(rawValue: "markdownInline")
    public static let objc = LanguageID(rawValue: "objc")
    public static let ocaml = LanguageID(rawValue: "ocaml")
    public static let perl = LanguageID(rawValue: "perl")
    public static let php = LanguageID(rawValue: "php")
    public static let python = LanguageID(rawValue: "python")
    public static let regex = LanguageID(rawValue: "regex")
    public static let ruby = LanguageID(rawValue: "ruby")
    public static let rust = LanguageID(rawValue: "rust")
    public static let scala = LanguageID(rawValue: "scala")
    public static let sql = LanguageID(rawValue: "sql")
    public static let swift = LanguageID(rawValue: "swift")
    public static let toml = LanguageID(rawValue: "toml")
    public static let tsx = LanguageID(rawValue: "tsx")
    public static let typescript = LanguageID(rawValue: "typescript")
    public static let verilog = LanguageID(rawValue: "verilog")
    public static let yaml = LanguageID(rawValue: "yaml")
    public static let zig = LanguageID(rawValue: "zig")
    public static let plainText = LanguageID(rawValue: "plainText")
}
