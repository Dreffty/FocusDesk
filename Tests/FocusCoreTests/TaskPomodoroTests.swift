import XCTest
@testable import FocusCore

final class TaskPomodoroTests: XCTestCase {
    private func task(minutes: Int = 120, work: Int = 25, pause: Int = 5, long: Int = 15, every: Int = 4) -> FocusTask {
        FocusTask(title: "Estudio", minutes: minutes, pomodoroWorkMinutes: work, pomodoroBreakMinutes: pause,
                  pomodoroLongBreakMinutes: long, pomodoroLongBreakEvery: every)
    }

    func testOneContinuousBlockHasNoPhase() {
        XCTAssertNil(FocusTask(title: "Bloque").pomodoroPhase(elapsed: 600))
    }

    func testAlternatesFocusAndBreak() {
        let t = task()
        let start = t.pomodoroPhase(elapsed: 0)
        XCTAssertEqual(start?.isBreak, false)
        XCTAssertEqual(start?.cycle, 1)
        XCTAssertEqual(start?.remainingInPhase, 25 * 60)

        let firstBreak = t.pomodoroPhase(elapsed: 25 * 60 + 60)
        XCTAssertEqual(firstBreak?.isBreak, true)
        XCTAssertEqual(firstBreak?.isLongBreak, false)
        XCTAssertEqual(firstBreak?.remainingInPhase, 4 * 60)

        let second = t.pomodoroPhase(elapsed: 30 * 60)
        XCTAssertEqual(second?.isBreak, false)
        XCTAssertEqual(second?.cycle, 2)
    }

    func testLongBreakAfterEveryFourthBlock() {
        let t = task()
        // Three cycles of 30 min, then the fourth focus block ends at 115 min.
        let afterFourth = t.pomodoroPhase(elapsed: 116 * 60)
        XCTAssertEqual(afterFourth?.isBreak, true)
        XCTAssertEqual(afterFourth?.isLongBreak, true)
        XCTAssertEqual(afterFourth?.cycle, 4)
        XCTAssertEqual(afterFourth?.label, "Descanso largo")
        XCTAssertEqual(t.pomodoroPhase(elapsed: 130 * 60)?.cycle, 5)
    }

    func testOldTasksDecodeWithoutPomodoro() throws {
        let json = #"{"title":"Antigua"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FocusTask.self, from: json)
        XCTAssertFalse(decoded.usesPomodoro)
        XCTAssertEqual(decoded.pomodoroBreakMinutes, 5)
    }

    func testPomodoroSettingsSurviveSaving() throws {
        let original = task(work: 50, pause: 10)
        let decoded = try JSONDecoder().decode(FocusTask.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.pomodoroWorkMinutes, 50)
        XCTAssertEqual(decoded.pomodoroBreakMinutes, 10)
    }
}

final class TaskPomodoroCalendarTests: XCTestCase {
    private func projected(at minutes: Double) -> CalendarSnapshot? {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let task = FocusTask(title: "Estudio", scheduledAt: start, minutes: 120, pomodoroWorkMinutes: 25, pomodoroBreakMinutes: 5)
        let session = WorkSession(task: task, now: start)
        guard case .event(let snapshot) = CalendarProjection.make(task: task, session: session, now: start.addingTimeInterval(minutes * 60)) else { return nil }
        return snapshot
    }

    func testFocusBlockEndsWhereTheBlockEnds() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snapshot = projected(at: 10)
        XCTAssertEqual(snapshot?.title, "Foco 1 · Estudio")
        XCTAssertEqual(snapshot?.end, start.addingTimeInterval(25 * 60))
    }

    func testBreakShowsAsItsOwnCountdown() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let snapshot = projected(at: 26)
        XCTAssertEqual(snapshot?.title, "Descanso · Estudio")
        XCTAssertEqual(snapshot?.end, start.addingTimeInterval(30 * 60))
    }

    func testPlainTaskKeepsItsWholeDuration() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let task = FocusTask(title: "Bloque", scheduledAt: start, minutes: 60)
        let session = WorkSession(task: task, now: start)
        guard case .event(let snapshot) = CalendarProjection.make(task: task, session: session, now: start.addingTimeInterval(600)) else { return XCTFail() }
        XCTAssertEqual(snapshot.title, "Bloque")
        XCTAssertEqual(snapshot.end, start.addingTimeInterval(3600))
    }
}
