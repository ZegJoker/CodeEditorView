import SwiftUI
import Foundation
import CodeEditorCore
import CodeEditorDocuments
import CodeEditorCommands
import CodeEditorWorkspace
import CodeEditorView
import CodeEditorLanguageSupport

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct DocumentContentSelector: Sendable, Hashable {
    public var pathExtensions: Set<String>
    public var utTypes: [String]

    public init(pathExtensions: Set<String>, utTypes: [String] = []) {
        self.pathExtensions = Set(pathExtensions.map { $0.lowercased() })
        self.utTypes = utTypes
    }

    public static func extensions(_ ext: String...) -> DocumentContentSelector {
        DocumentContentSelector(pathExtensions: Set(ext))
    }
}

@MainActor
public struct DocumentViewContext {
    public let workspace: Workspace
    public let document: TextDocument
    public let session: EditorSession
    public let paneID: EditorPaneID
    public let tabID: EditorTabID
    public var commandDispatcher: CommandDispatcher?
    public var editorConfiguration: EditorConfiguration
    public var clientRegistry: WorkbenchEditorClientRegistry

    public init(
        workspace: Workspace,
        document: TextDocument,
        session: EditorSession,
        paneID: EditorPaneID,
        tabID: EditorTabID,
        commandDispatcher: CommandDispatcher? = nil,
        editorConfiguration: EditorConfiguration = EditorConfiguration(),
        clientRegistry: WorkbenchEditorClientRegistry
    ) {
        self.workspace = workspace
        self.document = document
        self.session = session
        self.paneID = paneID
        self.tabID = tabID
        self.commandDispatcher = commandDispatcher
        self.editorConfiguration = editorConfiguration
        self.clientRegistry = clientRegistry
    }

    public var pathExtension: String {
        document.uri.fileURL?.pathExtension.lowercased()
            ?? (document.uri.rawValue as NSString).pathExtension.lowercased()
    }
}

@MainActor
public protocol DocumentViewProvider: AnyObject {
    var id: String { get }
    var supportedContentTypes: [DocumentContentSelector] { get }
    var priority: Int { get }
    func makeView(context: DocumentViewContext) -> AnyView
}

@MainActor
public final class DocumentViewRegistry {
    private var providers: [any DocumentViewProvider] = []

    public init() {}

    public func register(_ provider: any DocumentViewProvider) {
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
        providers.sort { $0.priority > $1.priority }
    }

    public func unregister(id: String) {
        providers.removeAll { $0.id == id }
    }

    public func provider(for pathExtension: String) -> (any DocumentViewProvider)? {
        let ext = pathExtension.lowercased()
        return providers.first { provider in
            provider.supportedContentTypes.contains { $0.pathExtensions.contains(ext) }
        }
    }

    public func makeView(context: DocumentViewContext) -> AnyView {
        if let provider = provider(for: context.pathExtension) {
            return provider.makeView(context: context)
        }
        // Fallback text
        return TextDocumentViewProvider().makeView(context: context)
    }

    public func allProviders() -> [any DocumentViewProvider] { providers }
}

// MARK: - Text

@MainActor
public final class TextDocumentViewProvider: DocumentViewProvider {
    public let id = "workbench.document.text"
    public let supportedContentTypes: [DocumentContentSelector] = [
        // Catch-all low priority handled by fallback; declare common source extensions high enough.
        DocumentContentSelector(pathExtensions: [
            "swift", "txt", "md", "json", "yml", "yaml", "xml", "html", "css", "js", "ts",
            "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "java", "kt", "sh",
            "toml", "ini", "cfg", "gradle", "cmake", "makefile", "podspec", "plist",
        ])
    ]
    public let priority: Int = 10

    public init() {}

    public func makeView(context: DocumentViewContext) -> AnyView {
        let ext = context.pathExtension
        let language = CodeLanguages.language(forFileExtension: ext)
        return AnyView(
            TextDocumentEditorHost(
                document: context.document,
                session: context.session,
                tabID: context.tabID,
                workspace: context.workspace,
                configuration: context.editorConfiguration,
                language: language,
                clientRegistry: context.clientRegistry
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

/// Hosts SharedCodeEditor and registers the controller as a command client when available.
@MainActor
struct TextDocumentEditorHost: View {
    let document: TextDocument
    let session: EditorSession
    let tabID: EditorTabID
    let workspace: Workspace
    let configuration: EditorConfiguration
    let language: CodeLanguage?
    let clientRegistry: WorkbenchEditorClientRegistry

    var body: some View {
        SharedCodeEditor(
            document: document,
            session: session,
            configuration: configuration,
            language: language
        )
        // Remount when tab/document/session changes (NSViewRepresentable is sticky otherwise).
        .id("\(tabID.rawValue.uuidString)/\(document.id.rawValue.uuidString)/\(session.id.rawValue.uuidString)")
        .onAppear {
            // Controller is internal to SharedEditorRepresentable; registry is filled via
            // workbench bridge when hosts inject coordinators. Session-level registration
            // uses a lightweight adapter for command context.
            clientRegistry.register(
                sessionID: session.id,
                client: SessionCommandClient(document: document, session: session)
            )
        }
        .onDisappear {
            clientRegistry.unregister(sessionID: session.id)
        }
        // Xcode/VS Code: editing a preview tab promotes it to permanent.
        .task(id: document.id.rawValue) {
            let stream = document.makeEventStream()
            for await event in stream {
                switch event {
                case .didApply, .dirtyStateDidChange(true):
                    workspace.promotePreviewTabs(for: document.id)
                default:
                    break
                }
            }
        }
    }
}

/// Minimal command client backed by document/session when full EditorController is unavailable.
@MainActor
final class SessionCommandClient: EditorCommandClient {
    let document: TextDocument
    let session: EditorSession

    init(document: TextDocument, session: EditorSession) {
        self.document = document
        self.session = session
    }

    var isEditable: Bool { true }
    var isFocused: Bool { true }
    var selections: [CodeEditorCore.TextRange] { session.selections }
    var snapshot: DocumentSnapshot { document.snapshot() }
    var documentID: DocumentID? { document.id }
    var sessionID: EditorSessionID? { session.id }
    var languageID: String? { nil }
    var contextFlags: [String: Bool] { [:] }

    func perform(_ action: EditorCommandAction) throws {
        switch action {
        case .undo: try document.performUndo()
        case .redo: try document.performRedo()
        case .selectAll:
            let len = document.length
            session.selections = [CodeEditorCore.TextRange(location: 0, length: len)]
        default:
            break
        }
    }
}

// MARK: - Image

@MainActor
public final class ImageDocumentViewProvider: DocumentViewProvider {
    public let id = "workbench.document.image"
    public let supportedContentTypes: [DocumentContentSelector] = [
        .extensions("png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp")
    ]
    public let priority: Int = 50

    public init() {}

    public func makeView(context: DocumentViewContext) -> AnyView {
        AnyView(ImageDocumentView(uri: context.document.uri))
    }
}

struct ImageDocumentView: View {
    let uri: DocumentURI

    var body: some View {
        Group {
            if let url = uri.fileURL, let image = platformImage(url: url) {
                image
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else {
                ContentUnavailableView("Unable to load image", systemImage: "photo")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.12))
    }

    @ViewBuilder
    private func platformImage(url: URL) -> Image? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let ns = NSImage(contentsOf: url) {
            return Image(nsImage: ns)
        }
        #elseif canImport(UIKit)
        if let ui = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: ui)
        }
        #endif
        return nil
    }
}

// MARK: - PDF

@MainActor
public final class PDFDocumentViewProvider: DocumentViewProvider {
    public let id = "workbench.document.pdf"
    public let supportedContentTypes: [DocumentContentSelector] = [.extensions("pdf")]
    public let priority: Int = 50

    public init() {}

    public func makeView(context: DocumentViewContext) -> AnyView {
        AnyView(PDFDocumentView(uri: context.document.uri))
    }
}

struct PDFDocumentView: View {
    let uri: DocumentURI

    var body: some View {
        #if canImport(PDFKit)
        if let url = uri.fileURL {
            PDFKitRepresentable(url: url)
        } else {
            ContentUnavailableView("Unable to load PDF", systemImage: "doc.richtext")
        }
        #else
        ContentUnavailableView("PDFKit unavailable", systemImage: "doc.richtext")
        #endif
    }
}

#if canImport(PDFKit)
import PDFKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#elseif canImport(UIKit)
struct PDFKitRepresentable: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#endif
#endif
