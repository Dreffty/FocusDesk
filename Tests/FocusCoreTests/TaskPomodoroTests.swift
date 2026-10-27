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
