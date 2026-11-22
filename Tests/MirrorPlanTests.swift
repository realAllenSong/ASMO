import Foundation
import Testing
@testable import ASMOCore

struct MirrorPlanTests {
    let id = UUID()

    func task(_ title: String = "开会", hour: Int? = 15, end: Int? = nil, done: Bool = false, day: Int = 20) -> MirrorItem {
        MirrorItem.from(title: title, year: 2026, month: 11, day: day, hour: hour, minute: 0, endMinute: end, done: done, notes: "")!
    }

    @Test func timedItemsAreEventsAndDayItemsReminders() {
        #expect(task().kind == .event)
        #expect(task().end == 16 * 60)
        #expect(task(hour: nil).kind == .reminder)
        #expect(task(done: true).title == "✓ 开会")
        #expect(task(done: true).plainTitle == "开会")
        #expect(MirrorItem.from(title: "x", year: 2026, month: 1, day: nil, hour: nil, minute: nil, endMinute: nil, done: false, notes: "") == nil)
    }

    @Test func newItemIsCreated() {
        #expect(MirrorPlan.actions(wanted: [id: task()], present: [:], written: [:]) == [.create(id, task())])
    }

    @Test func unchangedDoesNothing() {
        let actions = MirrorPlan.actions(wanted: [id: task()], present: [id: (task(), "e1")],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions.isEmpty)
    }

    @Test func changeHereIsWrittenThere() {
        let moved = task(hour: 16)
        let actions = MirrorPlan.actions(wanted: [id: moved], present: [id: (task(), "e1")],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.update(id, moved, identifier: "e1")])
    }

    @Test func changeThereComesBack() {
        let movedThere = task(hour: 18)
        let actions = MirrorPlan.actions(wanted: [id: task()], present: [id: (movedThere, "e1")],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.pull(id, movedThere)])
    }

    @Test func bothChangedThisSideWins() {
        let here = task(hour: 9), there = task(hour: 18)
        let actions = MirrorPlan.actions(wanted: [id: here], present: [id: (there, "e1")],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.update(id, here, identifier: "e1")])
    }

    @Test func deletedThereIsDeletedHere() {
        let actions = MirrorPlan.actions(wanted: [id: task()], present: [:],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.deleteHere(id, identifier: "e1")])
    }

    @Test func finishedAndClearedThereIsOnlyLetGo() {
        let done = task(hour: nil, done: true)
        let actions = MirrorPlan.actions(wanted: [id: done], present: [:],
                                         written: [id: MirrorRecord(item: done, identifier: "r1")])
        #expect(actions == [.release(id)])
        let again = MirrorPlan.actions(wanted: [id: done], present: [:],
                                       written: [id: MirrorRecord(item: done, identifier: "r1", released: true)])
        #expect(again.isEmpty)
        // Changed here later: written again.
        let reopened = task(hour: nil)
        let changed = MirrorPlan.actions(wanted: [id: reopened], present: [:],
                                         written: [id: MirrorRecord(item: done, identifier: "r1", released: true)])
        #expect(changed == [.create(id, reopened)])
    }

    @Test func changedHereAfterDeletedThereIsWrittenAgain() {
        // Deleted there while it was also changed here: 逐日 wins, it comes back.
        let actions = MirrorPlan.actions(wanted: [id: task(hour: 10)], present: [:],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.create(id, task(hour: 10))])
    }

    @Test func goneHereIsRemovedThere() {
        let actions = MirrorPlan.actions(wanted: [:], present: [id: (task(), "e1")],
                                         written: [id: MirrorRecord(item: task(), identifier: "e1")])
        #expect(actions == [.remove(id, identifier: "e1", kind: .event)])
    }

    @Test func timeAddedSwitchesReminderToEvent() {
        let reminder = task(hour: nil)
        let actions = MirrorPlan.actions(wanted: [id: task()], present: [id: (reminder, "r1")],
                                         written: [id: MirrorRecord(item: reminder, identifier: "r1")])
        #expect(actions == [.remove(id, identifier: "r1", kind: .reminder), .create(id, task())])
    }

    @Test func checkedOffInRemindersComesBack() {
        let reminder = task(hour: nil)
        let checked = task(hour: nil, done: true)
        let actions = MirrorPlan.actions(wanted: [id: reminder], present: [id: (checked, "r1")],
                                         written: [id: MirrorRecord(item: reminder, identifier: "r1")])
        #expect(actions == [.pull(id, checked)])
    }

    // MARK: One copy of each item

    @Test func rolledOverReminderMovesInsteadOfBeingMadeAgain() {
        // Yesterday's reminder is still there (19th); the to-do was rolled over to today (the 20th).
        let yesterday = task(hour: nil, day: 19), today = task(hour: nil, day: 20)
        let settled = MirrorPlan.settle(copies: [id: [MirrorCopy(item: yesterday, identifier: "r1")]], wanted: [id: today], today: (2026, 11, 20))
        #expect(settled.stale.isEmpty)
        let actions = MirrorPlan.actions(wanted: [id: today], present: settled.present,
                                         written: [id: MirrorRecord(item: yesterday, identifier: "r1")])
        #expect(actions == [.update(id, today, identifier: "r1")])
    }

    @Test func extraCopiesOfAWantedItemAreRemoved() {
        let today = task(hour: nil, day: 20)
        let copies = [17, 18, 19, 20].map { MirrorCopy(item: task(hour: nil, day: $0), identifier: "r\($0)") }
        let settled = MirrorPlan.settle(copies: [id: copies], wanted: [id: today], today: (2026, 11, 20))
        #expect(settled.present[id]?.identifier == "r20")
        #expect(Set(settled.stale) == ["r17", "r18", "r19"])
    }

    @Test func unfinishedPastReminderOfAnItemNoLongerThereIsRemoved() {
        let copies = [MirrorCopy(item: task(hour: nil, day: 17), identifier: "open"),
                      MirrorCopy(item: task(hour: nil, done: true, day: 16), identifier: "done"),
                      MirrorCopy(item: task(hour: nil, done: true, day: 15), identifier: "done-twice")]
        let settled = MirrorPlan.settle(copies: [id: copies], wanted: [:], today: (2026, 11, 20))
        #expect(settled.present.isEmpty)
        #expect(Set(settled.stale) == ["open", "done-twice"])
    }

    @Test func pastEventsStay() {
        let settled = MirrorPlan.settle(copies: [id: [MirrorCopy(item: task(day: 10), identifier: "e1")]], wanted: [:], today: (2026, 11, 20))
        #expect(settled.present.isEmpty && settled.stale.isEmpty)
    }

    @Test func upcomingCopyOfAnItemNoLongerWantedIsLeftToThePlan() {
        let settled = MirrorPlan.settle(copies: [id: [MirrorCopy(item: task(hour: nil, day: 25), identifier: "r1")]], wanted: [:], today: (2026, 11, 20))
        #expect(settled.stale.isEmpty)
        #expect(MirrorPlan.actions(wanted: [:], present: settled.present, written: [:]) == [.remove(id, identifier: "r1", kind: .reminder)])
    }

    @Test func checkedOffOnThePhoneSurvivesTheRollOver() {
        // Written for the 19th; checked off on the phone; then this Mac rolled the (still open) to-do to the 20th.
        let written = task(hour: nil, day: 19), checked = task(hour: nil, done: true, day: 19), rolled = task(hour: nil, day: 20)
        let actions = MirrorPlan.actions(wanted: [id: rolled], present: [id: (checked, "r1")],
                                         written: [id: MirrorRecord(item: written, identifier: "r1")])
        let done = task(hour: nil, done: true, day: 20)
        #expect(actions == [.pull(id, done), .update(id, done, identifier: "r1")])
    }

    // MARK: Written only (birthdays)

    @Test func oneWayItemsAreWrittenOverAndLetGo() {
        let birthday = MirrorItem(kind: .event, title: "妈生日", year: 2026, month: 11, day: 21, start: 660, end: 690)
        var moved = birthday
        moved.start = 720
        let record = [id: MirrorRecord(item: birthday, identifier: "e1")]
        #expect(MirrorPlan.actions(wanted: [id: birthday], present: [id: (moved, "e1")], written: record, oneWay: [id])
                == [.update(id, birthday, identifier: "e1")])
        #expect(MirrorPlan.actions(wanted: [id: birthday], present: [:], written: record, oneWay: [id]) == [.release(id)])
    }
}
