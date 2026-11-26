#if os(macOS)
import AppKit
import WebKit

/// Pictures a note shows in place of its source: formulas (KaTeX, bundled), mermaid diagrams (bundled mermaid) and
/// drawings. Made one at a time in a hidden web view, kept while the app runs; a note asks again for what isn't made
/// yet and is told (`ready`) when something new is.
@MainActor
final class NoteRenders: NSObject, WKNavigationDelegate {
    static let shared = NoteRenders()
    /// Posted when a picture asked for is ready (notes showing draw again).
    static let ready = Notification.Name("asmo.note.renderReady")

    private var images: [String: NSImage] = [:]
    private var failed: [String: String] = [:]
    private var queued: [(key: String, job: () async throws -> NSImage)] = []
    private var working = false
    private var announce: DispatchWorkItem?

    /// A formula: "x^2" written as $x^2$ (inline) or between $$ (display), in the ink's colour.
    func math(_ source: String, display: Bool, color: NSColor) -> NSImage? {
        let hex = color.usingColorSpace(.sRGB).map { String(format: "#%02X%02X%02X", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#000000"
        let key = "math|\(display)|\(hex)|\(source)"
        return image(key) { [unowned self] in try await self.drawMath(source, display: display, color: hex) }
    }

    /// A mermaid diagram (```mermaid).
    func mermaid(_ source: String) -> NSImage? {
        image("mermaid|" + source) {
            // Drawn from PDF on white: sharp however far it's zoomed in.
            let pdf = try await DiagramRenderer.shared.pdf(source)
            guard let page = NSPDFImageRep(data: pdf), page.bounds.width > 1 else { throw PageMarkdown.Failure(message: "No picture.") }
            let size = page.bounds.size
            return NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                page.draw(in: rect)
                return true
            }
        }
    }

    /// What went wrong making the picture for `key`'s source, if it couldn't be made.
    func problem(math source: String) -> String? {
        failed.first { $0.key.hasSuffix("|" + source) && $0.key.hasPrefix("math|") }?.value
    }

    func problem(mermaid source: String) -> String? { failed["mermaid|" + source] }

    /// Something made elsewhere (a drawing's preview), kept under its own key.
    func image(_ key: String, make: @escaping () async throws -> NSImage) -> NSImage? {
        if let known = images[key] { return known }
        guard failed[key] == nil, !queued.contains(where: { $0.key == key }) else { return nil }
        queued.append((key, make))
        run()
        return nil
    }

    /// Forgets a picture (its source changed on disk: a drawing saved again).
    func forget(_ key: String) {
        images[key] = nil
        failed[key] = nil
    }

    private func run() {
        guard !working, !queued.isEmpty else { return }
        working = true
        let (key, job) = queued.removeFirst()
        Task { @MainActor in
            do { images[key] = try await job() } catch {
                failed[key] = error.localizedDescription
                #if DEBUG
                let line = "\(Date.now) \(key.prefix(80)): \(error.localizedDescription)\n"
                let log = AppPaths.caches.appendingPathComponent("asmo-renders.txt")
                if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
                else { try? line.write(to: log, atomically: true, encoding: .utf8) }
                #endif
            }
            working = false
            // Several made in a row: the notes draw again once.
            announce?.cancel()
            let work = DispatchWorkItem { NotificationCenter.default.post(name: Self.ready, object: nil) }
            announce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (queued.isEmpty ? 0.02 : 0.4), execute: work)
            run()
        }
    }

    // MARK: Formulas

    private var web: WKWebView?
    private var loaded = false
    private var waiting: [CheckedContinuation<Void, Error>] = []

    private func drawMath(_ source: String, display: Bool, color: String) async throws -> NSImage {
        let web = try await mathPage()
        let answer = try await web.callAsyncJavaScript("return await draw(source, display, color)",
                                                       arguments: ["source": source, "display": display, "color": color],
                                                       in: nil, contentWorld: .page) as? [String: Any]
        guard let answer, answer["ok"] as? Bool == true, let width = answer["width"] as? Double, let height = answer["height"] as? Double,
              width > 0, height > 0 else {
            throw PageMarkdown.Failure(message: (answer?["error"] as? String) ?? "The formula could not be drawn.")
        }
        web.frame = CGRect(x: 0, y: 0, width: max(width + 20, 800), height: max(height + 20, 200))
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
        let pdf = try await web.pdf(configuration: configuration)
        guard let image = NSImage(data: pdf) else { throw PageMarkdown.Failure(message: "The formula could not be drawn.") }
        image.size = NSSize(width: width, height: height)
        return image
    }

    private func mathPage() async throws -> WKWebView {
        if let web, loaded { return web }
        if web == nil {
            guard let file = Bundle.main.url(forResource: "math", withExtension: "html") else {
                throw PageMarkdown.Failure(message: "This build has no formula support.")
            }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 200))
            view.setValue(false, forKey: "drawsBackground")
            view.navigationDelegate = self
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            web = view
        }
        try await withCheckedThrowingContinuation { waiting.append($0) }
        guard let web else { throw PageMarkdown.Failure(message: "This build has no formula support.") }
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        web = nil
        waiting.forEach { $0.resume(throwing: error) }
        waiting = []
    }
}
#endif
