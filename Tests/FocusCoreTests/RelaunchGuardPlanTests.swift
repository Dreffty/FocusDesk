import XCTest
@testable import FocusCore

/// FD-05: una regla obligatoria 24/7 ponía el ajuste del vigilante en «sí», pero nadie lo instalaba: cerrar la app a la
/// fuerza desactivaba la regla y nadie volvía a abrirla.
final class RelaunchGuardPlanTests: XCTestCase {
    let home = "/Users/luis"

    func testItIsInstalledWhenTheSettingIsOnAndItIsMissing() {
        XCTAssertTrue(RelaunchGuardPlan.shouldInstall(settingOn: true, fileExists: false, runningInstalledApp: true, demo: false))
    }

    func testItIsLeftAloneOtherwise() {
        XCTAssertFalse(RelaunchGuardPlan.shouldInstall(settingOn: false, fileExists: false, runningInstalledApp: true, demo: false),
                       "apagado en Ajustes: es una decisión tuya")
        XCTAssertFalse(RelaunchGuardPlan.shouldInstall(settingOn: true, fileExists: true, runningInstalledApp: true, demo: false),
                       "ya está: quien lo apagó con launchctl sin borrar el fichero sigue teniendo su salida hasta reiniciar")
        XCTAssertFalse(RelaunchGuardPlan.shouldInstall(settingOn: true, fileExists: false, runningInstalledApp: false, demo: false),
                       "una copia de compilación no apunta el vigilante a sí misma")
        XCTAssertFalse(RelaunchGuardPlan.shouldInstall(settingOn: true, fileExists: false, runningInstalledApp: true, demo: true),
                       "el modo demostración no toca el vigilante de verdad")
    }

    func testOnlyTheAppFoldersCountAsInstalled() {
        XCTAssertTrue(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Applications/FocusDesk.app", home: home))
        XCTAssertTrue(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Users/luis/Applications/FocusDesk.app", home: home))
        XCTAssertFalse(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Users/luis/Downloads/FocusDesk/dist.noindex/FocusDesk.app", home: home))
        XCTAssertFalse(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Users/luis/Downloads/FocusDesk/.build/installed-backups/FocusDesk-previous-1.app", home: home))
        XCTAssertFalse(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Users/luis/Downloads/FocusDesk/.build/debug", home: home))
        XCTAssertFalse(RelaunchGuardPlan.isInstalledLocation(bundlePath: "/Applications Viejas/FocusDesk.app", home: home))
    }

    // MARK: - La salida de reiniciar el Mac no se toca

    let zero = Date(timeIntervalSince1970: 1_000_000)

    func testARuleNeverGetsInTheWayOfARestart() {
        let now = zero.addingTimeInterval(1000)
        XCTAssertFalse(
            RelaunchDecision.shouldRelaunch(
                session: nil, hasActiveProtectedRule: true, appRunning: false, watcherAge: 3600, recentRelaunches: 0,
                closedBySystemAt: now.addingTimeInterval(-20), now: now
            ),
            "macOS acaba de cerrarla para reiniciar: volver a abrirla estorbaría justo lo que tiene que funcionar siempre"
        )
    }

    func testARuleComesBackAfterTheRestartIsOverOrWasCalledOff() {
        let now = zero.addingTimeInterval(1000)
        XCTAssertTrue(RelaunchDecision.shouldRelaunch(
            session: nil, hasActiveProtectedRule: true, appRunning: false, watcherAge: 3600, recentRelaunches: 0,
            closedBySystemAt: now.addingTimeInterval(-600), now: now
        ))
        XCTAssertTrue(RelaunchDecision.shouldRelaunch(
            session: nil, hasActiveProtectedRule: true, appRunning: false, watcherAge: 3600, recentRelaunches: 0, now: now
        ), "cerrada a la fuerza, sin reinicio de por medio")
    }

    func testTheMarkOfASystemCloseSurvivesSavingAndOldDataLoads() throws {
        var workspace = Workspace()
        XCTAssertNil(workspace.closedBySystemAt)
        workspace.closedBySystemAt = zero
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(Workspace.self, from: encoder.encode(workspace))
        XCTAssertEqual(loaded.closedBySystemAt, zero)
        let old = try decoder.decode(Workspace.self, from: Data(#"{"schema":1}"#.utf8))
        XCTAssertNil(old.closedBySystemAt)
    }
}
