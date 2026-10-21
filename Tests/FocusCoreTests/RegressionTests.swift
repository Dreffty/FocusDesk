import XCTest
@testable import FocusCore

/// Regressions for the day-to-day use issues found while reviewing FocusDesk 0.2.
final class RegressionTests: XCTestCase {
    private func madrid() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return cal
    }

    /// The projection used to walk every occurrence since `scheduledAt`, so the day and week views got slower the
    /// longer a series had existed. Jumping straight to the window must not change which occurrences come back.
    func testOccurrencePreviewIsIndependentOfHowOldTheSeriesIs() throws {
        let cal = madrid()
        // Window: Monday Nov 16 to Sunday Nov 22, 2026.
        let windowStart = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 0))!
        let windowEnd = cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23, minute: 59))!
        let window = DateInterval(start: windowStart, end: windowEnd)

        for rule in [RepeatRule.daily, .weekly, .weekdays, .customDays] {
            var days: [Int] = []
            for ageInDays in [3, 30, 180, 400] {
                let start = cal.date(byAdding: .day, value: -ageInDays, to: windowStart)!
                let anchored = cal.date(bySettingHour: 9, minute: 0, second: 0, of: start)!
                let task = FocusTask(
                    title: "Serie \(rule.rawValue)",
                    scheduledAt: anchored,
                    minutes: 60,
                    repeatRule: rule,
                    repeatDays: rule == .customDays ? [2, 4, 6] : []
                )
                let preview = task.upcomingOccurrences(in: window, calendar: cal)
                XCTAssertFalse(preview.isEmpty, "\(rule) con \(ageInDays) días debería proyectar algo")
                // Everything returned sits inside the window and keeps the wall-clock time of the series.
                for occurrence in preview {
                    XCTAssertGreaterThanOrEqual(occurrence.scheduledAt, windowStart)
                    XCTAssertLessThanOrEqual(occurrence.scheduledAt, windowEnd)
                    XCTAssertEqual(cal.component(.hour, from: occurrence.scheduledAt), 9)
                    XCTAssertEqual(occurrence.seriesID, task.id)
                }
                let weekdays = Set(preview.map { cal.component(.weekday, from: $0.scheduledAt) })
                switch rule {
                case .weekdays:
                    XCTAssertTrue(weekdays.isSubset(of: [2, 3, 4, 5, 6]), "laborables no debería incluir fin de semana")
                case .customDays:
                    XCTAssertTrue(weekdays.isSubset(of: [2, 4, 6]), "días concretos debería limitarse a L, X, V")
                default:
                    break
                }
                days.append(preview.count)
            }
            // The age of the series must not change how many occurrences land in the same window.
            XCTAssertEqual(Set(days).count, 1, "\(rule) devuelve distinto número según la antigüedad: \(days)")
        }
    }

    /// A skipped (detached) occurrence must stay skipped when the window is reached by jumping instead of walking.
    func testSkippedOccurrenceStaysSkippedInAFarWindow() throws {
        let cal = madrid()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 9))!
        var task = FocusTask(title: "Estudiar", scheduledAt: start, minutes: 45, repeatRule: .daily)
        let skipped = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        task.skippedDates.insert(FocusRules.dayKey(for: skipped, calendar: cal))

        let window = DateInterval(
            start: cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 0))!,
            end: cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 23, minute: 59))!
        )
        let days = task.upcomingOccurrences(in: window, calendar: cal).map { cal.component(.day, from: $0.scheduledAt) }
        XCTAssertEqual(days, [16, 17, 19, 20, 21, 22], "el 18 está separado de la serie y no debe proyectarse")
    }

    /// The countdown has to pass through 00:00 instead of jumping straight from 00:01 to +00:01.
    func testClockReachesZeroBeforeShowingOvertime() {
        XCTAssertEqual(FocusRules.clock(61), "01:01")
        XCTAssertEqual(FocusRules.clock(60), "01:00")
        XCTAssertEqual(FocusRules.clock(1), "00:01")
        XCTAssertEqual(FocusRules.clock(0.4), "00:00")
        XCTAssertEqual(FocusRules.clock(0), "00:00")
        XCTAssertEqual(FocusRules.clock(-0.4), "00:00")
        XCTAssertEqual(FocusRules.clock(-1), "+00:01")
        XCTAssertEqual(FocusRules.clock(-125), "+02:05")
        XCTAssertEqual(FocusRules.clock(3661), "1:01:01")
    }

    /// Vorssaint shows the nearest eligible moment of the calendar, so a task starting before the running session ends
    /// would count down to something the user is not doing yet. Only the session may hold the island while it runs.
    func testOnlyTheRunningSessionIsProjectedWhileAnotherTaskWouldCompeteForTheIsland() {
        let now = Date()
        var running = FocusTask(title: "Grabar", scheduledAt: now, minutes: 60)
        running.calendarEventID = "evento-sesion"
        var session = WorkSession(task: running, now: now, uptime: 1000)
        session.runningSince = now
        session.runningUptime = 1000

        // Starts 20 minutes in, while the session still has 60: it would steal the countdown.
        var competing = FocusTask(title: "Editar", scheduledAt: now.addingTimeInterval(20 * 60), minutes: 30)
        competing.calendarEventID = "evento-competidor"
        XCTAssertEqual(CalendarProjection.make(task: competing, session: session, now: now, uptime: 1000), .remove)

        // Never projected is never removed either: nothing to clean up, nothing to churn.
        var neverProjected = competing
        neverProjected.calendarEventID = nil
        XCTAssertEqual(CalendarProjection.make(task: neverProjected, session: session, now: now, uptime: 1000), .unchanged)

        // Starts after the session ends: it keeps its block, the island is free by then.
        let later = FocusTask(title: "Estudiar", scheduledAt: now.addingTimeInterval(90 * 60), minutes: 45)
        guard case .event(let snapshot) = CalendarProjection.make(task: later, session: session, now: now, uptime: 1000) else {
            return XCTFail("una tarea posterior al final de la sesión debe conservar su evento")
        }
        XCTAssertEqual(snapshot.start, later.scheduledAt)

        // The session itself keeps the island, ending at its own deadline.
        guard case .event(let own) = CalendarProjection.make(task: running, session: session, now: now, uptime: 1000) else {
            return XCTFail("la sesión en marcha debe proyectarse")
        }
        XCTAssertEqual(own.end.timeIntervalSince(now), 3600, accuracy: 2)

        // Paused there is no session countdown to protect, so the agenda comes back.
        session.pause(at: now, uptime: 1000)
        guard case .event = CalendarProjection.make(task: competing, session: session, now: now, uptime: 1000) else {
            return XCTFail("con la sesión en pausa, la agenda vuelve a proyectarse")
        }
        XCTAssertEqual(CalendarProjection.make(task: running, session: session, now: now, uptime: 1000), .remove)
    }

    /// The rolling copy mirrors the save in progress; a dated snapshot per day is what you can actually go back to.
    func testDailySnapshotIsTakenOncePerDayAndOldOnesArePruned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusDeskSnapshot-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore(url: dir.appendingPathComponent("workspace.json"))

        // Nothing saved yet: nothing to snapshot.
        XCTAssertNil(try store.createDailySnapshotIfNeeded())

        var workspace = Workspace()
        workspace.tasks = [FocusTask(title: "Grabar", minutes: 30)]
        try store.save(workspace)

        let day = Date()
        let first = try XCTUnwrap(try store.createDailySnapshotIfNeeded(at: day))
        XCTAssertTrue(first.lastPathComponent.hasPrefix("daily-"))
        // Same day, no second copy; the snapshot keeps the state from the start of the day.
        XCTAssertNil(try store.createDailySnapshotIfNeeded(at: day))

        // Even after a destructive save, the snapshot still holds the tasks.
        var emptied = workspace
        emptied.tasks = []
        try store.save(emptied)
        XCTAssertEqual(try store.load().tasks.count, 0)
        XCTAssertEqual(try store.validateBackup(at: first).tasks.count, 1)

        // Only the newest snapshots are kept.
        for offset in 1...5 {
            let other = Calendar.current.date(byAdding: .day, value: offset, to: day)!
            _ = try store.createDailySnapshotIfNeeded(at: other, keeping: 3)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.backupsDirectoryURL.path)
            .filter { $0.hasPrefix("daily-") }
        XCTAssertEqual(remaining.count, 3, "debería conservar solo las 3 copias diarias más recientes")
    }

    /// Dropping a block on the hourly grid used to ignore where you let go and always snap to `:00`.
    func testDroppedBlockLandsOnTheMinuteYouAimedAt() {
        let row = 60.0 // one point per minute, as the timeline draws it
        XCTAssertEqual(FocusRules.dropMinute(offset: 0, rowHeight: row), 0)
        XCTAssertEqual(FocusRules.dropMinute(offset: 7, rowHeight: row), 5)
        XCTAssertEqual(FocusRules.dropMinute(offset: 30, rowHeight: row), 30)
        XCTAssertEqual(FocusRules.dropMinute(offset: 47, rowHeight: row), 45)
        XCTAssertEqual(FocusRules.dropMinute(offset: 59.9, rowHeight: row), 55)
        // Never rolls over into the next hour, whatever comes in.
        XCTAssertEqual(FocusRules.dropMinute(offset: 600, rowHeight: row), 55)
        XCTAssertEqual(FocusRules.dropMinute(offset: -20, rowHeight: row), 0)
        // Works on a taller row too (zoomed timeline), and degrades safely.
        XCTAssertEqual(FocusRules.dropMinute(offset: 60, rowHeight: 120), 30)
        XCTAssertEqual(FocusRules.dropMinute(offset: 10, rowHeight: 0), 0)
        XCTAssertEqual(FocusRules.dropMinute(offset: .nan, rowHeight: row), 0)
        // Every result is a valid minute of the hour on a 5-minute grid.
        for offset in stride(from: -10.0, through: 80.0, by: 0.5) {
            let minute = FocusRules.dropMinute(offset: offset, rowHeight: row)
            XCTAssertTrue((0...55).contains(minute) && minute % 5 == 0, "minuto inválido \(minute) para \(offset)")
        }
    }

    /// Only one session can exist at a time, so a reminder must never offer to start the task already running.
    func testRunningTaskGetsNoReminderWhileOtherTasksKeepTheirs() {
        let now = Date()
        let running = FocusTask(title: "Grabar", scheduledAt: now.addingTimeInterval(1800), minutes: 60, leadMinutes: 10)
        let other = FocusTask(title: "Editar", scheduledAt: now.addingTimeInterval(3600), minutes: 45, leadMinutes: 10)
        let planned = ReminderPlan.make(tasks: [running, other], sessionTaskID: running.id, now: now)
        XCTAssertTrue(planned.allSatisfy { $0.taskID != running.id }, "la tarea en sesión no debe tener avisos")
        // The other task still gets both reminders, which is why starting it has to offer an explicit hand-off.
        XCTAssertEqual(planned.filter { $0.taskID == other.id }.map(\.kind).sorted { $0.rawValue < $1.rawValue },
                       [.before, .start])
    }
}
