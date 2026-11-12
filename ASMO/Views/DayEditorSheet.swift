import SwiftUI

/// Writing a day: a centered page over the calendar, like opening a doc. Esc, ✕ or a click outside closes it,
/// and what was written is organized onto the calendar.
struct DayEditorSheet<Toolbar: View, Content: View>: View {
    let organizing: Bool
    let theme: PlannerTheme
    let close: () -> Void
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(theme.dark ? 0.45 : 0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityLabel("关闭")
                VStack(spacing: 0) {
                    // Just the tools: the day is the one that was opened (open another day from the calendar).
                    ZStack {
                        toolbar().fixedSize()
                        HStack { Spacer(); closeButton }
                    }
                    .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                    ZStack(alignment: .top) {
                        Rectangle().fill(theme.line.opacity(0.6)).frame(height: 1)
                        if organizing {
                            ProgressView().progressViewStyle(.linear).tint(theme.accent).frame(height: 2)
                        }
                    }
                    .frame(height: 2)
                    ScrollView {
                        content()
                            .padding(.horizontal, 30).padding(.top, 14).padding(.bottom, 60)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: min(920, proxy.size.width - 80), height: min(1000, proxy.size.height * 0.9))
                // The shadow is on the page's shape only: on the whole page it re-rendered the text offscreen
                // (a ~60 ms hitch when a day opened).
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.field)
                        .shadow(color: .black.opacity(theme.dark ? 0.5 : 0.18), radius: 30, y: 12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.line) }
                .animation(.smooth(duration: 0.2), value: organizing)
            }
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.quiet)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("完成 · Esc")
        .accessibilityLabel("完成")
    }
}
