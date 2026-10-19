import XCTest
@testable import FocusCore

final class SessionTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)
    func testPauseDoesNotCountBreakAndResumeIsIdempotent() {
        var s = WorkSession(task: FocusTask(title: "Vídeo", minutes: 60), now: zero)
        s.pause(at: zero.addingTimeInterval(900))
        XCTAssertEqual(s.elapsed(at: zero.addingTimeInterval(1200)), 900)
        s.pause(at: zero.addingTimeInterval(1400))
        s.resume(at: zero.addingTimeInterval(1800))
        s.resume(at: zero.addingTimeInterval(1900))
        XCTAssertEqual(s.elapsed(at: zero.addingTimeInterval(2000)), 1100)
    }
    func testEarlyFinishAndOvertimeAreDifferentFromCompletion() {
        var early = WorkSession(task: FocusTask(title: "Vídeo", minutes: 60), now: zero)
        early.finish(at: zero.addingTimeInterval(900))
        early.finish(at: zero.addingTimeInterval(1000))
        XCTAssertEqual(early.endedAt, zero.addingTimeInterval(900))
        XCTAssertEqual(early.accumulated, 900)
        XCTAssertEqual(early.task.minutes, 60)
        XCTAssertFalse(early.task.completed)
        early.resume(at: zero.addingTimeInterval(1000))
        XCTAssertTrue(early.paused)
        XCTAssertEqual(early.elapsed(at: zero.addingTimeInterval(4000)), 900)
        let late = WorkSession(task: FocusTask(title: "Estudiar", minutes: 1), now: zero)
        XCTAssertEqual(late.remaining(at: zero.addingTimeInterval(90)), -30)
        XCTAssertNil(late.endedAt)
        XCTAssertFalse(late.paused)
    }
    func testNoObservationDuringPauseOrAfterFinish() {
        var s = WorkSession(task: FocusTask(title: "Leer"), now: zero)
        let event = Activity(at: zero, appID: "browser", name: "Browser", interruption: true)
        s.record(event); s.pause(at: zero.addingTimeInterval(10)); s.record(event)
        XCTAssertEqual(s.activities.count, 1); XCTAssertEqual(s.interruptionCount, 1)
        s.resume(at: zero.addingTimeInterval(20)); s.finish(at: zero.addingTimeInterval(30)); s.record(event)
        XCTAssertEqual(s.activities.count, 1)
    }
    func testRecurrenceHasOwnIdentityAndKeepsWallTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))!
        var task = FocusTask(title: "Estudio", scheduledAt: date, repeatRule: .daily)
        task.completed = true; task.calendarEventID = "old"
        let next = try XCTUnwrap(task.nextOccurrence(calendar: calendar))
        XCTAssertNotEqual(next.id, task.id); XCTAssertNil(next.calendarEventID); XCTAssertFalse(next.completed)
        XCTAssertEqual(calendar.component(.hour, from: next.scheduledAt), 10)
        XCTAssertEqual(next.scheduledAt.timeIntervalSince(date), 25 * 3600)
    }
    func testDomainMatchingUsesBoundaries() {
        XCTAssertTrue(FocusRules.domainAllowed("docs.example.com", list: "example.com, claude.ai"))
        XCTAssertTrue(FocusRules.domainAllowed("CLAUDE.AI", list: "example.com claude.ai"))
        XCTAssertFalse(FocusRules.domainAllowed("notexample.com", list: "example.com"))
        XCTAssertFalse(FocusRules.domainAllowed("example.com.evil.test", list: "example.com"))
    }
    func testEvidenceIgnoresUnchangedAndDeletedFiles() {
        let old = FileStamp(modified: zero, bytes: 10)
        let new = FileStamp(modified: zero.addingTimeInterval(1), bytes: 10)
        XCTAssertEqual(FocusRules.changed(before: ["same": old, "modified": old, "deleted": old], after: ["same": old, "modified": new, "created": new]), ["created", "modified"])
    }
    func testTaskValidationAndAdjacentBlocks() {
        XCTAssertFalse(FocusTask(title: "  ").valid)
        XCTAssertFalse(FocusTask(title: "Video", minutes: 0).valid)
        XCTAssertFalse(FocusTask(title: "Video", strict: true).valid)
        let a = FocusTask(title: "A", scheduledAt: zero, minutes: 30)
        let adjacent = FocusTask(title: "B", scheduledAt: zero.addingTimeInterval(1800), minutes: 30)
        let overlap = FocusTask(title: "C", scheduledAt: zero.addingTimeInterval(1799), minutes: 30)
        XCTAssertFalse(FocusRules.overlaps(a, adjacent)); XCTAssertTrue(FocusRules.overlaps(a, overlap))
    }
    func testDetailRetentionKeepsSummary() {
        var state = Workspace()
        var session = WorkSession(task: FocusTask(title: "Vídeo"), now: zero)
        session.record(Activity(appID: "app", name: "App", title: "Private", interruption: true))
        session.finish(at: zero.addingTimeInterval(600))
        state.history = [SessionRecord(session: session, completed: true, note: "Hecho", changedFiles: [])]
        state.prune(at: zero.addingTimeInterval(32 * 86400))
        XCTAssertTrue(state.history[0].session.activities.isEmpty)
        XCTAssertEqual(state.history[0].session.interruptionCount, 1)
        XCTAssertEqual(state.history[0].session.accumulated, 600)
        XCTAssertEqual(state.history[0].note, "Hecho")
    }
    func testStorageRoundTripAndCorruptDataAreNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceStore(url: folder.appendingPathComponent("state.json"))
        XCTAssertTrue(try store.load().tasks.isEmpty)
        var state = Workspace(); state.tasks = [FocusTask(title: "Mi tarea")]
        state.session = WorkSession(task: state.tasks[0], now: zero)
        state.session?.finish(at: zero.addingTimeInterval(50))
        state.session?.finalChangedFiles = ["/result/video.mov"]
        state.session?.finalEvidenceMessage = "Metadatos disponibles"
        try store.save(state)
        XCTAssertEqual(try store.load().tasks, state.tasks)
        XCTAssertEqual(try store.load().session, state.session)
        let broken = Data("invalid".utf8); try broken.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), broken)
    }
}
