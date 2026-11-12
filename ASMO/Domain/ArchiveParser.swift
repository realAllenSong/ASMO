import CryptoKit
import Foundation

struct ArchiveEntry: Identifiable, Sendable, Codable {
    var id: String
    var schedule: PlanDate?
    var body: String
}

struct ArchiveImport: Sendable {
    var id: String
    var raw: String
    var entries: [ArchiveEntry]

    func future(from today: PlanDate) -> [ArchiveEntry] {
        entries.filter { entry in
            guard let schedule = entry.schedule, !entry.body.trimmed.isEmpty else { return false }
            if schedule.day == nil { return schedule.key >= String(today.key.prefix(7)) }
            return schedule.dayOnly >= today.dayOnly
        }
    }
}

enum ArchiveParser {
    static func parse(_ raw: String, defaultYear: Int, clock: CaptureClock) -> ArchiveImport {
        var entries: [ArchiveEntry] = []
        var occurrences: [String: Int] = [:]
        var headerYear: Int?
        var headerMonth: Int?
        var schedule: PlanDate?
        var block: [String] = []

        func flush() {
            let body = block.joined(separator: "\n").trimmed
            if !body.isEmpty || schedule != nil {
                let key = digest("\(schedule?.key ?? "?")\n\(body)")
                let occurrence = occurrences[key, default: 0]
                occurrences[key] = occurrence + 1
                entries.append(ArchiveEntry(id: "\(key)-\(occurrence)", schedule: schedule, body: body))
            }
            block.removeAll(keepingCapacity: true)
            schedule = nil
        }

        for line in raw.components(separatedBy: .newlines) {
            if let values = line.match(#"^\s*(\d{2}|\d{4})\s*年\s*(\d{1,2})\s*月\s*[：:]?\s*$"#),
               let year = Int(values[1]), let month = Int(values[2]), (1...12).contains(month) {
                flush()
                headerYear = year < 100 ? year + 2000 : year
                headerMonth = month
            } else if let values = line.match(#"^\s*(?:(\d{4})[.．/\-年])?(\d{1,2})(?:[.．/\-月](\d{1,2})[日号]?)?月?\s*[：:]\s*(.*)$"#),
                      let month = Int(values[2]) {
                flush()
                let explicitYear = Int(values[1])
                let day = Int(values[3])
                let inferredYear = headerMonth == month ? (headerYear ?? defaultYear) : defaultYear
                let candidate = PlanDate(year: explicitYear ?? inferredYear, month: month, day: day)
                if (day != nil || explicitYear != nil), candidate.date(in: clock.calendar) != nil {
                    schedule = candidate
                    block = [values[4]]
                } else {
                    block = [line]
                }
            } else if line.match(#"^\s*\d{1,4}[.．/]\d{1,2}"#) != nil {
                flush()
                block = [line]
            } else {
                block.append(line)
            }
        }
        flush()
        return ArchiveImport(id: digest(raw), raw: raw, entries: entries)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
