import XCTest
@testable import FocusCore

/// FD-13: `--preview` separaba los datos, pero las preferencias eran las de la app real. Al sacar capturas para la
/// revisión cambió la vista de Hoy de la app de verdad.
final class PreferencesTests: XCTestCase {
    func testTheRealAppUsesItsOwnPreferences() {
        XCTAssertTrue(AppPreferences.store(demo: false) === UserDefaults.standard)
    }

    func testTheDemoDoesNotTouchTheRealPreferences() {
        let key = "FocusDesk.prueba-\(UUID().uuidString)"
        let demo = AppPreferences.store(demo: true)
        XCTAssertFalse(demo === UserDefaults.standard)
        demo.set(true, forKey: key)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        demo.removeObject(forKey: key)
    }

    func testEveryDemoStartsFromScratch() {
        let key = "FocusDesk.prueba-\(UUID().uuidString)"
        let first = AppPreferences.store(demo: true)
        first.set("algo", forKey: key)
        let second = AppPreferences.store(demo: true)
        XCTAssertNil(second.object(forKey: key), "lo que tocó la demostración anterior no se arrastra a la siguiente")
    }
}
