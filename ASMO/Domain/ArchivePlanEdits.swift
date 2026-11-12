import Foundation

struct ArchivePlanDraft: Sendable {
    let sourceIDs: [String]
    let sourceText: String
    let title: String
    let schedule: PlanDate
    let endMinute: Int?
    let note: String

    var duplicateKey: String {
        Self.duplicateKey(title: title, schedule: schedule, endMinute: endMinute)
    }

    static func duplicateKey(title: String, schedule: PlanDate, endMinute: Int?) -> String {
        [schedule.key, String(schedule.hour ?? -1), String(schedule.minute ?? -1),
         String(endMinute ?? -1), title.trimmed.lowercased()].joined(separator: "|")
    }

    static func make(title: String, date: PlanDate, sources: [ArchiveEntry], clock: CaptureClock,
                     note: String = "") -> Self {
        let parsed = date.day.flatMap { _ -> CaptureDraft? in
            let draft = CaptureParser.manual(title, clock: clock, selectedDay: date)
            guard draft.schedule?.dayOnly == date.dayOnly, draft.schedule?.hour != nil,
                  !draft.requiresReview else { return nil }
            return draft
        }
        return Self(sourceIDs: sources.map(\.id), sourceText: sources.map(\.body).joined(separator: "\n\n"),
                    title: parsed?.title ?? title, schedule: parsed?.schedule ?? date,
                    endMinute: parsed?.endMinute, note: note)
    }
}

enum ArchivePlanEdits {
    struct Validation: Sendable {
        var drafts: [ArchivePlanDraft] = []
        var invalidLines: [Int] = []
    }

    static func initialText(for entries: [ArchiveEntry]) -> String {
        entries.compactMap { entry in
            guard let key = entry.schedule?.key else { return nil }
            return "\(key): \(entry.body.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "；"))"
        }.joined(separator: "\n")
    }

    static func validate(_ text: String, entries: [ArchiveEntry], clock: CaptureClock) -> Validation {
        let byDate = Dictionary(grouping: entries, by: { $0.schedule?.key })
        var result = Validation()
        var unique = Set<String>()
        for (offset, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmed
            if line.isEmpty { continue }
            guard let parts = line.match(#"^(\d{4}-\d{2}(?:-\d{2})?)\s*[：:]\s*(\S.*)$"#),
                  let sources = byDate[parts[1]], let date = sources.first?.schedule else {
                result.invalidLines.append(offset + 1)
                continue
            }
            let draft = ArchivePlanDraft.make(title: parts[2].trimmed, date: date, sources: sources, clock: clock)
            if unique.insert(draft.duplicateKey).inserted { result.drafts.append(draft) }
        }
        return result
    }

    static func matches(_ query: String, entry: ArchiveEntry) -> Bool {
        let search = query.trimmed
        guard !search.isEmpty else { return true }
        if entry.body.localizedCaseInsensitiveContains(search) { return true }
        guard let date = entry.schedule else { return false }
        if date.key.contains(search) || date.label.contains(search) { return true }
        if let parts = search.match(#"^(\d{4})\s*[.．/\-年]\s*(\d{1,2})(?:\s*[.．/\-月]\s*(\d{1,2}))?\s*[月日号]?$"#) {
            return date.year == Int(parts[1]) && date.month == Int(parts[2]) &&
                (parts[3].isEmpty || date.day == Int(parts[3]))
        }
        if let parts = search.match(#"^(\d{1,2})\s*[.．/\-月]\s*(\d{1,2})\s*[日号]?$"#) {
            return date.month == Int(parts[1]) && date.day == Int(parts[2])
        }
        return false
    }
}
