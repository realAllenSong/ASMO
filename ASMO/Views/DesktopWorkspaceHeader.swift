import SwiftUI

struct DesktopWorkspaceHeader: View {
    /// 0 逐日 (a day opens as its own page), 1 日历.
    let current: Int
    let theme: PlannerTheme
    let select: (Int) -> Void
    /// The 逐日 / 日历 switch (Mac has only the calendar: a day is written in its popup).
    var tabs = true
    let today: () -> Void
    let settings: () -> Void
    @Namespace private var selection
    #if os(iOS)
    static let compact = true
    #else
    static let compact = false
    #endif

    var body: some View {
        ZStack {
            HStack {
                Image("BrandMark").resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 24)
                    .accessibilityHidden(true)
                Spacer()
                Button(action: settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.quiet)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .accessibilityLabel("设置")
                .help("设置")
            }

            if tabs {
            HStack(spacing: 2) {
                segment(String(localized: "逐日"), mark: .sun, index: 0)
                segment(String(localized: "日历"), mark: .calendar, index: 1)
            }
            .padding(3)
            .background(theme.surface, in: Capsule())
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: current)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("视图")
            }
        }
        .padding(.horizontal, Self.compact ? 14 : 22)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1).allowsHitTesting(false) }
    }

    private func segment(_ title: String, mark: ASMOIcon.Mark, index: Int) -> some View {
        let active = current == index
        return Button { select(index) } label: {
            HStack(spacing: 5) {
                ASMOIcon(mark: mark, size: 14)
                Text(title.localized).font(.system(size: Self.compact ? 14 : 12, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? theme.accent : theme.quiet)
            .padding(.horizontal, Self.compact ? 15 : 13)
            .frame(height: Self.compact ? 34 : 27)
            .background {
                if active {
                    Capsule().fill(theme.paper)
                        .shadow(color: .black.opacity(theme.dark ? 0.15 : 0.07), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "active-view", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier(["workspace-journal", "workspace-calendar"][index])
    }
}

struct DesktopTaskMotion {
    let namespace: Namespace.ID

    func label<Label: View>(_ label: Label, id: String) -> some View {
        label.matchedGeometryEffect(id: id, in: namespace, properties: .position, anchor: .leading)
    }
}
