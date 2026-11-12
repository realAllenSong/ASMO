import SwiftUI

private struct PlannerPanelClose: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var closePlannerPanel: (() -> Void)? {
        get { self[PlannerPanelClose.self] }
        set { self[PlannerPanelClose.self] = newValue }
    }
}

struct PlannerPanel<Content: View, Footer: View>: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    let close: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @Environment(\.colorScheme) private var scheme

    private var theme: PlannerTheme { PlannerTheme(dark: scheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.localized).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    ASMOIcon(mark: .close, size: 15)
                        .frame(width: 34, height: 34)
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Rectangle().fill(theme.line).frame(height: 1)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .frame(maxHeight: height)
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 8) {
                Spacer()
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: width)
        .background(theme.paper, in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(theme.line) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.33 : 0.12), radius: 22, y: 12)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .accessibilityAddTraits(.isModal)
        .padding(15)
    }
}

struct PlannerActionStyle: ButtonStyle {
    let theme: PlannerTheme
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(primary ? .semibold : .medium))
            .foregroundStyle(primary ? theme.onAccent : theme.ink)
            .padding(.horizontal, 13)
            .frame(minHeight: 36)
            .background(primary ? theme.accent : theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { if !primary { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct PlannerToggle: View {
    let title: String
    @Binding var selected: Bool
    let theme: PlannerTheme
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { selected.toggle() } label: {
            HStack(spacing: 8) {
                ASMOCheckbox(complete: selected, theme: theme)
                Text(title.localized).font(.subheadline.weight(.medium))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .opacity(enabled ? 1 : 0.6)
    }
}
