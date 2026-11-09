import XCTest
@testable import FocusCore

/// Luis does not want FocusDesk's floating countdown in the top-right corner: countdowns belong in Vorssaint.
final class NoFloatingPillTests: XCTestCase {
    func testSettingsNoLongerCarryThePillSwitch() throws {
        let data = try JSONEncoder().encode(Settings())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("showFloatingTimerPill"))
    }

    func testOldSettingsWithThePillStillLoad() throws {
        let old = Data(#"{"showFloatingTimerPill": true}"#.utf8)
        XCTAssertNoThrow(try JSONDecoder().decode(Settings.self, from: old))
    }
}
