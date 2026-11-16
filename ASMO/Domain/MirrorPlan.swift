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

public enum MirrorPlan {
    /// - Parameters:
    ///   - wanted: 逐日's items that belong in Apple's apps, by item id.
    ///   - present: what Apple's apps have now, by the item id written into each.
    ///   - written: what was last written, by item id.
    ///   - inWindow: whether an item id is in the range of days being kept (outside it nothing is removed).
    public static func actions(wanted: [UUID: MirrorItem], present: [UUID: (item: MirrorItem, identifier: String)],
                               written: [UUID: MirrorRecord]) -> [MirrorAction] {
        var actions: [MirrorAction] = []
        for (id, want) in wanted {
            let record = written[id]
            guard let have = present[id] else {
                if let record, !record.released, record.item == want {
                    // Deleted in Calendar/Reminders while unchanged here: delete it here too, or (done) let go.
                    actions.append(want.done ? .release(id) : .deleteHere(id, identifier: record.identifier))
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
            if let record, record.item == want, have.item != record.item {
                actions.append(.pull(id, have.item))
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
