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

    /// Skipping one day used to freeze a series in the past for good: no reminder, no Calendar block, while the agenda
    /// still drew the following days. Rolling moves it to today and leaves the missed day behind as overdue.
    func testMissedDayRollsTheSeriesForwardAndKeepsTheMissedOccurrenceAsOverdue() throws {
        let cal = madrid()
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let wednesdayNoon = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        var series = FocusTask(title: "Estudiar", scheduledAt: monday, minutes: 45, repeatRule: .daily)
        series.calendarEventID = "evento-serie"

        // Before rolling, the series has no reminder at all on any later day: this is the bug.
        XCTAssertTrue(ReminderPlan.make(tasks: [series], sessionTaskID: nil, now: wednesdayNoon).isEmpty)

        let result = SeriesRoller.roll([series], sessionTaskID: nil, now: wednesdayNoon, calendar: cal)
        XCTAssertEqual(result.rolledSeriesIDs, [series.id])
        let head = try XCTUnwrap(result.tasks.first { $0.id == series.id })
        // Lands on today's occurrence (Wednesday 9:00), keeping its identity and its Calendar event to move.
        XCTAssertEqual(cal.component(.day, from: head.scheduledAt), 21)
        XCTAssertEqual(cal.component(.hour, from: head.scheduledAt), 9)
        XCTAssertEqual(head.repeatRule, .daily)
        XCTAssertEqual(head.calendarEventID, "evento-serie")

        // The missed Monday stays visible as one ordinary overdue task, tied to its series, without a Calendar event.
        XCTAssertEqual(result.createdOverdueIDs.count, 1)
        let missed = try XCTUnwrap(result.tasks.first { $0.id == result.createdOverdueIDs[0] })
        XCTAssertEqual(missed.repeatRule, .never)
        XCTAssertEqual(missed.seriesID, series.id)
        XCTAssertEqual(cal.component(.day, from: missed.scheduledAt), 19)
        XCTAssertNil(missed.calendarEventID)

        // Tomorrow's reminders exist again.
        let thursdayEarly = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 7))!
        let rolledAgain = SeriesRoller.roll(result.tasks, sessionTaskID: nil, now: thursdayEarly, calendar: cal)
        XCTAssertFalse(ReminderPlan.make(tasks: rolledAgain.tasks, sessionTaskID: nil, now: thursdayEarly).isEmpty)
        // Missing it again does not pile up a second overdue copy of the same series.
        XCTAssertTrue(rolledAgain.createdOverdueIDs.isEmpty)
        XCTAssertEqual(rolledAgain.tasks.filter { $0.repeatRule == .never && $0.seriesID == series.id }.count, 1)
    }

    /// What must NOT roll: today's occurrence (you can still do it), a completed one, the running session, and
    /// days the series skips on purpose.
    func testRollLeavesTodayCompletedSessionAndSkippedDaysAlone() throws {
        let cal = madrid()
        let wednesdayNoon = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        let todayAtNine = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 9))!
        let monday = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!

        let today = FocusTask(title: "Hoy pasada", scheduledAt: todayAtNine, minutes: 30, repeatRule: .daily)
        let done = FocusTask(title: "Hecha", scheduledAt: monday, minutes: 30, repeatRule: .daily, completed: true)
        let running = FocusTask(title: "En sesión", scheduledAt: monday, minutes: 30, repeatRule: .daily)
        let result = SeriesRoller.roll([today, done, running], sessionTaskID: running.id, now: wednesdayNoon, calendar: cal)
        XCTAssertTrue(result.rolledSeriesIDs.isEmpty)
        XCTAssertEqual(result.tasks, [today, done, running])

        // Weekly on Mondays, missed last Monday, today Wednesday: next occurrence is next Monday, not today.
        let weekly = FocusTask(title: "Semanal", scheduledAt: monday.addingTimeInterval(-7 * 86400), minutes: 30, repeatRule: .weekly)
        let weeklyRolled = try XCTUnwrap(SeriesRoller.roll([weekly], sessionTaskID: nil, now: wednesdayNoon, calendar: cal).tasks.first { $0.id == weekly.id })
        XCTAssertEqual(cal.component(.day, from: weeklyRolled.scheduledAt), 26)
        XCTAssertEqual(cal.component(.weekday, from: weeklyRolled.scheduledAt), 2)

        // A day detached from the series (skipped) is jumped over.
        var daily = FocusTask(title: "Diaria", scheduledAt: monday, minutes: 30, repeatRule: .daily)
        daily.skippedDates.insert("2026-10-21")
        let dailyRolled = try XCTUnwrap(SeriesRoller.roll([daily], sessionTaskID: nil, now: wednesdayNoon, calendar: cal).tasks.first { $0.id == daily.id })
        XCTAssertEqual(cal.component(.day, from: dailyRolled.scheduledAt), 22)
    }

    /// «He terminado» pulsado sin querer se puede deshacer: vuelve la cuenta atrás con lo ya trabajado, y el rato
    /// que estuvo parada no cuenta.
    func testReopeningAFinishedSessionKeepsWorkedTimeAndSkipsTheStop() {
        let start = Date()
        var session = WorkSession(task: FocusTask(title: "Grabar", minutes: 60), now: start, uptime: 100)
        session.finish(at: start.addingTimeInterval(600), uptime: 700)
        XCTAssertEqual(session.accumulated, 600, accuracy: 0.5)

        session.reopen(at: start.addingTimeInterval(900), uptime: 1000) // 5 minutes looking at the confirmation sheet
        XCTAssertNil(session.endedAt)
        XCTAssertFalse(session.paused)
        XCTAssertEqual(session.elapsed(at: start.addingTimeInterval(960), uptime: 1060), 660, accuracy: 0.5)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(960), uptime: 1060), 3600 - 660, accuracy: 0.5)

        // Reopening a session that is still running does nothing.
        let before = session
        session.reopen(at: start.addingTimeInterval(1000), uptime: 1100)
        XCTAssertEqual(session, before)
    }

    /// New fields must never make older files unreadable: one unknown key used to be enough to lock the whole agenda.
    func testOlderFilesWithoutAutoStartStillDecode() throws {
        let profileJSON = #"{"id":"11111111-1111-1111-1111-111111111101","name":"Grabar vídeo","category":"Contenido","minutes":60,"leadMinutes":10,"strict":false,"apps":[],"domains":"claude.ai","checklist":""}"#
        let profile = try JSONDecoder().decode(FocusProfile.self, from: Data(profileJSON.utf8))
        XCTAssertFalse(profile.autoStart)
        XCTAssertEqual(profile.domains, "claude.ai")

        let taskJSON = #"{"id":"22222222-2222-2222-2222-222222222222","title":"Estudiar","scheduledAt":782000000,"minutes":45}"#
        let task = try JSONDecoder().decode(FocusTask.self, from: Data(taskJSON.utf8))
        XCTAssertFalse(task.autoStart)

        var withAuto = task
        withAuto.autoStart = true
        let roundTrip = try JSONDecoder().decode(FocusTask.self, from: JSONEncoder().encode(withAuto))
        XCTAssertTrue(roundTrip.autoStart)

        var target = FocusTask(title: "x")
        target.apply(FocusProfile(name: "Auto", autoStart: true))
        XCTAssertTrue(target.autoStart, "aplicar un perfil con inicio automático debe activarlo en la tarea")
    }

    /// Overlapping tasks are laid out side by side instead of hiding each other.
    func testOverlappingBlocksGetTheirOwnColumns() {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let slots = TimelineLayout.columns(for: [
            .init(id: a, start: at(0), end: at(60)),     // 9:00-10:00
            .init(id: b, start: at(0), end: at(30)),     // 9:00-9:30, same start as a
            .init(id: c, start: at(30), end: at(90)),    // 9:30-10:30, reuses b's column
            .init(id: d, start: at(120), end: at(150)),  // 11:00, alone
            .init(id: e, start: at(150), end: at(155)),  // 11:30 for 5 min: touches d only through d's end
        ])
        XCTAssertEqual(slots[a]?.columns, 2)
        XCTAssertEqual(slots[b]?.columns, 2)
        XCTAssertEqual(slots[c]?.columns, 2)
        XCTAssertNotEqual(slots[a]?.column, slots[b]?.column)
        XCTAssertEqual(slots[c]?.column, slots[b]?.column, "c empieza cuando b acaba: comparte su columna")
        XCTAssertEqual(slots[d], TimelineLayout.Slot(column: 0, columns: 1))
        XCTAssertEqual(slots[e], TimelineLayout.Slot(column: 0, columns: 1))

        // A 10-minute task is drawn 30 minutes tall: another one 15 minutes later would be covered, so it gets a column.
        let short = UUID(), next = UUID()
        let tight = TimelineLayout.columns(for: [.init(id: short, start: at(0), end: at(10)), .init(id: next, start: at(15), end: at(45))])
        XCTAssertEqual(tight[short]?.columns, 2)
        XCTAssertEqual(tight[next]?.columns, 2)
        XCTAssertTrue(TimelineLayout.columns(for: []).isEmpty)
    }

    /// New tasks go to the first free slot of the day instead of all landing on 9:00.
    func testFirstFreeSlotFollowsTheDayAndStepsOverBreaks() {
        let cal = madrid()
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 0))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 18, minute: 7))!
        let lunch = BreakPeriod(title: "Comida", startHour: 14, startMinute: 0, durationMinutes: 60)
        func slot(_ tasks: [FocusTask]) -> DateComponents {
            cal.dateComponents([.day, .hour, .minute, .second], from:
                FocusRules.firstFreeSlot(on: tomorrow, tasks: tasks, breaks: [lunch], workStartHour: 9, now: now, calendar: cal))
        }
        // Empty day: start of the working day.
        XCTAssertEqual(slot([]).hour, 9)
        XCTAssertEqual(slot([]).minute, 0)
        // After the last pending task of that day.
        let first = FocusTask(title: "A", scheduledAt: cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 9))!, minutes: 50)
        XCTAssertEqual(slot([first]).hour, 9)
        XCTAssertEqual(slot([first]).minute, 50)
        // Completed tasks and other days do not count.
        var done = first; done.completed = true
        let otherDay = FocusTask(title: "B", scheduledAt: now, minutes: 600)
        XCTAssertEqual(slot([done, otherDay]).hour, 9)
        // Inside a break: moved to its end.
        let morning = FocusTask(title: "C", scheduledAt: cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12, minute: 30))!, minutes: 90)
        XCTAssertEqual(slot([morning]).hour, 15)
        XCTAssertEqual(slot([morning]).minute, 0)
        // Odd minutes are rounded up to the next 5.
        let odd = FocusTask(title: "D", scheduledAt: cal.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 10, minute: 3))!, minutes: 31)
        XCTAssertEqual(slot([odd]).minute, 35)
        XCTAssertEqual(slot([odd]).second, 0)
        // Today: never before ten minutes from now (18:07 + 10 = 18:17, rounded to 18:20).
        let today = cal.dateComponents([.hour, .minute], from:
            FocusRules.firstFreeSlot(on: now, tasks: [], breaks: [lunch], workStartHour: 9, now: now, calendar: cal))
        XCTAssertEqual(today.hour, 18)
        XCTAssertEqual(today.minute, 20)
    }

    /// Pruning the detailed activity after 30 days used to drop the per-app summary and the observed time to zero.
    func testHistoryKeepsAppSummariesAfterPruningAndShowsTheChecklist() throws {
        let old = Date().addingTimeInterval(-40 * 86400)
        var session = WorkSession(task: FocusTask(title: "Grabar", minutes: 60, checklist: "Guion\nTomas\nGuardar"), now: old, uptime: 0)
        session.record(Activity(at: old, appID: "com.lemon.lvoverseas", name: "CapCut"), at: old, uptime: 0)
        session.record(Activity(at: old.addingTimeInterval(1200), appID: "com.brave.Browser", name: "Brave"), at: old.addingTimeInterval(1200), uptime: 1200)
        session.checkpoint(at: old.addingTimeInterval(1500), uptime: 1500)
        session.checked = ["0", "2"]
        session.finish(at: old.addingTimeInterval(1500), uptime: 1500)
        var workspace = Workspace()
        workspace.history = [SessionRecord(session: session, completed: true, note: "", changedFiles: [])]
        let before = workspace.history[0].appSummaries

        workspace.prune(at: Date())
        let record = workspace.history[0]
        XCTAssertTrue(record.session.activities.isEmpty, "el detalle se borra pasados los días configurados")
        XCTAssertEqual(record.appSummaries, before, "pero el resumen por app se conserva")
        XCTAssertEqual(record.appSummaries.first?.name, "CapCut")
        XCTAssertEqual(record.observedSeconds, 1500, accuracy: 1)

        // It survives saving and loading, and older files without the new fields still decode.
        let reloaded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(reloaded.appSummaries, before)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacy.removeValue(forKey: "savedSummaries")
        legacy.removeValue(forKey: "savedObservedSeconds")
        let legacyRecord = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(legacyRecord.appSummaries.isEmpty)

        let steps = record.checklistSteps
        XCTAssertEqual(steps.map(\.text), ["Guion", "Tomas", "Guardar"])
        XCTAssertEqual(steps.map(\.done), [true, false, true])
    }

    /// Global shortcuts that override other apps' commands are retired; only three-modifier combinations remain.
    func testOnlySafeGlobalShortcutsAreOffered() {
        XCTAssertTrue(HotKeyPreset.presets.allSatisfy { !HotKeyPreset.isRetired(modifiers: $0.modifiers) })
        XCTAssertTrue(HotKeyPreset.isRetired(modifiers: 512 | 256), "⇧⌘ anulaba atajos de otras apps")
        XCTAssertTrue(HotKeyPreset.isRetired(modifiers: 2048 | 256), "⌥⌘ también")
        XCTAssertFalse(HotKeyPreset.isRetired(modifiers: 4096 | 2048 | 256))
        XCTAssertFalse(HotKeyPreset.presets.contains { $0.label == "⌃⌥⌘P" || $0.label == "⌃⌥⌘T" }, "no deben chocar con los atajos de sesión")
    }

    /// One unreadable task used to make the whole file unreadable, and the app read-only.
    func testOneBrokenElementDoesNotLockTheAgenda() throws {
        var workspace = Workspace()
        workspace.tasks = [FocusTask(title: "Buena 1", minutes: 30), FocusTask(title: "Buena 2", minutes: 45)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as! [String: Any]
        var tasks = json["tasks"] as! [[String: Any]]
        tasks.insert(["id": "no-es-un-uuid", "title": 42], at: 1)          // broken: wrong types
        json["tasks"] = tasks
        var history = (json["history"] as? [[String: Any]]) ?? []
        history.append(["session": "rota"])                                  // broken history record
        json["history"] = history

        let loaded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.tasks.map(\.title), ["Buena 1", "Buena 2"])
        XCTAssertEqual(loaded.decodingSkipped, 2)
        XCTAssertTrue(loaded.history.isEmpty)

        // A clean file reports nothing skipped, and the counter is never written to disk.
        let clean = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(clean.decodingSkipped, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(loaded), as: UTF8.self).contains("decodingSkipped"))
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

    /// Completing an occurrence creates a new head with a new id. Its series key must not change, or the days
    /// already detached from the series stop belonging to it.
    func testSeriesKeepsItsKeyAcrossCompletedOccurrences() throws {
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()))
        let first = FocusTask(title: "Estudiar", scheduledAt: start, minutes: 30, repeatRule: .daily)
        let (series, detached) = first.detachOccurrence(at: try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: start)))
        let second = try XCTUnwrap(series.nextOccurrence(after: start.addingTimeInterval(60)))
        let third = try XCTUnwrap(second.nextOccurrence(after: second.scheduledAt.addingTimeInterval(60)))
        XCTAssertEqual(detached.seriesID, first.id)
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.seriesID, first.id)
        XCTAssertEqual(third.seriesID, first.id)
        // A detached copy taken from a later head points at the same key.
        XCTAssertEqual(third.detachOccurrence(at: third.scheduledAt).detachedTask.seriesID, first.id)
    }

    /// An export goes where the user chose it, without leaving a `workspace.backup.json` next to it.
    func testExportDoesNotWriteARollingBackupBesideIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("focusdesk-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = WorkspaceStore(url: folder.appendingPathComponent("FocusDesk-backup.json"))
        try store.save(Workspace(), rollingBackup: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.backupURL.path))
        // The app's own file still keeps its rolling copy.
        try store.save(Workspace())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.backupURL.path))
    }
}
