import XCTest
@testable import FocusCore

final class PlanningTests: XCTestCase {
    private let zero = Date(timeIntervalSince1970: 1_000_000)

    func testOldTasksDoNotStarveFutureRemindersAndZeroLeadDoesNotDuplicate() {
        var tasks = (0..<50).map { FocusTask(title: "Antigua \($0)", scheduledAt: zero.addingTimeInterval(-1000)) }
        let future = FocusTask(title: "Nueva", scheduledAt: zero.addingTimeInterval(600), leadMinutes: 0)
        tasks.append(future)
        let reminders = ReminderPlan.make(tasks: tasks, sessionTaskID: nil, now: zero)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders.first?.id, future.id.uuidString + "start")
        XCTAssertEqual(reminders.first?.taskID, future.id)
        XCTAssertEqual(reminders.first?.kind, .start)
    }

    func testReminderOrderingLimitAndActiveExclusion() {
        let tasks = (1...80).map { FocusTask(title: "Tarea \($0)", scheduledAt: zero.addingTimeInterval(Double($0) * 1000)) }
        let reminders = ReminderPlan.make(tasks: tasks.reversed(), sessionTaskID: tasks[0].id, now: zero)
        XCTAssertEqual(reminders.count, 60)
        XCTAssertFalse(reminders.contains { $0.id.hasPrefix(tasks[0].id.uuidString) })
        XCTAssertEqual(reminders.map(\.at), reminders.map(\.at).sorted())
    }

    func testReminderReplenishmentWhenBusyDayConsumesInitialReminders() {
        let tasks = (1...45).map { FocusTask(title: "Tarea \($0)", scheduledAt: zero.addingTimeInterval(Double($0) * 1200), leadMinutes: 10) }
        let initial = ReminderPlan.make(tasks: tasks, sessionTaskID: nil, now: zero)
        XCTAssertEqual(initial.count, 60)
        let initialIDs = initial.map(\.id)
        XCTAssertFalse(ReminderPlan.needsReplenishment(scheduledIDs: initialIDs, tasks: tasks, sessionTaskID: nil, now: zero))

        // After the first task's reminders have passed, needsReplenishment must trigger and incorporate task #31's reminders.
        let later = zero.addingTimeInterval(1500)
        XCTAssertTrue(ReminderPlan.needsReplenishment(scheduledIDs: initialIDs, tasks: tasks, sessionTaskID: nil, now: later))
        let replenished = ReminderPlan.make(tasks: tasks, sessionTaskID: nil, now: later)
        XCTAssertEqual(replenished.count, 60)
        XCTAssertFalse(replenished.contains { $0.taskID == tasks[0].id })
        XCTAssertTrue(replenished.contains { $0.taskID == tasks[30].id })
    }

    func testSnoozeOverdueTaskMovesToFutureAndFutureTaskShiftsRelativeToSchedule() {
        let overdue = FocusTask(title: "Atrasada 2h", scheduledAt: zero.addingTimeInterval(-7200), minutes: 30)
        let snoozedOverdue = overdue.snoozed(minutes: 10, now: zero)
        XCTAssertEqual(snoozedOverdue.scheduledAt, zero.addingTimeInterval(600))
        XCTAssertGreaterThan(snoozedOverdue.scheduledAt, zero)

        let future = FocusTask(title: "Futura", scheduledAt: zero.addingTimeInterval(1800), minutes: 30)
        let snoozedFuture = future.snoozed(minutes: 10, now: zero)
        XCTAssertEqual(snoozedFuture.scheduledAt, zero.addingTimeInterval(2400))

        let unscheduled = FocusTask(title: "Sin hora", scheduledAt: zero.addingTimeInterval(-10000), isScheduled: false, minutes: 25)
        let snoozedUnscheduled = unscheduled.snoozed(minutes: 10, now: zero)
        XCTAssertTrue(snoozedUnscheduled.isScheduled)
        XCTAssertEqual(snoozedUnscheduled.scheduledAt, zero.addingTimeInterval(600))
    }

    func testLateRecurrenceSkipsMissedDaysButKeepsWallTime() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 11))!
        let task = FocusTask(title: "Estudio", scheduledAt: start, repeatRule: .daily)
        let next = try XCTUnwrap(task.nextOccurrence(after: now, calendar: cal))
        XCTAssertGreaterThan(next.scheduledAt, now)
        XCTAssertEqual(cal.component(.day, from: next.scheduledAt), 28)
        XCTAssertEqual(cal.component(.hour, from: next.scheduledAt), 10)
    }

    func testWeekdaysAndCustomDaysRecurrencePreviewAndSingleOccurrenceDetach() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        // Monday Oct 19, 2026 at 09:00
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let sunday = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23))!
        // Mon (2), Wed (4), Fri (6)
        let studyTask = FocusTask(
            title: "Estudiar bloque",
            scheduledAt: monday,
            minutes: 60,
            repeatRule: .customDays,
            repeatDays: [2, 4, 6]
        )
        let preview = studyTask.upcomingOccurrences(in: DateInterval(start: monday, end: sunday), calendar: cal)
        // Upcoming in the same week after Monday are Wednesday (21) and Friday (23)
        XCTAssertEqual(preview.map { cal.component(.day, from: $0.scheduledAt) }, [21, 23])

        // Detach Wednesday (Oct 21) occurrence so it can be edited independently without altering the series
        let wednesday = preview[0].scheduledAt
        let (updatedSeries, detachedSingle) = studyTask.detachOccurrence(at: wednesday, calendar: cal)
        XCTAssertEqual(detachedSingle.repeatRule, .never)
        XCTAssertEqual(detachedSingle.seriesID, studyTask.id)
        let previewAfterDetach = updatedSeries.upcomingOccurrences(in: DateInterval(start: monday, end: sunday), calendar: cal)
        XCTAssertEqual(previewAfterDetach.map { cal.component(.day, from: $0.scheduledAt) }, [23])
    }

    func testUnscheduledTasksAndSmartNextTaskSelectionPrioritizesUpcomingTodayOverAncientOverdue() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 10, minute: 0))!
        let ancientOverdue = FocusTask(title: "Antigua de hace 3 días", scheduledAt: now.addingTimeInterval(-3 * 86400), minutes: 30)
        let upcomingSoon = FocusTask(title: "Reunión importante hoy", scheduledAt: now.addingTimeInterval(15 * 60), minutes: 45)
        let unscheduled = FocusTask(title: "Preparar guion", isScheduled: false, dueDate: now.addingTimeInterval(2 * 86400), minutes: 60)

        // Unscheduled tasks do not produce start reminders or calendar events
        XCTAssertTrue(ReminderPlan.make(tasks: [unscheduled], sessionTaskID: nil, now: now).isEmpty)
        XCTAssertEqual(CalendarProjection.make(task: unscheduled, session: nil, now: now), .unchanged)

        // Smart next task picks the imminent task today rather than the 3-day-old overdue task
        let suggested = FocusRules.nextSuggestedTask(tasks: [ancientOverdue, unscheduled, upcomingSoon], sessionTaskID: nil, now: now, calendar: cal)
        XCTAssertEqual(suggested?.id, upcomingSoon.id)
    }

    func testCalendarProjectionTracksPauseResumeExtensionAndEarlyFinish() throws {
        let task = FocusTask(title: "Vídeo", scheduledAt: zero.addingTimeInterval(100), minutes: 60)
        var session = WorkSession(task: task, now: zero)
        session.pause(at: zero.addingTimeInterval(600))
        XCTAssertEqual(CalendarProjection.make(task: task, session: session, now: zero.addingTimeInterval(610)), .remove)
        session.resume(at: zero.addingTimeInterval(900))
        session.add(minutes: 10)
        guard case .event(let resumed) = CalendarProjection.make(task: task, session: session, now: zero.addingTimeInterval(899)) else { return XCTFail("Missing projection") }
        XCTAssertEqual(resumed.end, zero.addingTimeInterval(4500))
        session.finish(at: zero.addingTimeInterval(1000))
        guard case .event(let ended) = CalendarProjection.make(task: task, session: session, now: zero.addingTimeInterval(1001)) else { return XCTFail("Missing finished projection") }
        XCTAssertEqual(ended.end, zero.addingTimeInterval(1000))
        XCTAssertEqual(ended.start, zero)
    }

    func testOvertimeDoesNotInventFutureDeadlineAndUnstartedTaskDoesNotLookActive() {
        let task = FocusTask(title: "Vídeo", scheduledAt: zero, minutes: 1)
        let session = WorkSession(task: task, now: zero)
        guard case .event(let event) = CalendarProjection.make(task: task, session: session, now: zero.addingTimeInterval(100)) else { return XCTFail() }
        XCTAssertEqual(event.end, zero.addingTimeInterval(60))
        XCTAssertEqual(CalendarProjection.make(task: task, session: nil, now: zero.addingTimeInterval(100)), .unchanged)
    }

    func testExternalCalendarEditsAreDetectedButFractionalSecondRoundingIsTolerated() {
        let original = CalendarSnapshot(title: "Vídeo", start: zero, end: zero.addingTimeInterval(60))
        XCTAssertTrue(original.matches(CalendarSnapshot(title: "Vídeo", start: zero.addingTimeInterval(0.4), end: zero.addingTimeInterval(60))))
        XCTAssertFalse(original.matches(CalendarSnapshot(title: "Editado", start: zero, end: zero.addingTimeInterval(60))))
        XCTAssertFalse(original.matches(CalendarSnapshot(title: "Vídeo", start: zero, end: zero.addingTimeInterval(90))))
        XCTAssertFalse(original.matches(CalendarSnapshot(title: "Vídeo", start: zero, end: zero.addingTimeInterval(60), allDay: true)))
    }

    func testPendingCalendarQueueCoalescesAndClearsOnVerification() {
        var ws = Workspace()
        let taskID = UUID()
        let snap1 = CalendarSnapshot(title: "V1", start: zero, end: zero.addingTimeInterval(600))
        ws.enqueueCalendarOp(PendingCalendarOp(taskID: taskID, action: .upsert, snapshot: snap1))
        XCTAssertEqual(ws.pendingCalendarOps.count, 1)

        // Coalesces when paused/removed before sync completes, avoiding stale events or duplicates
        ws.enqueueCalendarOp(PendingCalendarOp(taskID: taskID, action: .remove, eventID: "evt-1", baselineSnapshot: snap1))
        XCTAssertEqual(ws.pendingCalendarOps.count, 1)
        XCTAssertEqual(ws.pendingCalendarOps.first?.action, .remove)

        ws.clearCalendarOp(for: taskID)
        XCTAssertTrue(ws.pendingCalendarOps.isEmpty)
    }
}
