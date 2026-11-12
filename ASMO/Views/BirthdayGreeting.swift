import SwiftUI

struct DesktopOccasionZonePicker: View {
    @Binding var selection: String?
    let theme: PlannerTheme
    var isBirthday = false

    private var label: String {
        let zone = selection ?? (isBirthday ? ImportantDateTimeZone.china.rawValue : nil)
        return ImportantDateTimeZone.label(for: zone)
    }

    var body: some View {
        Menu("\(isBirthday ? "生日时区" : "时区") · \(label)") {
            Button("跟随设备") { selection = ImportantDateTimeZone.deviceID }
            ForEach(ImportantDateTimeZone.allCases, id: \.self) { zone in
                Button(zone.label) { selection = zone.rawValue }
            }
        }
        .buttonStyle(PlannerActionStyle(theme: theme))
        .accessibilityLabel(isBirthday ? "生日时区" : "时区")
        .accessibilityValue(label)
    }
}

struct BirthdayGreetingDraft {
    let title: String
    let day: PlanDate
    let rule: ImportantDateRule
}

struct BirthdayGreeting: View {
    let draft: BirthdayGreetingDraft
    let theme: PlannerTheme
    let close: () -> Void
    let review: (Date, String) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var deviceZone = TimeZone.current
    @State private var chosenMinute: Int?

    var body: some View {
        TimelineView(.everyMinute) { tick in
            let now = max(tick.date, .now)
            var calendar = Calendar(identifier: .gregorian)
            let _ = calendar.timeZone = deviceZone
            let suggestion = draft.rule.suggestedGreeting(on: draft.day, after: now, localCalendar: calendar)
            let minute = chosenMinute ?? suggestion.map { ($0.recipient.hour ?? 9) * 60 + ($0.recipient.minute ?? 0) } ?? 540
            let time = draft.rule.greeting(on: draft.day, at: minute, localCalendar: calendar)
            greetingPanel(time: time, minute: minute, now: now, hasSuggestion: suggestion != nil)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { deviceZone = .current }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            deviceZone = .current
        }
    }

    private func greetingPanel(time: BirthdayGreetingTime?, minute: Int, now: Date,
                               hasSuggestion: Bool) -> some View {
        let recipientLabel = time.map { ImportantDateTimeZone.label(for: $0.recipientZone.identifier) } ??
            ImportantDateTimeZone.label(for: draft.rule.timeZoneID)
        let localLabel = ImportantDateTimeZone.label(for: deviceZone.identifier)
        let canSchedule = time.map { $0.instant > now } ?? false

        return PlannerPanel(title: String(localized: "安排生日祝福"), width: 470, height: 320, close: close) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.title).font(.title3.weight(.semibold))
                    Text("\(draft.day.label) · \(recipientLabel)")
                        .font(.subheadline).foregroundStyle(theme.quiet)
                }

                HStack {
                    Text(chosenMinute == nil && hasSuggestion ? "建议祝福时间" : "祝福时间")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    PlannerTimeButton(selection: .init(start: minute), theme: theme, label: String(localized: "选择祝福时间"),
                                      allowsEnd: false, allowsClear: false, compact: true) { selection in
                        chosenMinute = selection.start
                    }
                }
                if let time {
                    HStack(spacing: 8) {
                        timeCard(time.recipient, zone: time.recipientZone, at: time.instant, title: String(localized: "生日当天 · ") + recipientLabel)
                        if time.recipientZone.identifier != deviceZone.identifier {
                            timeCard(time.local, zone: deviceZone, at: time.instant, title: String(localized: "你的设备 · ") + localLabel)
                        }
                    }
                    if time.crossesDateBoundary {
                        Text(time.local.dayOnly < time.recipient.dayOnly ? "你的当地时间是前一天。" : "你的当地时间是次日。")
                            .font(.caption).foregroundStyle(theme.quiet)
                    }
                    if time.instant <= now {
                        Text("这个时间已经过去，可以在生日当天选个更晚的时间。")
                            .font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("该时区在这天没有这个时刻，请选择另一个时间。")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        } footer: {
            Button("取消", action: close).buttonStyle(PlannerActionStyle(theme: theme))
            Button("继续设置提醒") {
                if let time, time.instant > .now { review(time.instant, recipientLabel) }
            }
            .buttonStyle(PlannerActionStyle(theme: theme, primary: true))
            .disabled(!canSchedule)
            .opacity(canSchedule ? 1 : 0.5)
        }
    }

    private func timeCard(_ time: PlanDate, zone: TimeZone, at instant: Date, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(theme.quiet)
            Text(PlannerClockTime.label((time.hour ?? 0) * 60 + (time.minute ?? 0)))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.ink)
            Text("\(time.month) 月 \(time.day ?? 1) 日 · \(ImportantDateTimeZone.offsetLabel(zone, at: instant))")
                .font(.caption.monospacedDigit()).foregroundStyle(theme.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}
