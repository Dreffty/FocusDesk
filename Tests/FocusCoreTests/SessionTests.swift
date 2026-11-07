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

    func testMonotonicDurationIsImmuneToSystemClockChanges() {
        // Start session at wall clock `zero` and monotonic uptime `1000`
        var s = WorkSession(task: FocusTask(title: "Vídeo", minutes: 60), now: zero, uptime: 1000)
        // System clock jumps forward by 2 hours (+7200s), but only 45s of monotonic time elapsed
        let jumpedForwardWallClock = zero.addingTimeInterval(7200)
        XCTAssertEqual(s.elapsed(at: jumpedForwardWallClock, uptime: 1045), 45)
        // System clock jumps backward by 1 hour (-3600s), monotonic time is now 1120 (120s elapsed)
        let jumpedBackwardWallClock = zero.addingTimeInterval(-3600)
        XCTAssertEqual(s.elapsed(at: jumpedBackwardWallClock, uptime: 1120), 120)
        s.pause(at: jumpedBackwardWallClock, uptime: 1120)
        XCTAssertEqual(s.accumulated, 120)
    }

    func testContinuousDistractionCountsOnceUntilReturnToWork() {
        let allowedApp = AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
        let task = FocusTask(title: "Programar", apps: [allowedApp])
        var s = WorkSession(task: task, now: zero, uptime: 100)

        // Start in allowed app
        XCTAssertFalse(s.observeForeground(appID: "com.apple.dt.Xcode", name: "Xcode", allowed: true, at: zero, uptime: 100))
        XCTAssertEqual(s.interruptionCount, 0)

        // Switch to unallowed app: counts as 1st interruption
        XCTAssertTrue(s.observeForeground(appID: "com.apple.Music", name: "Music", title: "Canción 1", allowed: false, at: zero.addingTimeInterval(10), uptime: 110))
        XCTAssertEqual(s.interruptionCount, 1)

        // Remain in unallowed app across multiple periodic ticks and window title changes: still 1 interruption!
        XCTAssertFalse(s.observeForeground(appID: "com.apple.Music", name: "Music", title: "Canción 1", allowed: false, at: zero.addingTimeInterval(25), uptime: 125))
        XCTAssertFalse(s.observeForeground(appID: "com.apple.Music", name: "Music", title: "Canción 2", allowed: false, at: zero.addingTimeInterval(40), uptime: 140))
        XCTAssertFalse(s.observeForeground(appID: "com.apple.mail", name: "Mail", title: "Bandeja", allowed: false, at: zero.addingTimeInterval(55), uptime: 155))
        XCTAssertEqual(s.interruptionCount, 1)

        // Return to allowed app
        XCTAssertFalse(s.observeForeground(appID: "com.apple.dt.Xcode", name: "Xcode", allowed: true, at: zero.addingTimeInterval(70), uptime: 170))
        XCTAssertEqual(s.interruptionCount, 1)

        // Leave again later: counts as 2nd interruption
        XCTAssertTrue(s.observeForeground(appID: "com.apple.Music", name: "Music", allowed: false, at: zero.addingTimeInterval(90), uptime: 190))
        XCTAssertEqual(s.interruptionCount, 2)
    }

    func testStrictRedirectTrackerPausesAfterConsecutiveFailuresOrMissingApp() {
        var tracker = StrictRedirectTracker(maxConsecutiveFailures: 3, cooldown: 1.5)
        // Missing allowed app pauses immediately
        if case .pauseSession = tracker.evaluateUnallowed(hasRunningAllowedApp: false, at: zero) {} else {
            XCTFail("Expected pause when no allowed app is running")
        }

        // Consecutive failures without returning to allowed app eventually pause to avoid infinite loop
        XCTAssertEqual(tracker.evaluateUnallowed(hasRunningAllowedApp: true, at: zero), .redirect)
        tracker.recordRedirectAttempt()
        XCTAssertEqual(tracker.evaluateUnallowed(hasRunningAllowedApp: true, at: zero.addingTimeInterval(0.5)), .cooldown)
        XCTAssertEqual(tracker.evaluateUnallowed(hasRunningAllowedApp: true, at: zero.addingTimeInterval(2.0)), .redirect)
        tracker.recordRedirectAttempt()
        XCTAssertEqual(tracker.evaluateUnallowed(hasRunningAllowedApp: true, at: zero.addingTimeInterval(4.0)), .redirect)
        tracker.recordRedirectAttempt()
        if case .pauseSession = tracker.evaluateUnallowed(hasRunningAllowedApp: true, at: zero.addingTimeInterval(6.0)) {} else {
            XCTFail("Expected pause after 3 consecutive redirect failures")
        }
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

    func testActivityIntervalDurationAndAppSummaries() {
        var s = WorkSession(task: FocusTask(title: "Editar"), now: zero, uptime: 100)
        s.observeForeground(appID: "app.one", name: "App One", allowed: true, at: zero, uptime: 100)
        s.observeForeground(appID: "app.two", name: "App Two", allowed: true, at: zero.addingTimeInterval(30), uptime: 130)
        s.finish(at: zero.addingTimeInterval(100), uptime: 200)
        let record = SessionRecord(session: s, completed: true, note: "", changedFiles: [])
        XCTAssertEqual(record.observedSeconds, 100)
        XCTAssertEqual(record.appSummaries.first?.appID, "app.two")
        XCTAssertEqual(record.appSummaries.first?.seconds, 70)
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

    func testDomainMatchingAndURLNormalization() {
        XCTAssertEqual(FocusRules.normalizeDomains("https://claude.ai/, http://www.chatgpt.com/c/123?q=1, *.example.com"), "claude.ai, chatgpt.com, example.com")
        XCTAssertEqual(FocusRules.parseDomains("claude.ai, invalido_sin_punto").invalid, ["invalido_sin_punto"])
        XCTAssertTrue(FocusRules.domainAllowed("docs.example.com", list: "example.com, https://claude.ai/"))
        XCTAssertTrue(FocusRules.domainAllowed("CLAUDE.AI", list: "example.com https://claude.ai/login"))
        XCTAssertFalse(FocusRules.domainAllowed("notexample.com", list: "example.com"))
        XCTAssertFalse(FocusRules.domainAllowed("example.com.evil.test", list: "example.com"))
    }

    func testProfileApplicationPreservesCustomTitleAndAppliesConfig() {
        let profile = FocusProfile(
            name: "Grabar vídeo",
            category: "Contenido",
            minutes: 90,
            leadMinutes: 15,
            strict: true,
            apps: [AllowedApp(id: "com.lemon.lvoverseas", name: "CapCut", path: "/Applications/CapCut.app")],
            domains: "https://claude.ai/",
            folder: "/tmp/videos",
            checklist: "Guion\nTomas"
        )
        var task = FocusTask(title: "Vídeo especial de domingo")
        task.apply(profile)
        XCTAssertEqual(task.title, "Vídeo especial de domingo")
        XCTAssertEqual(task.category, "Contenido")
        XCTAssertEqual(task.minutes, 90)
        XCTAssertTrue(task.strict)
        XCTAssertEqual(task.domains, "claude.ai")
        XCTAssertEqual(task.folder, "/tmp/videos")
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
        XCTAssertFalse(FocusTask(title: "Video", repeatRule: .customDays, repeatDays: []).valid)
        let a = FocusTask(title: "A", scheduledAt: zero, minutes: 30)
        let adjacent = FocusTask(title: "B", scheduledAt: zero.addingTimeInterval(1800), minutes: 30)
        let overlap = FocusTask(title: "C", scheduledAt: zero.addingTimeInterval(1799), minutes: 30)
        XCTAssertFalse(FocusRules.overlaps(a, adjacent)); XCTAssertTrue(FocusRules.overlaps(a, overlap))
    }

    func testDetailRetentionKeepsSummary() {
        var state = Workspace()
        var session = WorkSession(task: FocusTask(title: "Vídeo"), now: zero)
        session.record(Activity(at: zero, appID: "app", name: "App", title: "Private", interruption: true))
        session.finish(at: zero.addingTimeInterval(600))
        state.history = [SessionRecord(session: session, completed: true, note: "Hecho", changedFiles: [])]
        state.prune(at: zero.addingTimeInterval(32 * 86400))
        XCTAssertTrue(state.history[0].session.activities.isEmpty)
        XCTAssertEqual(state.history[0].session.interruptionCount, 1)
        XCTAssertEqual(state.history[0].session.accumulated, 600)
        XCTAssertEqual(state.history[0].note, "Hecho")
    }

    func testStorageRoundTripLegacySchemaCompatibilityAndBackupRecovery() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceStore(url: folder.appendingPathComponent("state.json"))
        XCTAssertTrue(try store.load().tasks.isEmpty)

        // Verify legacy v0.2 JSON format (without new fields) decodes cleanly without losing anything
        let legacyJSON = """
        {
          "history" : [],
          "schema" : 1,
          "settings" : {
            "calendarID" : "80D4ACAD-AF3C-4D99-B828-258CAA5DD149",
            "detailDays" : 30,
            "observeBrave" : true,
            "observeTitles" : true
          },
          "tasks" : [
            {
              "apps" : [],
              "calendarEventID" : "FE43CE7E:BC4DBDD0",
              "calendarSnapshot" : {
                "allDay" : false,
                "end" : 814147836,
                "start" : 814147536,
                "title" : "Prueba de conexión · FocusDesk"
              },
              "category" : "Personal",
              "checklist" : "",
              "completed" : false,
              "domains" : "",
              "id" : "99912E1A-20CF-4918-A22F-BD9B8B42DE7A",
              "leadMinutes" : 1,
              "minutes" : 5,
              "repeatRule" : "never",
              "scheduledAt" : 814147536.96614,
              "strict" : false,
              "title" : "Prueba de conexión · FocusDesk"
            }
          ]
        }
        """
        try Data(legacyJSON.utf8).write(to: store.url)
        let decodedLegacy = try store.load()
        XCTAssertEqual(decodedLegacy.tasks.count, 1)
        XCTAssertEqual(decodedLegacy.tasks[0].title, "Prueba de conexión · FocusDesk")
        XCTAssertEqual(decodedLegacy.settings.calendarID, "80D4ACAD-AF3C-4D99-B828-258CAA5DD149")
        XCTAssertTrue(decodedLegacy.tasks[0].isScheduled)
        XCTAssertEqual(decodedLegacy.profiles.count, 3)

        var state = decodedLegacy
        state.session = WorkSession(task: state.tasks[0], now: zero)
        state.session?.finish(at: zero.addingTimeInterval(50))
        state.session?.finalChangedFiles = ["/result/video.mov"]
        state.session?.finalEvidenceMessage = "Metadatos disponibles"
        try store.save(state)
        XCTAssertEqual(try store.load().tasks, state.tasks)
        XCTAssertEqual(try store.load().session, state.session)

        // Corrupt primary file is not overwritten on load, and rolling backup recovers it
        let broken = Data("invalid".utf8)
        try broken.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), broken)

        let recovered = try store.recoverFromRollingBackup(at: zero)
        XCTAssertEqual(recovered.tasks, state.tasks)
    }
}
