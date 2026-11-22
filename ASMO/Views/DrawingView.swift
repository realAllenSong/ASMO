#if os(macOS)
import AppKit
import SwiftUI
import WebKit

private var drawingPage: URL? {
    Bundle.main.url(forResource: "Excalidraw", withExtension: "bundle")?.appendingPathComponent("drawing.html")
}

/// A drawing (an Obsidian ".excalidraw.md"), drawn in Excalidraw, which ships inside the app: every change is saved
/// to the file in the plugin's own layout, so Obsidian on the phone opens the same drawing.
struct DrawingView: NSViewRepresentable {
    let url: URL
    let dark: Bool
    let library: NotesLibrary

    func makeCoordinator() -> Coordinator { Coordinator(url: url, library: library) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "asmo")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.dark = dark
        if let page = drawingPage { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        library.noteOpened(url)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.url != url || coordinator.dark != dark {
            coordinator.flush()
            coordinator.url = url
            coordinator.dark = dark
            coordinator.show()
            library.noteOpened(url)
        }
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.flush()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "asmo")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var url: URL
        var dark = false
        let library: NotesLibrary
        weak var web: WKWebView?
        private var loaded = false

        init(url: URL, library: NotesLibrary) {
            self.url = url
            self.library = library
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            show()
            webView.window?.makeFirstResponder(webView)
        }

        /// Opens the file's drawing in the editor.
        func show() {
            guard loaded, let web else { return }
            let text = library.read(url) ?? ""
            let drawing = ExcalidrawFile.drawing(in: text) ?? ExcalidrawFile.Drawing(data: "", compressed: true)
            web.callAsyncJavaScript("open(data, compressed, dark)", arguments: ["data": drawing.data, "compressed": drawing.compressed, "dark": dark],
                                    in: nil, in: .page, completionHandler: nil)
        }

        /// Saves what's drawn now (leaving the drawing).
        func flush() {
            web?.evaluateJavaScript("flush()", completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["type"] as? String == "changed", let data = body["data"] as? String else { return }
            let texts = (body["texts"] as? [[String: Any]] ?? []).compactMap { item -> (id: String, text: String)? in
                guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
                return (id, text)
            }
            let file = url
            let written = ExcalidrawFile.updated(library.read(file) ?? "", data: data, texts: texts)
            try? library.write(written, to: file)
            DrawingPreviews.changed(file)
        }
    }
}

/// The drawing on the page, with its name and a way back to the note it was opened from.
struct DrawingScreen: View {
    let url: URL
    let theme: PlannerTheme
    @ObservedObject var library: NotesLibrary
    let back: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let back {
                    Button(action: back) {
                        Label("返回笔记", systemImage: "chevron.left").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.quiet)
                            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme))
                }
                Text(NotesLibrary.title(of: url)).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.ink)
                Text((library.path(of: url) as NSString).deletingLastPathComponent).font(.system(size: 12)).foregroundStyle(theme.quiet)
                Spacer()
                Text("画板 · 自动保存，Obsidian 也能打开").font(.system(size: 11.5)).foregroundStyle(theme.quiet)
            }
            .padding(.horizontal, 18).frame(height: 44)
            Rectangle().fill(theme.line.opacity(0.6)).frame(height: 1)
            DrawingView(url: url, dark: theme.dark, library: library)
        }
    }
}

/// Pictures of drawings, for showing them inside notes (made in a hidden Excalidraw, kept until the file changes).
@MainActor
enum DrawingPreviews {
    private static var web: WKWebView?
    private static var loader: Loader?
    private static var waiting: [CheckedContinuation<Void, Never>] = []
    private static var loaded = false

    static func key(_ file: URL) -> String {
        "drawing|\(file.path)|\(NotesLibrary.shared.modifiedDate(file).timeIntervalSince1970)"
    }

    static func preview(_ file: URL) -> NSImage? {
        NoteRenders.shared.image(key(file)) { try await render(file) }
    }

    static func changed(_ file: URL) {
        // A new key (the file's date changed): made again when next shown.
        NotificationCenter.default.post(name: NoteRenders.ready, object: nil)
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                DrawingPreviews.loaded = true
                DrawingPreviews.waiting.forEach { $0.resume() }
                DrawingPreviews.waiting = []
            }
        }
    }

    private static func page() async -> WKWebView? {
        if let web, loaded { return web }
        if web == nil {
            guard let page = drawingPage else { return nil }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = Loader()
            loader = delegate
            view.navigationDelegate = delegate
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            web = view
        }
        await withCheckedContinuation { waiting.append($0) }
        return web
    }

    private static func render(_ file: URL) async throws -> NSImage {
        guard let text = NotesLibrary.shared.read(file), let drawing = ExcalidrawFile.drawing(in: text),
              !drawing.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PageMarkdown.Failure(message: "An empty drawing.")
        }
        guard let web = await page() else { throw PageMarkdown.Failure(message: "This build has no drawing support.") }
        let answer = try await web.callAsyncJavaScript("return await preview(data, compressed)",
                                                       arguments: ["data": drawing.data, "compressed": drawing.compressed],
                                                       in: nil, contentWorld: .page) as? [String: Any]
        guard let base64 = answer?["png"] as? String, let data = Data(base64Encoded: base64), let image = NSImage(data: data),
              let rep = image.representations.first else {
            throw PageMarkdown.Failure(message: (answer?["error"] as? String) ?? "The drawing could not be shown.")
        }
        image.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        return image
    }
}
#endif
