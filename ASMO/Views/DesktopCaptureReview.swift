import SwiftUI

struct DesktopCaptureReview: View {
    @State var drafts: [CaptureDraft]
    let source: String
    let theme: PlannerTheme
    let close: () -> Void
    let save: ([CaptureDraft]) -> Void

    var body: some View {
        PlannerPanel(title: String(localized: "检查录入结果"), width: 480, height: 360, close: close) {
            VStack(alignment: .leading, spacing: 11) {
                Text(source).font(.subheadline).foregroundStyle(theme.quiet).textSelection(.enabled)
                ForEach($drafts) { $draft in
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("事项", text: $draft.title)
                            .modifier(PlannerFieldStyle(theme: theme))
                        HStack(spacing: 7) {
                            Text(draft.schedule?.label ?? "未安排")
                            if draft.requiresReview {
                                Text("继续后确认日期或提醒").foregroundStyle(theme.accent)
                            } else {
                                Button("调整") { draft.requiresReview = true }
                                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                                    .accessibilityLabel("调整 \(draft.title) 的日期或提醒")
                            }
                        }
                        .font(.caption).foregroundStyle(theme.quiet)
                    }
                }
            }
        } footer: {
            Button("返回原文", action: close).buttonStyle(PlannerActionStyle(theme: theme))
            Button("继续", action: { save(drafts) })
                .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
                .disabled(drafts.isEmpty || drafts.contains { $0.title.trimmed.isEmpty })
        }
    }
}
