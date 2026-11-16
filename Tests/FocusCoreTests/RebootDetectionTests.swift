import XCTest
@testable import FocusCore

/// FD-04: el reinicio se detectaba mirando si el reloj interno iba por detrás del de cuando se empezó, y dejaba de
/// verse en cuanto el Mac llevaba encendido más tiempo que entonces: los temporizadores se alargaban.
final class RebootDetectionTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)

    func testARestartIsSeenEvenOnceTheMacHasBeenOnLongerThanBefore() {
        // Temporizador de 2 h empezado a los 5 min de encender. Se reinicia 25 min después.
        let deadline = TrustedDeadline(seconds: 7200, wall: zero, continuous: 300, bootID: "arranque-1")

        let oneMinuteAfterBoot = zero.addingTimeInterval(26 * 60)
        XCTAssertEqual(deadline.remainingAfterPossibleReboot(wall: oneMinuteAfterBoot, continuous: 60, bootID: "arranque-2"), 94 * 60, accuracy: 0.001)

        // A los 6 min de encender el reloj interno (360) ya va por delante del de entonces (300).
        let sixMinutesAfterBoot = zero.addingTimeInterval(31 * 60)
        XCTAssertTrue(deadline.rebooted(continuous: 360, bootID: "arranque-2"))
        XCTAssertEqual(deadline.remainingAfterPossibleReboot(wall: sixMinutesAfterBoot, continuous: 360, bootID: "arranque-2"), 89 * 60, accuracy: 0.001,
                       "quedan 89 min, no los 119 que decía el reloj interno")

        let past = zero.addingTimeInterval(121 * 60)
        XCTAssertEqual(deadline.elapsedSincePassed(wall: past, continuous: 600, bootID: "arranque-2"), 60, accuracy: 0.001)
    }

    func testWithoutARestartTheContinuousClockStillDecides() {
        let deadline = TrustedDeadline(seconds: 7200, wall: zero, continuous: 300, bootID: "arranque-1")
        XCTAssertFalse(deadline.rebooted(continuous: 360, bootID: "arranque-1"))
        // Mover la hora del Mac no cambia nada: el reloj interno manda.
        let movedForward = zero.addingTimeInterval(5 * 3600)
        XCTAssertEqual(deadline.remainingAfterPossibleReboot(wall: movedForward, continuous: 360, bootID: "arranque-1"), 7140, accuracy: 0.001)
    }

    func testOldDataWithoutTheBootIDStillLoadsAndUsesTheOldRule() throws {
        let json = """
        {"continuousEnd":7500,"wallEnd":\(zero.addingTimeInterval(7200).timeIntervalSinceReferenceDate),"anchorWall":\(zero.timeIntervalSinceReferenceDate),"anchorContinuous":300}
        """
        let deadline = try JSONDecoder().decode(TrustedDeadline.self, from: Data(json.utf8))
        XCTAssertNil(deadline.anchorBootID)
        XCTAssertTrue(deadline.rebooted(continuous: 60, bootID: "arranque-2"), "por debajo del reloj de entonces: reinicio")
        XCTAssertFalse(deadline.rebooted(continuous: 360, bootID: "arranque-2"), "sin el dato no se puede saber: como antes")
    }

    func testTheBootIDOfThisMacCanBeRead() {
        XCTAssertNotNil(TrustedClock.bootID)
        XCTAssertFalse(TrustedClock.bootID?.isEmpty ?? true)
        XCTAssertEqual(TrustedDeadline(seconds: 1).anchorBootID, TrustedClock.bootID)
    }

    func testTheBootIDSurvivesSavingAndLoading() throws {
        let deadline = TrustedDeadline(seconds: 7200, wall: zero, continuous: 300, bootID: "arranque-1")
        let loaded = try JSONDecoder().decode(TrustedDeadline.self, from: JSONEncoder().encode(deadline))
        XCTAssertEqual(loaded, deadline)
    }
}
