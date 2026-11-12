#if os(iOS)
import SwiftUI

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
    let settings: () -> Void

    @State private var position: String?
    @State private var visible: PlanDate?
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
    private static let rowHeight: CGFloat = 118

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdays
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(months, id: \.key) { month in
                        section(month).id(month.key)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .top)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .onAppear { position = PlanDate(year: start.year, month: start.month).key }
            .onChange(of: position) { _, key in
                guard let key, let month = months.first(where: { $0.key == key }) else { return }
                visible = month
            }
            .onChange(of: jump) { _, _ in scroll(to: start) }
            .sensoryFeedback(.selection, trigger: shown.key)
        }
    }

    private func scroll(to month: PlanDate) {
        withAnimation(.smooth(duration: 0.45)) { position = PlanDate(year: month.year, month: month.month).key }
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

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { column in
                let weekday = (calendar.firstWeekday - 1 + column) % 7 + 1
                Text(AppLanguage.weekday(weekday, short: true))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(weekday == 1 || weekday == 7 ? theme.quiet.opacity(0.7) : theme.quiet)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 0.5) }
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

    /// One month: its name over the column of its first day, then its weeks. Days of other months stay blank
    /// (they belong to the month above or below), as in Apple Calendar.
    private func section(_ month: PlanDate) -> some View {
        let grid = CalendarMonth(containing: month, calendar: calendar)
        let data = items(grid)
        let weeks = grid.days.count / 7
        let firstColumn = grid.days.firstIndex { $0.month == month.month } ?? 0
        let isThisMonth = month.year == today.year && month.month == today.month
        return VStack(spacing: 0) {
            GeometryReader { proxy in
                Text(AppLanguage.isEnglish ? Calendar(identifier: .gregorian).monthSymbols[month.month - 1]
                     : (month.month == 1 ? "\(month.year)年1月" : "\(month.month)月"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isThisMonth ? theme.accent : theme.ink)
                    .padding(.leading, proxy.size.width / 7 * CGFloat(firstColumn) + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(height: 34)
            ForEach(0..<weeks, id: \.self) { week in
                let days = Array(grid.days[(week * 7)..<((week + 1) * 7)])
                if days.contains(where: { $0.month == month.month }) {
                    HStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            if day.month == month.month { cell(day, items: data[day] ?? []) }
                            else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                    .frame(height: Self.rowHeight)
                    .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 0.5) }
                }
            }
        }
    }

    private func cell(_ date: PlanDate, items: [CalendarDayItem]) -> some View {
        let isToday = date == today
        let capacity = 4
        let visible = items.prefix(items.count > capacity ? capacity - 1 : capacity)
        return VStack(alignment: .leading, spacing: 1.5) {
            Text(date.day.map(String.init) ?? "")
                .font(.system(size: 15, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? theme.onAccent : theme.ink)
                .frame(width: 28, height: 28)
                .background { if isToday { Circle().fill(theme.accent) } }
                .frame(maxWidth: .infinity)
                .padding(.top, 3).padding(.bottom, 2)
            ForEach(visible) { item in
                let timed = item.kind == .occasion || item.kind == .event || item.startMinute != nil
                // Cut at the cell's edge without "…" (a few more characters stay readable); the cell's width
                // decides, never the text's.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 15, maxHeight: 15)
                    .overlay(alignment: .leading) {
                        Text(item.previewTitle)
                            .font(.system(size: 11, weight: timed ? .medium : .regular))
                            .lineLimit(1)
                            .fixedSize()
                            .strikethrough(item.completed)
                            .foregroundStyle(item.completed ? theme.quiet.opacity(0.75) : timed ? theme.accent : theme.ink.opacity(0.85))
                            .padding(.horizontal, 3)
                    }
                    .clipped()
                    .background(timed && !item.completed ? theme.block : .clear, in: RoundedRectangle(cornerRadius: 3))
            }
            if items.count > visible.count {
                Text("+\(items.count - visible.count)")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.quiet)
                    .padding(.horizontal, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1.5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { openDay(date) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(date.label + (items.isEmpty ? "" : "，" + items.map(\.title).joined(separator: "，")))
        .accessibilityIdentifier("calendar-day-" + date.key)
    }
}
#endif
