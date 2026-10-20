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
    }
    func testReminderOrderingLimitAndActiveExclusion() {
        let tasks = (1...80).map { FocusTask(title: "Tarea \($0)", scheduledAt: zero.addingTimeInterval(Double($0) * 1000)) }
        let reminders = ReminderPlan.make(tasks: tasks.reversed(), sessionTaskID: tasks[0].id, now: zero)
        XCTAssertEqual(reminders.count, 60)
        XCTAssertFalse(reminders.contains { $0.id.hasPrefix(tasks[0].id.uuidString) })
        XCTAssertEqual(reminders.map(\.at), reminders.map(\.at).sorted())
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
}
