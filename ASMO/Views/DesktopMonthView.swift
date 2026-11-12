import SwiftUI

struct CalendarDayItem: Identifiable {
    enum Kind { case occasion, event, task, archive, note }

    let id: String
    let title: String
    var detail: String? = nil
    let kind: Kind
    var startMinute: Int? = nil
    var completed = false
    var toggle: (() -> Void)? = nil
    var timeEdit: TimelineTimeEdit? = nil
    var open: (() -> Void)? = nil
    var openHint: String? = nil
    var dragID: String? = nil
    var delete: (() -> Void)? = nil

    var sortGroup: Int {
        switch kind {
        case .occasion: 0
        case .event, .task: startMinute == nil ? 2 : 1
        case .note: 3
        case .archive: 4
        }
    }

    var previewTitle: String {
        kind == .archive || kind == .note ? detail ?? title : title
    }

    var icon: ASMOIcon.Mark {
        switch kind {
        case .occasion: .spark
        case .event: .calendar
        case .task: .check
        case .archive: .archive
        case .note: .tray
        }
    }
}

struct DesktopMonthView: View {
    let month: CalendarMonth
    let cursor: PlanDate
    let selected: PlanDate
    let today: PlanDate
    let items: [PlanDate: [CalendarDayItem]]
    let monthPlans: [CalendarDayItem]
    let theme: PlannerTheme
    let motion: DesktopTaskMotion?
    @Binding var detailDay: PlanDate?
    @Binding var dropDay: PlanDate?
    let select: (PlanDate) -> Void
    let shift: (Int) -> Void
    let drop: ([String], PlanDate) -> Bool
    let jump: () -> Void
    let openDay: (PlanDate) -> Void
    let add: (String, PlanDate) throws -> Void
    /// Mac has no top bar: settings sit at the end of the month's row.
    var settings: (() -> Void)? = nil
    var logo = false
    @State private var showingMonthPlans = false
    @State private var lastClick: (day: PlanDate, at: Date)?
    #if os(macOS)
    private static var doubleClick: TimeInterval { NSEvent.doubleClickInterval }
    #else
    private static let doubleClick: TimeInterval = 0.35
    #endif

    /// Line size follows the cell width: wide windows get larger, easier lines (like Google/Apple Calendar).
    @State private var lineFont: CGFloat = 10.5
    private var rowPitch: CGFloat { lineFont + 5.5 }
    private let cellTop: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if logo {
                    Image("BrandMark").resizable().interpolation(.high).scaledToFit()
                        .frame(width: 28, height: 26)
                        .padding(.trailing, 8)
                        .accessibilityHidden(true)
                }
                Button(action: jump) {
                    HStack(spacing: 7) {
                        Text(AppLanguage.monthTitle(year: cursor.year, month: cursor.month))
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        ASMOIcon(mark: .down, size: 11).foregroundStyle(theme.quiet)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(DesktopButtonStyle(theme: theme))
                .help("跳到月份")
                .accessibilityAddTraits(.isHeader)
                #if os(macOS)
                // The month's arrows sit right by its name (纸面).
                monthArrow(.left, String(localized: "上个月"), offset: -1)
                monthArrow(.right, String(localized: "下个月"), offset: 1)
                #endif
                if !monthPlans.isEmpty { monthPlansButton }
                Spacer()
                #if os(iOS)
                monthArrow(.left, String(localized: "上个月"), offset: -1)
                monthArrow(.right, String(localized: "下个月"), offset: 1)
                #endif
                if let settings {
                    Button(action: settings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.quiet)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme))
                    .help("设置")
                    .accessibilityLabel("设置")
                    .padding(.leading, 4)
                }
            }
            .padding(.bottom, 6)

            HStack(spacing: 0) {
                ForEach(month.weekdays, id: \.self) { label in
                    Text(AppLanguage.weekday(["日": 1, "一": 2, "二": 3, "三": 4, "四": 5, "五": 6, "六": 7][label] ?? 1, short: Self.compact))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.quiet)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 7)

            #if os(iOS)
            compactGrid
            #else
            GeometryReader { proxy in
                let rowCount = month.days.count / 7
                let height = proxy.size.height / CGFloat(max(1, rowCount))
                let font: CGFloat = proxy.size.width / 7 > 165 ? 12 : proxy.size.width / 7 > 130 ? 11 : 10.5
                let capacity = max(1, Int((height - cellTop - 4) / (font + 5.5)))
                VStack(spacing: 0) {
                    ForEach(0..<rowCount, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(month.days[(row * 7)..<((row + 1) * 7)], id: \.self) { day in
                                cell(day, items: items[day] ?? [], capacity: capacity)
                            }
                        }
                        .frame(height: height)
                    }
                }
                .background(theme.dark ? theme.field.opacity(0.28) : Color.clear)
                .clipShape(.rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line).allowsHitTesting(false) }
                .onAppear { lineFont = font }
                .onChange(of: font) { _, value in lineFont = value }
            }
            #endif
        }
        .padding(.horizontal, Self.compact ? 14 : 20)
        .padding(.top, Self.compact ? 6 : 8)
        .padding(.bottom, Self.compact ? 74 : 70)
    }

    #if os(iOS)
    static let compact = true

    /// Phone: like Apple Calendar's detailed month — tall cells that fill the screen, each listing its items
    /// as small tinted lines. Tap a day to open it in 逐日; swipe sideways for other months.
    private var compactGrid: some View {
        GeometryReader { proxy in
            let rowCount = max(1, month.days.count / 7)
            let height = proxy.size.height / CGFloat(rowCount)
            let capacity = max(1, Int((height - 26) / 16))
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(month.days[(row * 7)..<((row + 1) * 7)], id: \.self) { day in
                            compactCell(day, items: items[day] ?? [], capacity: capacity)
                        }
                    }
                    .frame(height: height)
                    .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
                }
            }
        }
        .contentShape(Rectangle())
        // A thumb moves through months either way: up or left for the next one, down or right for the last.
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            let x = value.translation.width, y = value.translation.height
            if abs(x) > abs(y) * 1.3, abs(x) > 40 { shift(x < 0 ? 1 : -1) }
            else if abs(y) > abs(x) * 1.3, abs(y) > 50 { shift(y < 0 ? 1 : -1) }
        })
    }

    private func compactCell(_ date: PlanDate, items: [CalendarDayItem], capacity: Int) -> some View {
        let inMonth = date.month == cursor.month && date.year == cursor.year
        let isToday = date == today
        let visible = items.prefix(items.count > capacity ? max(0, capacity - 1) : capacity)
        return VStack(alignment: .center, spacing: 1) {
            Text(date.day.map(String.init) ?? "")
                .font(.system(size: 12, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? theme.onAccent : inMonth ? theme.ink : theme.quiet.opacity(0.55))
                .frame(width: 22, height: 20)
                .background { if isToday { Circle().fill(theme.accent) } }
                .padding(.top, 3).padding(.bottom, 1)
            ForEach(visible) { item in
                let band = item.kind == .occasion || item.kind == .event || item.startMinute != nil
                Text(item.previewTitle)
                    .font(.system(size: 10.5, weight: band ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(item.completed)
                    .foregroundStyle(item.completed ? theme.quiet : band ? theme.accent : theme.ink.opacity(0.85))
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading)
                    .background(band && !item.completed ? theme.block : .clear, in: RoundedRectangle(cornerRadius: 2.5))
            }
            if items.count > visible.count {
                Text("+\(items.count - visible.count)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.quiet)
                    .frame(maxWidth: .infinity, minHeight: 15, alignment: .leading).padding(.horizontal, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(inMonth ? Color.clear : theme.surface.opacity(0.35))
        .contentShape(Rectangle())
        .onTapGesture { select(date); openDay(date) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(date.label + (items.isEmpty ? "" : "，" + items.map(\.title).joined(separator: "，")))
        .accessibilityIdentifier("calendar-day-" + date.key)
    }
    #else
    static let compact = false
    #endif

    private var monthPlansButton: some View {
        Button { showingMonthPlans.toggle() } label: {
            Text("\(monthPlans.count) 项月计划")
                .font(.caption.weight(.medium)).foregroundStyle(theme.quiet)
                .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .popover(isPresented: $showingMonthPlans, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("本月 · 日期待定").font(.headline)
                ForEach(monthPlans) { item in
                    Button {
                        showingMonthPlans = false
                        item.open?()
                    } label: {
                        Text(item.title).strikethrough(item.completed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(DesktopButtonStyle(theme: theme))
                }
            }
            .padding(15).frame(width: 270)
            .background(theme.paper)
        }
    }

    private func monthArrow(_ mark: ASMOIcon.Mark, _ label: String, offset: Int) -> some View {
        Button { shift(offset) } label: {
            ASMOIcon(mark: mark, size: 15).foregroundStyle(theme.quiet)
                .frame(width: 31, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(DesktopButtonStyle(theme: theme))
        .accessibilityLabel(label.localized)
        .help(label.localized)
    }

    private func cell(_ date: PlanDate, items: [CalendarDayItem], capacity: Int) -> some View {
        let active = date == selected
        let inMonth = date.month == cursor.month && date.year == cursor.year
        let isToday = date == today
        // When it doesn't all fit, the last line says how many more (it opens the day's list).
        let visible = items.prefix(items.count > capacity ? max(0, capacity - 1) : capacity)
        let detail = Binding(get: { detailDay == date }, set: { value in
            if value { detailDay = date }
            else if detailDay == date { detailDay = nil }
        })
        let targeted = dropDay == date
        // A plain view rather than a Button, so the items inside can be picked up and dragged to another day.
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                let number = Text(date.day.map(String.init) ?? "")
                    .font(.system(size: 12, weight: active || isToday ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? theme.accent : inMonth ? theme.ink : theme.quiet)
                    .frame(minWidth: 22, minHeight: 21)
                    .background(isToday ? theme.wash : .clear, in: Capsule())
                if let motion { motion.label(number, id: "day-" + date.key) } else { number }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 3)
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                previewLine(item, moving: true)
                    .plannerDraggable(item.dragID, title: item.title, theme: theme)
            }
            if items.count > visible.count {
                Text("还有 \(items.count - visible.count) 项")
                    .font(.system(size: lineFont - 0.5, weight: .medium))
                    .foregroundStyle(theme.quiet)
                    .padding(.horizontal, 4)
                    .frame(height: rowPitch - 1)
            }
        }
        .padding(.horizontal, 5).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .modifier(CalendarCellSurface(theme: theme, active: active, inMonth: inMonth, targeted: targeted))
        // A click shows the day's schedule at once; a second click on the same day (a double-click) writes it.
        // (A separate double-tap gesture made every single click wait out the double-click interval.)
        .onTapGesture {
            let now = Date.now
            if let last = lastClick, last.day == date, now.timeIntervalSince(last.at) < Self.doubleClick {
                lastClick = nil
                detailDay = nil
                openDay(date)
            } else {
                lastClick = (date, now)
                select(date)
                detailDay = date
            }
        }
        .plannerDayDrop(date, target: $dropDay, perform: drop)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1).allowsHitTesting(false) }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select(date); detailDay = date }
        .accessibilityAction(named: String(localized: "写这一天")) { select(date); openDay(date) }
        .accessibilityLabel(date.label + (items.isEmpty ? "" : "，" + items.map(\.title).joined(separator: "，")))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier("calendar-day-" + date.key)
        .popover(isPresented: detail, arrowEdge: .bottom) {
            DesktopCalendarDayPopover(date: date, items: items, theme: theme, close: { detailDay = nil },
                                      openDay: { detailDay = nil; openDay(date) }, add: { try add($0, date) })
        }
    }

    private func previewLine(_ item: CalendarDayItem, moving: Bool) -> some View {
        let band = item.kind == .occasion || item.kind == .event
        let color = item.kind == .occasion ? theme.accent : item.completed || item.kind == .archive || item.kind == .note
            ? theme.quiet : theme.ink
        let title = Text(item.previewTitle)
            .font(.system(size: lineFont, weight: band ? .medium : .regular))
            .strikethrough(item.completed)
            .foregroundStyle(color)
            .lineLimit(1)
        // 纸面: a thin violet tick, then the time in small monospace violet, then the title in ink.
        return HStack(spacing: 5) {
            Capsule()
                .fill(item.completed ? theme.quiet.opacity(0.35) : theme.accent.opacity(band ? 0.9 : 0.55))
                .frame(width: 2, height: max(8, rowPitch - 7))
            if let minute = item.startMinute {
                Text(PlannerClockTime.label(minute))
                    .font(.system(size: lineFont - 1, weight: .medium, design: .monospaced))
                    .foregroundStyle(item.completed ? theme.quiet : theme.accent)
                    .fixedSize()
            }
            if moving, let motion { motion.label(title, id: item.id) }
            else { title }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: rowPitch - 1)
        .background(band ? theme.block : .clear, in: RoundedRectangle(cornerRadius: 3))
        .padding(.bottom, 1)
    }
}

private struct CalendarCellSurface: ViewModifier {
    let theme: PlannerTheme
    let active: Bool
    let inMonth: Bool
    let targeted: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(targeted ? theme.wash.opacity(0.8)
                        : active ? theme.wash.opacity(0.48)
                        : hovering ? theme.surface.opacity(0.75)
                        : inMonth ? .clear : theme.surface.opacity(0.4))
            .overlay {
                Rectangle().strokeBorder(theme.accent.opacity(targeted ? 0.6 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .animation(.smooth(duration: 0.12), value: targeted)
            .onHover { hovering = $0 }
    }
}
