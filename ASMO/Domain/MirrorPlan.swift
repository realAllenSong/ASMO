import Foundation

/// How 逐日's items are kept in Apple Calendar and Reminders, decided without touching either: given what 逐日 has,
/// what Apple has, and what was last written there, what to create, change, remove, and what to take back
/// (an item moved or checked off in Calendar or Reminders comes back to 逐日).
///
/// Items with a time are calendar events; items with only a day are reminders due that day. 逐日 wins when both
/// sides changed. Something deleted in Calendar or Reminders is deleted in 逐日 too, unless it was done there
/// (clearing finished reminders is housekeeping, not "this never happened"): a done one is only let go of.
public struct MirrorItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case event, reminder }

    public var kind: Kind
    public var title: String
    public var year: Int
    public var month: Int
    public var day: Int
    /// Events only: minutes from midnight.
    public var start: Int?
    public var end: Int?
    public var done: Bool
    public var notes: String

    public init(kind: Kind, title: String, year: Int, month: Int, day: Int, start: Int? = nil, end: Int? = nil,
                done: Bool = false, notes: String = "") {
        self.kind = kind
        self.title = title
        self.year = year
        self.month = month
        self.day = day
        self.start = start
        self.end = end
        self.done = done
        self.notes = notes
    }

    /// A 逐日 item as it should look in Apple's apps (nil for items that have no day). An event without an end lasts
    /// an hour; a done event says ✓ in its title (events have no checkbox).
    public static func from(title: String, year: Int, month: Int, day: Int?, hour: Int?, minute: Int?, endMinute: Int?,
                            done: Bool, notes: String) -> MirrorItem? {
        guard let day else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let hour {
            let start = hour * 60 + (minute ?? 0)
            let end = min(endMinute.flatMap { $0 > start ? $0 : nil } ?? start + 60, 24 * 60 - 1)
            return MirrorItem(kind: .event, title: done ? "✓ " + trimmed : trimmed, year: year, month: month, day: day,
                              start: start, end: end, done: done, notes: notes)
        }
        return MirrorItem(kind: .reminder, title: trimmed, year: year, month: month, day: day, done: done, notes: notes)
    }

    /// The title without the ✓ an event carries when done.
    public var plainTitle: String {
        kind == .event && title.hasPrefix("✓ ") ? String(title.dropFirst(2)) : title
    }
}

/// What was last written to Apple for one item.
public struct MirrorRecord: Codable, Equatable, Sendable {
    public var item: MirrorItem
    /// EventKit's identifier for it.
    public var identifier: String
    /// Deleted in Calendar or Reminders: left alone there until the item itself changes in 逐日.
    public var released = false

    public init(item: MirrorItem, identifier: String, released: Bool = false) {
        self.item = item
        self.identifier = identifier
        self.released = released
    }
}

public enum MirrorAction: Equatable, Sendable {
    /// Write a new event or reminder.
    case create(UUID, MirrorItem)
    /// Change Apple's copy to match 逐日 (`identifier` is the existing one).
    case update(UUID, MirrorItem, identifier: String)
    /// Remove Apple's copy (the item is gone from 逐日, or became the other kind).
    case remove(UUID, identifier: String, kind: MirrorItem.Kind)
    /// The item was changed in Calendar or Reminders: change it in 逐日 to `MirrorItem`.
    case pull(UUID, MirrorItem)
    /// Apple's copy of a finished item was deleted there: stop writing it until the item changes in 逐日.
    case release(UUID)
    /// Apple's copy was deleted there: delete the item in 逐日 (once it's checked that it really is gone).
    case deleteHere(UUID, identifier: String)
}

/// One copy of an item found in Calendar or Reminders (an item should have one; a bug or a sync hiccup can leave more).
public struct MirrorCopy: Equatable, Sendable {
    public var item: MirrorItem
    public var identifier: String

    public init(item: MirrorItem, identifier: String) {
        self.item = item
        self.identifier = identifier
    }
}

public enum MirrorPlan {
    /// Picks the one copy of each item that the plan works with, and names the copies to remove outright:
    /// - an item 逐日 wants keeps one copy (the one that already matches, else the latest), wherever its day is, so a
    ///   to-do rolled over to today moves its reminder instead of leaving yesterday's behind;
    /// - an item 逐日 no longer wants keeps nothing from today on, and nothing unfinished in the past (the reminder
    ///   of a deleted or rewritten to-do would sit in "Today" as overdue forever); what was finished in the past
    ///   stays, once.
    /// `today` is (year, month, day).
    public static func settle(copies: [UUID: [MirrorCopy]], wanted: [UUID: MirrorItem], today: (Int, Int, Int))
        -> (present: [UUID: (item: MirrorItem, identifier: String)], stale: [String]) {
        func day(_ item: MirrorItem) -> Int { item.year * 10_000 + item.month * 100 + item.day }
        let todayKey = today.0 * 10_000 + today.1 * 100 + today.2
        var present: [UUID: (item: MirrorItem, identifier: String)] = [:]
        var stale: [String] = []
        for (id, all) in copies {
            let latestFirst = all.sorted { (day($0.item), $0.identifier) > (day($1.item), $1.identifier) }
            if let want = wanted[id] {
                let keep = latestFirst.first { $0.item == want } ?? latestFirst[0]
                present[id] = (keep.item, keep.identifier)
                stale += latestFirst.filter { $0.identifier != keep.identifier }.map(\.identifier)
                continue
            }
            let upcoming = latestFirst.filter { day($0.item) >= todayKey }
            if let first = upcoming.first { present[id] = (first.item, first.identifier) }   // the plan removes it
            stale += upcoming.dropFirst().map(\.identifier)
            let past = latestFirst.filter { day($0.item) < todayKey }
            let finished = past.filter { $0.item.kind == .event || $0.item.done }
            stale += past.filter { $0.item.kind == .reminder && !$0.item.done }.map(\.identifier)
            stale += finished.dropFirst().map(\.identifier)
        }
        return (present, stale)
    }

    /// - Parameters:
    ///   - wanted: 逐日's items that belong in Apple's apps, by item id.
    ///   - present: what Apple's apps have now, by the item id written into each.
    ///   - written: what was last written, by item id.
    ///   - oneWay: items only ever written, never read back (birthdays and other yearly dates): a change made
    ///     there is written over, and one deleted there is let go of.
    ///   - checkOnly: one day of a repeating item. Its check mark comes back (done on the phone is done here);
    ///     its words and day are the routine's, so any other change there is written over, and one deleted there
    ///     is let go of.
    public static func actions(wanted: [UUID: MirrorItem], present: [UUID: (item: MirrorItem, identifier: String)],
                               written: [UUID: MirrorRecord], oneWay: Set<UUID> = [],
                               checkOnly: Set<UUID> = []) -> [MirrorAction] {
        var actions: [MirrorAction] = []
        for (id, want) in wanted {
            let record = written[id]
            guard let have = present[id] else {
                if let record, !record.released, record.item == want {
                    // Deleted in Calendar/Reminders while unchanged here: delete it here too, or (done) let go.
                    actions.append(want.done || oneWay.contains(id) || checkOnly.contains(id)
                                   ? .release(id) : .deleteHere(id, identifier: record.identifier))
                } else if let record, record.released, record.item == want {
                    // Already let go of, and still unchanged here: nothing to do.
                } else {
                    actions.append(.create(id, want))
                }
                continue
            }
            if have.item.kind != want.kind {
                actions.append(.remove(id, identifier: have.identifier, kind: have.item.kind))
                actions.append(.create(id, want))
                continue
            }
            if have.item == want { continue }
            // Something differs. If 逐日 is as last written, the change was made in Apple's app: take it back.
            if oneWay.contains(id) {
                actions.append(.update(id, want, identifier: have.identifier))
            } else if let record, record.item == want, have.item != record.item, !checkOnly.contains(id) {
                actions.append(.pull(id, have.item))
            } else if let record, have.item.done != record.item.done, want.done == record.item.done {
                // Both changed, and what changed there is the check mark (an overdue reminder checked off on the
                // phone before this Mac rolled it over to today): the check mark is kept, the rest is 逐日's.
                var merged = want
                merged.done = have.item.done
                if merged.kind == .event {
                    merged.title = (merged.done ? "✓ " : "") + want.plainTitle
                }
                actions.append(.pull(id, merged))
                if merged != have.item { actions.append(.update(id, merged, identifier: have.identifier)) }
            } else {
                actions.append(.update(id, want, identifier: have.identifier))
            }
        }
        // In Apple's apps but no longer wanted (deleted, or its day removed in 逐日): remove it.
        for (id, have) in present where wanted[id] == nil {
            actions.append(.remove(id, identifier: have.identifier, kind: have.item.kind))
        }
        return actions
    }
}
