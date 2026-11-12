#if os(iOS)
import SwiftUI
import UIKit

/// The iPhone's page: plain free writing in a native text view. Same role as the Mac's PageController
/// (it holds what is being written so the planner can take lines out and file them), without rich text.
@MainActor
final class PageController: ObservableObject {
    @Published var text = ""
    @Published var recording = false
    @Published var isEditing = false
    /// Bumped to ask the editor to take or give up focus.
    @Published var focusRequest = 0
    @Published var wantsFocus = false
    /// A page written on the Mac with formatting, tables or pictures, shown read-only: the phone can't keep those,
    /// so what is written here is added after it instead of replacing it.
    @Published var keptPage: String?
    /// The page as stored when it was opened (to save nothing when nothing changed).
    private(set) var opened: Data?

    var isEmpty: Bool { text.trimmed.isEmpty }

    /// Opens a day's page.
    func load(_ data: Data?) {
        opened = data
        if let data, Self.isRich(data) {
            keptPage = Self.decode(data)
            text = ""
        } else {
            keptPage = nil
            text = Self.decode(data)
        }
    }

    /// What to store for the page now; nil when it should stay exactly as it was.
    func toStore() -> (data: Data?, changed: Bool) {
        if keptPage != nil {
            guard !text.trimmed.isEmpty, let opened,
                  let page = try? NSMutableAttributedString(data: opened, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                            documentAttributes: nil) else { return (opened, false) }
            let attributes = page.length > 0 ? page.attributes(at: page.length - 1, effectiveRange: nil).filter { $0.key == .font || $0.key == .foregroundColor } : [:]
            page.append(NSAttributedString(string: (page.string.hasSuffix("\n") ? "" : "\n") + text, attributes: attributes))
            return (try? page.data(from: NSRange(location: 0, length: page.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]), true)
        }
        guard text != Self.decode(opened) else { return (opened, false) }
        return (Self.encode(text), true)
    }

    /// Anything a plain text view would lose: pictures, tables, links, bold, italic, strikethrough, highlight.
    static func isRich(_ data: Data) -> Bool {
        if let raw = String(data: data, encoding: .isoLatin1), raw.contains("\\trowd") || raw.contains("\\itap") { return true }
        guard let page = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                                 documentAttributes: nil) else { return false }
        if page.string.contains("\u{FFFC}") { return true }
        var rich = false
        page.enumerateAttributes(in: NSRange(location: 0, length: page.length)) { attributes, _, stop in
            if attributes[.attachment] != nil || attributes[.link] != nil || attributes[.strikethroughStyle] != nil
                || attributes[.backgroundColor] != nil { rich = true }
            if let font = attributes[.font] as? UIFont,
               font.fontDescriptor.symbolicTraits.contains(.traitBold) || font.fontDescriptor.symbolicTraits.contains(.traitItalic) || font.pointSize > 16 {
                rich = true
            }
            if rich { stop.pointee = true }
        }
        return rich
    }

    /// The page as stored data (nil when empty), in the same RTFD form the Mac writes.
    func encoded() -> Data? { Self.encode(text) }

    static func encode(_ text: String) -> Data? {
        guard !text.trimmed.isEmpty else { return nil }
        let value = NSAttributedString(string: text)
        return try? value.data(from: NSRange(location: 0, length: value.length),
                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    static func decode(_ data: Data?) -> String {
        guard let data else { return "" }
        if let value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                               documentAttributes: nil) {
            return value.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func insert(_ value: String) {
        if !text.isEmpty && !text.hasSuffix("\n") && !value.hasPrefix("\n") { text += "\n" }
        text += value
    }

    func appendLine(_ value: String) {
        let prefix = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += prefix + value + "\n"
    }

    func focus() { wantsFocus = true; focusRequest += 1 }
    func resignFocus() { wantsFocus = false; focusRequest += 1 }

    struct Candidate {
        var text: String
        var level: Int
        var style: String? = nil
    }

    /// Lines that could be things to do (long paragraphs and quotes stay as notes).
    func candidates() -> [Candidate] {
        text.components(separatedBy: "\n").compactMap { raw in
            let indent = raw.prefix { $0 == "\t" || $0 == " " || $0 == "\u{3000}" }
            var body = String(raw.dropFirst(indent.count))
            guard !body.trimmed.isEmpty, body.count <= 80 else { return nil }
            for marker in ["• ", "- ", "☐ ", "☑ "] where body.hasPrefix(marker) { body = String(body.dropFirst(marker.count)); break }
            return Candidate(text: body, level: indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
        }
    }

    func remove(_ lines: [Candidate]) {
        var rest = text.components(separatedBy: "\n")
        for line in lines {
            if let index = rest.firstIndex(where: { $0.contains(line.text) }) { rest.remove(at: index) }
        }
        text = rest.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if !text.isEmpty { text += "\n" }
    }
}
#endif

#if os(iOS)
/// The writing area: a native text view that grows with its text, on the page's paper.
struct PhonePageEditor: View {
    @ObservedObject var controller: PageController
    let theme: PlannerTheme
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let kept = controller.keptPage {
                Text(kept)
                    .font(.system(size: 17))
                    .lineSpacing(5)
                    .foregroundStyle(theme.ink.opacity(0.85))
                    .textSelection(.enabled)
                    .padding(.horizontal, 5)
                Text("这一页有格式、表格或图片，请在 Mac 上修改。在下面写的内容会加到页面末尾。")
                    .font(.footnote).foregroundStyle(theme.quiet)
                    .padding(.horizontal, 5)
            }
            editor
        }
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if controller.text.isEmpty {
                Text(controller.keptPage == nil ? placeholder : String(localized: "接着写…"))
                    .font(.system(size: 17))
                    .foregroundStyle(theme.quiet.opacity(0.75))
                    .padding(.top, 8).padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextField("", text: $controller.text, axis: .vertical)
                .font(.system(size: 17))
                .lineSpacing(5)
                .foregroundStyle(theme.ink)
                .tint(theme.accent)
                .focused($focused)
                .padding(.vertical, 8).padding(.horizontal, 5)
                .accessibilityIdentifier("pageText")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: controller.focusRequest) { _, _ in focused = controller.wantsFocus }
        .onChange(of: focused) { _, value in controller.isEditing = value }
        .onAppear { if controller.wantsFocus { focused = true } }
    }
}
#endif

#if os(iOS) && DEBUG
/// Debug builds on iPhone: the same background test files as the Mac, in the app's Caches folder
/// (`xcrun simctl get_app_container <device> com.realallensong.asmo data`/Library/Caches).
enum PhoneDebugHooks {
    @MainActor
    static func watch() async {
        let folder = AppPaths.caches
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(400))
            for (name, notification) in [("asmo-type.txt", Notification.Name.asmoDebugType), ("asmo-nav.txt", .asmoDebugNav)] {
                let file = folder.appendingPathComponent(name)
                if let text = try? String(contentsOf: file, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: file)
                    NotificationCenter.default.post(name: notification, object: text)
                }
            }
            let voice = folder.appendingPathComponent("asmo-voice-test.aiff")
            if FileManager.default.fileExists(atPath: voice.path) {
                let moved = folder.appendingPathComponent("asmo-voice-running.aiff")
                try? FileManager.default.removeItem(at: moved)
                try? FileManager.default.moveItem(at: voice, to: moved)
                let started = Date.now
                let result: String
                do { result = try await VoiceCapture.transcribe(file: moved, locale: Locale(identifier: "zh-Hans-CN")) }
                catch { result = "ERROR: \(error.localizedDescription)" }
                let line = String(format: "%.2fs\t", Date.now.timeIntervalSince(started)) + result
                try? line.write(to: folder.appendingPathComponent("asmo-voice-test.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
