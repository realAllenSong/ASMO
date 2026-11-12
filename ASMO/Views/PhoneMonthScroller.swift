#if os(iOS)
import SwiftUI

/// One month per swipe, landing exactly on a page (a multiple of the scroll area's height). The system's paging
/// moved programmatic scrolls off the page boundary; this one only decides where a finger's scroll ends.
private struct MonthPaging: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let height = context.containerSize.height
        guard height > 0 else { return }
        let from = (context.originalTarget.rect.minY / height).rounded()
        var page = (target.rect.minY / height).rounded()
        // A flick that didn't travel half a page still turns it.
        if page == from, abs(context.velocity.dy) > 0.3 { page += context.velocity.dy > 0 ? 1 : -1 }
        page = min(max(page, from - 1), from + 1)
        let last = max(0, (context.contentSize.height / height).rounded() - 1)
        target.rect.origin.y = min(max(page, 0), last) * height
    }
}

/// The iPhone calendar, like Apple Calendar's month view: months follow one another in one continuous vertical
/// scroll, each day lists its items in the cell, and the title shows the month on screen. Tap the title for a
/// month picker, 今天 to come back, a day to open its page.
struct PhoneMonthScroller: View {
    /// The month to start on, and to scroll to whenever `jump` changes.
    let start: PlanDate
    let jump: Int
    let today: PlanDate
    let theme: PlannerTheme
    let calendar: Calendar
    let items: (CalendarMonth) -> [PlanDate: [CalendarDayItem]]
    let openDay: (PlanDate) -> Void
    /// Opens the day ready to type.
    let writeDay: (PlanDate) -> Void
    let settings: () -> Void

    /// Scrolled by exact offsets (page index × page height): positions never depend on layout estimates.
    @State private var scroller = ScrollPosition()
    @State private var pageHeight: CGFloat = 0
    @State private var nudge = false
    /// The scroll starts on the right month (set before the first layout, so the page lands exactly).
    init(start: PlanDate, jump: Int, today: PlanDate, theme: PlannerTheme, calendar: Calendar,
         items: @escaping (CalendarMonth) -> [PlanDate: [CalendarDayItem]], openDay: @escaping (PlanDate) -> Void,
         writeDay: @escaping (PlanDate) -> Void, settings: @escaping () -> Void) {
        self.start = start; self.jump = jump; self.today = today; self.theme = theme; self.calendar = calendar
        self.items = items; self.openDay = openDay; self.writeDay = writeDay; self.settings = settings
    }
    @State private var visible: PlanDate?
    @State private var ready = false
    @State private var picking = false
    @State private var pickerYear = 2026

    /// Three years back and forward; the list is lazy, so only what's on screen is built.
    private var months: [PlanDate] {
        (-36...36).compactMap { offset in
            guard let base = PlanDate(year: today.year, month: today.month, day: 1).date(in: calendar),
                  let date = calendar.date(byAdding: .month, value: offset, to: base) else { return nil }
            let day = PlanDate.from(date, calendar: calendar)
            return PlanDate(year: day.year, month: day.month)
        }
    }

    private var shown: PlanDate { visible ?? PlanDate(year: start.year, month: start.month) }
    private var shownIndex: Int { months.firstIndex { $0.key == shown.key } ?? 36 }
    /// Five days to a row instead of seven: wider cells, so a month fills the screen and its lines can be read.
    private static let columns = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                ScrollView {
                    // Every page has the same fixed height, so positions are exact; only the month on screen and
                    // its neighbours are drawn (the rest are blank placeholders).
                    VStack(spacing: 0) {
                        ForEach(Array(months.enumerated()), id: \.element.key) { index, month in
                            Group {
                                if abs(index - shownIndex) <= 1 {
                                    // A page is exactly the scroll area; its rows stop above the floating bar.
                                    page(month, height: proxy.size.height, bottom: 58)
                                } else {
                                    Color.clear.frame(height: proxy.size.height)
                                }
                            }
                                .id(month.key)
                                // The month coming in settles into place; the one leaving falls back a little.
                                .scrollTransition(.interactive, axis: .vertical) { view, phase in
                                    view.opacity(phase.isIdentity ? 1 : 0.35)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.96)
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(MonthPaging())
                .scrollPosition($scroller)
                .onScrollGeometryChange(for: Int.self) { geometry in
                    Int((geometry.contentOffset.y / max(geometry.containerSize.height, 1)).rounded())
                } action: { _, index in
                    if ready, months.indices.contains(index) { visible = months[index] }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                // The height settles over the first frames (safe areas arrive): each height gets a fresh scroll view,
                // landed on the month that was showing, so pages and paging always agree.
                .id(Int(proxy.size.height.rounded()))
                .task(id: Int(proxy.size.height.rounded())) {
                    let height = proxy.size.height
                    let month = ready ? shown : PlanDate(year: start.year, month: start.month)
                    pageHeight = height
                    for delay in [0, 40, 120, 300] {
                        try? await Task.sleep(for: .milliseconds(delay))
                        guard !Task.isCancelled else { return }
                        land(on: month)
                    }
                    ready = true
                }
            }
            .onChange(of: jump) { _, _ in scroll(to: start) }
            .sensoryFeedback(.selection, trigger: shown.key)
        }
    }

    private func land(on month: PlanDate) {
        guard pageHeight > 0, let index = months.firstIndex(where: { $0.year == month.year && $0.month == month.month }) else { return }
        // Never the same request twice in a row (an unchanged one is ignored even when the layout moved under it).
        nudge.toggle()
        scroller.scrollTo(y: CGFloat(index) * pageHeight + (nudge ? 0.01 : 0))
    }

    private func scroll(to month: PlanDate) {
        withAnimation(.smooth(duration: 0.45)) { land(on: month) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { pickerYear = shown.year; picking = true } label: {
                HStack(spacing: 6) {
                    Text(AppLanguage.monthTitle(year: shown.year, month: shown.month))
                        .font(.system(size: 26, weight: .bold)).tracking(-0.5)
                        .foregroundStyle(theme.ink)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: shown.key)
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.quiet)
                        .rotationEffect(.degrees(picking ? 180 : 0))
                }
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("monthMenu")
            .popover(isPresented: $picking, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                monthPicker.presentationCompactAdaptation(.popover)
            }
            Spacer()
            if shown.year != today.year || shown.month != today.month {
                Button { scroll(to: today) } label: {
                    Text("今天").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                        .padding(.horizontal, 12).frame(height: 34)
                        .background(theme.block, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .accessibilityIdentifier("todayButton")
            }
            Button(action: settings) {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.quiet)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
        }
        .animation(.snappy, value: shown.year != today.year || shown.month != today.month)
        .padding(.horizontal, 16).padding(.top, 2)
    }

    private var monthPicker: some View {
        VStack(spacing: 12) {
            HStack {
                Button { withAnimation(.snappy) { pickerYear -= 1 } } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 40).contentShape(Rectangle())
                }
                Spacer()
                Text(String(pickerYear)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Button { withAnimation(.snappy) { pickerYear += 1 } } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 40).contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let current = pickerYear == shown.year && month == shown.month
                    let isThisMonth = pickerYear == today.year && month == today.month
                    let reachable = months.contains { $0.year == pickerYear && $0.month == month }
                    Button {
                        picking = false
                        scroll(to: PlanDate(year: pickerYear, month: month))
                    } label: {
                        Text(AppLanguage.isEnglish ? Calendar(identifier: .gregorian).shortMonthSymbols[month - 1] : "\(month)月")
                            .font(.system(size: 15, weight: current ? .semibold : .regular))
                            .foregroundStyle(current ? theme.onAccent : isThisMonth ? theme.accent : theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(current ? theme.accent : theme.block.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!reachable)
                    .opacity(reachable ? 1 : 0.35)
                    .accessibilityIdentifier("pick-month-\(month)")
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Months

    /// One month filling the screen: its days in rows of five, each with its weekday.
    private func page(_ month: PlanDate, height: CGFloat, bottom: CGFloat) -> some View {
        let grid = CalendarMonth(containing: month, calendar: calendar)
        let data = items(grid)
        let days = grid.days.filter { $0.month == month.month && $0.year == month.year }
        let rows = Int((Double(days.count) / Double(Self.columns)).rounded(.up))
        // The rows share the height above the bar.
        let rowHeight = max(60, (height - bottom - 6) / CGFloat(max(rows, 1)))
        return VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        let index = row * Self.columns + column
                        if index < days.count {
                            cell(days[index], items: data[days[index]] ?? [], height: rowHeight)
                                .overlay(alignment: .leading) {
                                    if column > 0 { Rectangle().fill(theme.line.opacity(0.6)).frame(width: 0.5) }
                                }
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: rowHeight)
                .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 0.5) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: height)
    }

    private func weekday(of date: PlanDate) -> Int {
        date.date(in: calendar).map { calendar.component(.weekday, from: $0) } ?? 1
    }

    private func cell(_ date: PlanDate, items all: [CalendarDayItem], height: CGFloat) -> some View {
        // The month shows what is particular to each day; routines (the same line every day) wait in the day itself
        // and in the press-and-hold preview.
        let items = all.filter { !$0.id.hasPrefix("routine-") }
        let isToday = date == today
        let day = weekday(of: date)
        let capacity = max(1, Int((height - 40) / 18))
        let visible = items.prefix(items.count > capacity ? capacity - 1 : capacity)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(date.day.map(String.init) ?? "")
                    .font(.system(size: 17, weight: isToday ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? theme.onAccent : theme.ink)
                    .frame(minWidth: 28, minHeight: 28)
                    .background { if isToday { Circle().fill(theme.accent) } }
                Text(AppLanguage.weekday(day))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isToday ? theme.accent : day == 1 || day == 7 ? theme.quiet.opacity(0.6) : theme.quiet)
                Spacer(minLength: 0)
            }
            .padding(.top, 5).padding(.bottom, 1)
            ForEach(visible) { item in
                let timed = item.kind == .occasion || item.kind == .event || item.startMinute != nil
                // Cut at the cell's edge without "…" (a few more characters stay readable).
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
                    .overlay(alignment: .leading) {
                        Text(item.previewTitle)
                            .font(.system(size: 12, weight: timed ? .medium : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? theme.quiet.opacity(0.7) : timed ? theme.accent : theme.ink.opacity(0.88))
                            .padding(.horizontal, 4)
                    }
                    .clipped()
                    .background(timed && !item.completed ? theme.block : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
            if items.count > visible.count {
                Text("+\(items.count - visible.count)")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.quiet)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(isToday ? theme.block.opacity(0.35) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { openDay(date) }
        // Press and hold: a look at the whole day without opening it.
        .contextMenu {
            Button { openDay(date) } label: { Label("打开这一天", systemImage: "arrow.up.right") }
            Button { writeDay(date) } label: { Label("记到这一天", systemImage: "square.and.pencil") }
        } preview: {
            peek(date, items: all)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(date.label + (all.isEmpty ? "" : "，" + all.map(\.title).joined(separator: "，")))
        .accessibilityIdentifier("calendar-day-" + date.key)
    }

    /// The day as a card: every item with its time, for the press-and-hold preview.
    private func peek(_ date: PlanDate, items: [CalendarDayItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppLanguage.dayTitle(month: date.month, day: date.day ?? 1) + " " + AppLanguage.weekday(weekday(of: date)))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(date == today ? theme.accent : theme.ink)
                .padding(.bottom, 10)
            if items.isEmpty {
                Text("这天还没有安排").font(.system(size: 15)).foregroundStyle(theme.quiet)
            }
            ForEach(items.prefix(12)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.startMinute.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) } ?? "·")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.completed ? theme.quiet : theme.accent)
                        .frame(width: 46, alignment: .leading)
                    Text(item.previewTitle)
                        .font(.system(size: 16))
                        .strikethrough(item.completed)
                        .foregroundStyle(item.completed ? theme.quiet : theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }
            if items.count > 12 {
                Text("+\(items.count - 12)").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.quiet).padding(.top, 4)
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
        .background(theme.paper)
    }
}
#endif
