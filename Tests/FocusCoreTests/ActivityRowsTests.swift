import XCTest
@testable import FocusCore

/// FD-07: en el navegador cada 5 s se añadían dos filas, una con dominio y otra sin él, y workspace.json pesaba 900 KB
/// con solo 10 sesiones. Filas seguidas de la misma app y el mismo dominio son una sola.
final class ActivityRowsTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)
    let brave = "com.brave.Browser"

    private func tick(_ s: inout WorkSession, second: Int, host: String?, app: String? = nil, title: String? = nil, status: String? = "sin permiso de Accesibilidad") {
        let at = zero.addingTimeInterval(Double(second))
        let appID = app ?? brave
        s.observeForeground(appID: appID, name: appID, title: title, titleStatus: status, allowed: true, at: at, uptime: Double(second))
        if let host {
            s.recordVisit(appID: appID, name: appID, domain: host, interruption: false, at: at.addingTimeInterval(0.2), uptime: Double(second) + 0.2)
        }
    }

    func testTenMinutesOnTheSameWebIsOneRow() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        for second in stride(from: 0, to: 600, by: 5) { tick(&s, second: second, host: "youtube.com") }
        s.checkpoint(at: zero.addingTimeInterval(600), uptime: 600)

        XCTAssertEqual(s.activities.count, 1, "en la prueba de la revisión salían 240 filas")
        XCTAssertEqual(s.activities[0].domain, "youtube.com")
        XCTAssertEqual(s.activities[0].duration, 600, accuracy: 0.5)
    }

    func testANewWebIsANewRow() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        for second in stride(from: 0, to: 30, by: 5) { tick(&s, second: second, host: "youtube.com") }
        for second in stride(from: 30, to: 60, by: 5) { tick(&s, second: second, host: "claude.ai") }
        XCTAssertEqual(s.activities.map(\.domain), ["youtube.com", "claude.ai"])
    }

    func testAnotherAppIsANewRowAndComingBackAddsOnlyOne() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        for second in stride(from: 0, to: 15, by: 5) { tick(&s, second: second, host: "youtube.com") }
        for second in stride(from: 15, to: 30, by: 5) { tick(&s, second: second, host: nil, app: "com.apple.dt.Xcode") }
        for second in stride(from: 30, to: 45, by: 5) { tick(&s, second: second, host: "youtube.com") }
        XCTAssertEqual(s.activities.map(\.appID), [brave, "com.apple.dt.Xcode", brave])
        XCTAssertEqual(s.activities[2].domain, "youtube.com", "la fila recién abierta recibe su dominio; no hay una más sin él")
    }

    func testABrowserOnAPageWithoutAddressKeepsItsOwnRow() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        for second in stride(from: 0, to: 60, by: 5) { tick(&s, second: second, host: nil) }
        tick(&s, second: 60, host: "youtube.com")
        XCTAssertEqual(s.activities.map(\.domain), [nil, "youtube.com"], "un minuto en una pestaña interna no se le atribuye a la web siguiente")
        XCTAssertEqual(s.activities[0].duration, 60, accuracy: 0.5)
    }

    func testARowWithoutAddressPermissionDoesNotAlternateEither() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        for second in stride(from: 0, to: 60, by: 5) {
            let at = zero.addingTimeInterval(Double(second))
            s.observeForeground(appID: brave, name: "Brave", titleStatus: "sin permiso de Accesibilidad", allowed: true, at: at, uptime: Double(second))
            if s.activities.last?.domainStatus != "sin permiso" {
                s.record(Activity(at: at, appID: brave, name: "Brave", domainStatus: "sin permiso"), at: at, uptime: Double(second))
            }
        }
        XCTAssertLessThanOrEqual(s.activities.count, 2)
    }

    func testAVisitThatInterruptsIsCountedOncePerVisit() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        tick(&s, second: 0, host: nil)
        s.recordVisit(appID: brave, name: "Brave", domain: "youtube.com", interruption: true, at: zero.addingTimeInterval(1), uptime: 1)
        XCTAssertEqual(s.interruptionCount, 1)
        XCTAssertEqual(s.activities.count, 1)
        XCTAssertTrue(s.activities[0].interruption)

        // Otra ruta del mismo sitio cuenta como otra visita, sin otra fila.
        s.recordVisit(appID: brave, name: "Brave", domain: "youtube.com", interruption: true, at: zero.addingTimeInterval(6), uptime: 6)
        XCTAssertEqual(s.interruptionCount, 2)
        XCTAssertEqual(s.activities.count, 1)
    }

    func testNothingIsRecordedWhilePaused() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        s.pause(at: zero, uptime: 0)
        s.recordVisit(appID: brave, name: "Brave", domain: "youtube.com", interruption: true, at: zero, uptime: 0)
        XCTAssertTrue(s.activities.isEmpty)
        XCTAssertEqual(s.interruptionCount, 0)
    }

    // MARK: - Los datos que ya existen

    func testOldHistoryIsFoldedWithoutLosingTime() {
        var s = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        s.activities = [
            Activity(at: zero, appID: brave, name: "Brave", duration: 0.2, titleStatus: "sin permiso de Accesibilidad"),
            Activity(at: zero, appID: brave, name: "Brave", domain: "youtube.com", duration: 5),
            Activity(at: zero, appID: brave, name: "Brave", duration: 0.2, titleStatus: "sin permiso de Accesibilidad"),
            Activity(at: zero, appID: brave, name: "Brave", domain: "youtube.com", interruption: true, duration: 5),
            Activity(at: zero, appID: "com.apple.dt.Xcode", name: "Xcode", title: "Uno", duration: 3),
            Activity(at: zero, appID: "com.apple.dt.Xcode", name: "Xcode", title: "Dos", duration: 3),
            Activity(at: zero, appID: brave, name: "Brave", duration: 0.2),
            Activity(at: zero, appID: brave, name: "Brave", domain: "claude.ai", duration: 5),
            Activity(at: zero, appID: brave, name: "Brave", domain: "youtube.com", duration: 5)
        ]
        let total = s.activities.reduce(0) { $0 + $1.duration }
        let count = s.interruptionCount

        s.foldActivities()

        XCTAssertEqual(s.activities.map(\.domain), ["youtube.com", nil, nil, "claude.ai", "youtube.com"])
        XCTAssertEqual(s.activities.map(\.title), [nil, "Uno", "Dos", nil, nil], "títulos distintos en otra app siguen siendo filas distintas")
        XCTAssertTrue(s.activities[0].interruption)
        XCTAssertEqual(s.activities.reduce(0) { $0 + $1.duration }, total, accuracy: 0.001)
        XCTAssertEqual(s.interruptionCount, count)

        let once = s.activities
        s.foldActivities()
        XCTAssertEqual(s.activities, once, "repetirlo no cambia nada")
    }

    func testPruneFoldsTheHistoryAndTheRunningSession() {
        var workspace = Workspace()
        var record = WorkSession(task: FocusTask(title: "Estudiar", minutes: 60), now: zero, uptime: 0)
        record.activities = [
            Activity(at: zero, appID: brave, name: "Brave", duration: 1),
            Activity(at: zero, appID: brave, name: "Brave", domain: "youtube.com", duration: 5)
        ]
        record.finish(at: zero, uptime: 0)
        workspace.history = [SessionRecord(session: record, completed: true, cancelled: false, note: "", changedFiles: [], confirmedFiles: [], manualFiles: [])]
        workspace.session = record
        workspace.prune(at: zero)
        XCTAssertEqual(workspace.history[0].session.activities.count, 1)
        XCTAssertEqual(workspace.session?.activities.count, 1)
    }
}
