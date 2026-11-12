import SwiftUI

#if !os(macOS)
struct PlannerColumns: Layout {
    private let splitWidth: CGFloat = 610
    private let spacing: CGFloat = 29
    private let firstShare: CGFloat = 0.60

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 950
        let widths = columnWidths(width)
        let left = subviews[0].sizeThatFits(.init(width: widths.0, height: nil))
        let right = subviews[1].sizeThatFits(.init(width: widths.1, height: nil))
        return CGSize(width: width, height: width < splitWidth ? left.height + 22 + right.height : max(left.height, right.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width)
        let left = ProposedViewSize(width: widths.0, height: nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: left)
        let isStacked = bounds.width < splitWidth
        let origin = isStacked ?
            CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(left).height + 22) :
            CGPoint(x: bounds.minX + widths.0 + spacing, y: bounds.minY)
        subviews[1].place(at: origin, anchor: .topLeading, proposal: .init(width: widths.1, height: nil))
    }

    private func columnWidths(_ width: CGFloat) -> (CGFloat, CGFloat) {
        guard width >= splitWidth else { return (width, width) }
        let available = width - spacing
        return (available * firstShare, available * (1 - firstShare))
    }
}
#endif

struct ASMOIcon: View {
    enum Mark {
        case left, right, down, plus, close, more, mic, stop, calendar, check, square, arrow, pointer
        case sun, tray, archive, spark, sliders
    }

    let mark: Mark
    var size: CGFloat = 17

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 24
            let path = drawing.applying(CGAffineTransform(scaleX: scale, y: scale))
            if mark == .stop || mark == .more { context.fill(path, with: .foreground) }
            else { context.stroke(path, with: .foreground,
                                  style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round, lineJoin: .round)) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var drawing: Path {
        var path = Path()
        func stroke(_ points: [(CGFloat, CGFloat)]) {
            guard let start = points.first else { return }
            path.move(to: CGPoint(x: start.0, y: start.1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        switch mark {
        case .left: stroke([(15, 5), (8, 12), (15, 19)])
        case .right: stroke([(9, 5), (16, 12), (9, 19)])
        case .down: stroke([(5, 9), (12, 16), (19, 9)])
        case .plus: stroke([(12, 5), (12, 19)]); stroke([(5, 12), (19, 12)])
        case .close: stroke([(6, 6), (18, 18)]); stroke([(6, 18), (18, 6)])
        case .check: stroke([(5.5, 12.5), (9.5, 16.5), (18.5, 7.5)])
        case .arrow: stroke([(12, 19), (12, 5)]); stroke([(7, 10), (12, 5), (17, 10)])
        case .more:
            for x in [5, 12, 19] { path.addEllipse(in: CGRect(x: x - 1, y: 11, width: 2, height: 2)) }
        case .stop:
            path.addRoundedRect(in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerSize: CGSize(width: 3, height: 3))
        case .square:
            path.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 5, height: 5))
        case .calendar:
            path.addRoundedRect(in: CGRect(x: 3.5, y: 5.5, width: 17, height: 15), cornerSize: CGSize(width: 3, height: 3))
            stroke([(3.5, 10.5), (20.5, 10.5)])
            stroke([(8, 3.5), (8, 7.5)]); stroke([(16, 3.5), (16, 7.5)])
            stroke([(8, 15.5), (10, 15.5)]); stroke([(14, 15.5), (16, 15.5)])
        case .mic:
            path.addRoundedRect(in: CGRect(x: 9, y: 2.5, width: 6, height: 12), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 5.5, y: 11.5))
            path.addQuadCurve(to: CGPoint(x: 12, y: 18), control: CGPoint(x: 5.5, y: 18))
            path.addQuadCurve(to: CGPoint(x: 18.5, y: 11.5), control: CGPoint(x: 18.5, y: 18))
            stroke([(12, 18), (12, 21)]); stroke([(9, 21), (15, 21)])
        case .sun:
            path.addEllipse(in: CGRect(x: 8, y: 8, width: 8, height: 8))
            stroke([(12, 2), (12, 4)]); stroke([(12, 20), (12, 22)])
            stroke([(2, 12), (4, 12)]); stroke([(20, 12), (22, 12)])
            stroke([(5, 5), (6.5, 6.5)]); stroke([(17.5, 17.5), (19, 19)])
            stroke([(5, 19), (6.5, 17.5)]); stroke([(17.5, 6.5), (19, 5)])
        case .tray:
            stroke([(3, 13), (6, 5), (18, 5), (21, 13), (21, 19), (3, 19), (3, 13),
                    (8, 13), (9.5, 15.5), (14.5, 15.5), (16, 13), (21, 13)])
        case .archive:
            path.addRoundedRect(in: CGRect(x: 3, y: 4.5, width: 18, height: 5), cornerSize: CGSize(width: 1.5, height: 1.5))
            stroke([(5, 10), (5, 19), (19, 19), (19, 10)]); stroke([(10, 13.5), (14, 13.5)])
        case .spark:
            stroke([(12, 3), (14.3, 9.7), (21, 12), (14.3, 14.3), (12, 21),
                    (9.7, 14.3), (3, 12), (9.7, 9.7), (12, 3)])
        case .sliders:
            stroke([(4, 7), (7, 7)]); stroke([(12, 7), (20, 7)])
            stroke([(4, 17), (12, 17)]); stroke([(17, 17), (20, 17)])
            path.addEllipse(in: CGRect(x: 7, y: 4.5, width: 5, height: 5))
            path.addEllipse(in: CGRect(x: 12, y: 14.5, width: 5, height: 5))
        case .pointer:
            path.addEllipse(in: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
            stroke([(9, 15), (14.5, 9), (13, 14), (9, 15)])
        }
        return path
    }
}

struct ASMOCheckbox: View {
    let complete: Bool
    let theme: PlannerTheme

    var body: some View {
        #if os(macOS)
        let size: CGFloat = 17
        let radius: CGFloat = 5
        #else
        let size: CGFloat = 20
        let radius: CGFloat = 6
        #endif
        RoundedRectangle(cornerRadius: radius)
            .fill(complete ? theme.accent : .clear)
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(complete ? theme.accent : theme.quiet.opacity(0.7)) }
            .overlay {
                if complete {
                    ASMOIcon(mark: .check, size: 15).foregroundStyle(theme.onAccent)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(width: size, height: size)
            // Checking gives a small press-and-spring, so finishing something feels like something.
            .keyframeAnimator(initialValue: 1.0, trigger: complete) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(0.8, duration: 0.09)
                SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: complete)
    }
}

struct PlannerFieldStyle: ViewModifier {
    let theme: PlannerTheme

    func body(content: Content) -> some View {
        content.textFieldStyle(.plain)
            .padding(10)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line) }
    }
}


struct DesktopButtonStyle: ButtonStyle {
    let theme: PlannerTheme
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        DesktopButtonSurface(label: configuration.label, theme: theme, selected: selected,
                             pressed: configuration.isPressed)
    }

    private struct DesktopButtonSurface<Label: View>: View {
        let label: Label
        let theme: PlannerTheme
        let selected: Bool
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            label
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovered = $0 }
        }

        private var background: Color {
            if selected { return theme.wash.opacity(pressed ? 0.68 : 1) }
            if enabled && (pressed || hovered) { return theme.quiet.opacity(pressed ? 0.14 : 0.08) }
            return .clear
        }
    }
}

struct DesktopDateField: View {
    @Binding var date: Date
    let theme: PlannerTheme
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                ASMOIcon(mark: .calendar, size: 16).foregroundStyle(theme.quiet)
                Text(date.formatted(.dateTime.year().month(.defaultDigits).day()
                    .locale(Locale(identifier: "zh_CN"))))
                    .monospacedDigit()
                Spacer(minLength: 16)
                ASMOIcon(mark: .down, size: 12).foregroundStyle(theme.quiet)
            }
            .padding(.horizontal, 10).frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line).allowsHitTesting(false) }
        .accessibilityLabel("日期")
        .accessibilityValue(date.formatted(date: .long, time: .omitted))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DesktopCalendarPicker(date: $date, theme: theme)
                .padding(14).frame(width: 304)
                .onChange(of: date) { _, _ in showing = false }
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct DesktopCalendarPicker: View {
    @Binding var date: Date
    let theme: PlannerTheme
    var openTypedDate: ((Date) -> Void)? = nil
    @State private var typed = ""
    @State private var invalid = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("年-月-日", text: $typed, prompt: Text("YYYY-MM-DD").foregroundStyle(theme.quiet))
                    .font(.subheadline.monospacedDigit())
                    .modifier(PlannerFieldStyle(theme: theme))
                    .onChange(of: typed) { _, _ in invalid = false }
                    .onSubmit(apply)
                Button(openTypedDate == nil ? "设为" : "跳转", action: apply)
                    .buttonStyle(PlannerActionStyle(theme: theme))
                    .disabled(typed.trimmed.isEmpty)
            }
            if invalid {
                Text("请输入有效日期，例如 2027-03-12。")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            DatePicker(String(localized: "选择日期"), selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .tint(theme.accent)
    }

    private func apply() {
        let fields = typed.trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, let year = Int(fields[0]), (1...9999).contains(year),
              let month = Int(fields[1]), let day = Int(fields[2]),
              let chosen = PlanDate(year: year, month: month, day: day).date(in: CaptureClock().calendar) else {
            invalid = true
            return
        }
        invalid = false
        typed = ""
        if let openTypedDate { openTypedDate(chosen) }
        else { date = chosen }
    }
}
