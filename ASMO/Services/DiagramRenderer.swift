#if os(macOS)
import AppKit
import WebKit

/// Draws mermaid diagrams with the copy of mermaid that ships in the app (no network, no model): a hidden web
/// view lays the diagram out, and the result becomes a picture on the page.
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRenderer()

    private var web: WKWebView?
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Error>] = []

    /// A PNG of the diagram, with its source kept inside. Throws mermaid's own message when the source is wrong.
    func render(_ source: String) async throws -> Data {
        let web = try await page()
        let answer = try await web.callAsyncJavaScript("return await draw(source)", arguments: ["source": source],
                                                       in: nil, contentWorld: .page) as? [String: Any]
        guard let answer, answer["ok"] as? Bool == true, let width = answer["width"] as? Double, let height = answer["height"] as? Double,
              width > 1, height > 1 else {
            let reason = (answer?["error"] as? String ?? "it could not be drawn").components(separatedBy: "\n").prefix(4).joined(separator: " ")
            throw PageMarkdown.Failure(message: "The mermaid diagram has a mistake: \(reason)")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        web.frame = CGRect(x: 0, y: 0, width: max(width, 700), height: max(height, 400))
        let configuration = WKPDFConfiguration()
        configuration.rect = rect
        let pdf = try await web.pdf(configuration: configuration)
        guard let png = PageMarkdown.diagram(pdf: pdf, source: source) else {
            throw PageMarkdown.Failure(message: "The mermaid diagram could not be turned into a picture.")
        }
        return png
    }

    private func page() async throws -> WKWebView {
        if let web, ready { return web }
        if web == nil {
            guard let file = Bundle.main.url(forResource: "diagram", withExtension: "html") else {
                throw PageMarkdown.Failure(message: "This build has no diagram support.")
            }
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 400))
            view.navigationDelegate = self
            view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            web = view
        }
        try await withCheckedThrowingContinuation { waiting.append($0) }
        guard let web else { throw PageMarkdown.Failure(message: "This build has no diagram support.") }
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
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
