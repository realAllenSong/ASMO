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
}
