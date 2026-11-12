import Foundation

extension String {
    /// This text in the app's language, when it is fixed wording the app ships (helpers that take a plain string
    /// look their titles up here). Anything that isn't a known phrase comes back unchanged.
    var localized: String { Bundle.main.localizedString(forKey: self, value: self, table: nil) }
}

/// The language the app's interface is shown in, and the dates and weekdays written in it.
enum AppLanguage {
    /// What Settings ▸ 语言 offers. Stored as the app's own AppleLanguages, which macOS reads at launch.
    enum Choice: String, CaseIterable {
        case system, chinese, english

        var label: String {
            switch self {
            case .system: String(localized: "跟随系统")
            case .chinese: "中文"
            case .english: "English"
            }
        }

        var languages: [String]? {
            switch self {
            case .system: nil
            case .chinese: ["zh-Hans"]
            case .english: ["en"]
            }
        }
    }

    /// The choice saved for this app (not the system-wide list macOS falls back to).
    static var choice: Choice {
        get {
            let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
            guard let first = own?.first else { return .system }
            return first.hasPrefix("en") ? .english : first.hasPrefix("zh") ? .chinese : .system
        }
        set {
            if let languages = newValue.languages { UserDefaults.standard.set(languages, forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// The choice the running app started with (a change shows after reopening).
    static let launchedWith = choice

    /// People who used 逐日 before it spoke English keep the Chinese interface; new installs follow the system.
    static func keepChineseForEarlierUsers(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: "languageChosen") else { return }
        defaults.set(true, forKey: "languageChosen")
        if defaults.bool(forKey: "paperLookApplied") { choice = .chinese }
    }

    static var isEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false }

    private static var locale: Locale { isEnglish ? Locale(identifier: "en_US") : Locale(identifier: "zh_Hans_CN") }

    private static func date(_ year: Int, _ month: Int, _ day: Int = 1) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    /// "2026年11月" / "November 2026".
    static func monthTitle(year: Int, month: Int) -> String {
        isEnglish ? date(year, month).formatted(.dateTime.month(.wide).year().locale(locale)) : "\(year)年\(month)月"
    }

    /// "11 月 11 日" / "Nov 11".
    static func dayTitle(month: Int, day: Int) -> String {
        isEnglish ? date(2001, month, day).formatted(.dateTime.month(.abbreviated).day().locale(locale)) : "\(month) 月 \(day) 日"
    }

    /// Weekday names by calendar index (1 = Sunday): "周日" / "Sun"; `short` gives "日" / "S".
    static func weekday(_ index: Int, short: Bool = false) -> String {
        let chinese = ["日", "一", "二", "三", "四", "五", "六"][(index - 1 + 7) % 7]
        guard isEnglish else { return short ? chinese : "周" + chinese }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = short ? calendar.veryShortWeekdaySymbols : calendar.shortWeekdaySymbols
        return symbols[(index - 1 + 7) % 7]
    }
}
