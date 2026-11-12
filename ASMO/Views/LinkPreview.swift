#if os(macOS)
import AppKit
#else
import UIKit
#endif
import LinkPresentation
import SwiftUI

/// Finds the first web link in a piece of text.
enum TextLinks {
    static func first(in text: String) -> (url: URL, range: Range<String.Index>)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let url = match.url, url.scheme?.hasPrefix("http") == true,
              let range = Range(match.range, in: text) else { return nil }
        return (url, range)
    }
}

/// A small chip for a link inside an item: click opens it, hovering shows a preview card.
struct LinkChip: View {
    let url: URL
    let theme: PlannerTheme
    @State private var hovering = false
    @State private var showing = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 9.5, weight: .semibold))
                Text(url.host(percentEncoded: false)?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(theme.wash.opacity(hovering ? 0.9 : 0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            // Show the preview after a short rest, so passing over a row doesn't pop cards.
            hoverTask = Task {
                try? await Task.sleep(for: .milliseconds(inside ? 450 : 250))
                if !Task.isCancelled { showing = inside }
            }
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            LinkCard(url: url).frame(width: 300).padding(8)
                .presentationCompactAdaptation(.popover)
        }
    }
}

#if os(macOS)
private typealias LinkRepresentable = NSViewRepresentable
#else
private typealias LinkRepresentable = UIViewRepresentable
#endif

private struct LinkCard: LinkRepresentable {
    let url: URL

    #if os(macOS)
    func makeNSView(context: Context) -> LPLinkView { makeView() }
    func updateNSView(_ view: LPLinkView, context: Context) {}
    #else
    func makeUIView(context: Context) -> LPLinkView { makeView() }
    func updateUIView(_ view: LPLinkView, context: Context) {}
    #endif

    private func makeView() -> LPLinkView {
        let view = LPLinkView(url: url)
        let provider = LPMetadataProvider()
        provider.timeout = 6
        provider.startFetchingMetadata(for: url) { metadata, _ in
            guard let metadata else { return }
            DispatchQueue.main.async { view.metadata = metadata }
        }
        return view
    }
}

extension Text {
    /// Applies a stored title style: "b" bold, "i" italic, "u" underline, "s" strike, "#RRGGBB" color.
    func titleStyle(_ style: String?) -> Text {
        guard let style else { return self }
        var text = self
        for part in style.split(separator: " ") {
            switch part {
            case "b": text = text.bold()
            case "i": text = text.italic()
            case "u": text = text.underline()
            case "s": text = text.strikethrough()
            default:
                if part.hasPrefix("#"), part.count == 7, let value = Int(part.dropFirst(), radix: 16) {
                    text = text.foregroundColor(Color(red: Double((value >> 16) & 0xFF) / 255,
                                                      green: Double((value >> 8) & 0xFF) / 255,
                                                      blue: Double(value & 0xFF) / 255))
                }
            }
        }
        return text
    }
}
