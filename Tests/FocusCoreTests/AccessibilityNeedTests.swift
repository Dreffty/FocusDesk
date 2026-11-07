import XCTest
@testable import FocusCore

/// FD-06: sin el permiso de Accesibilidad parte del bloqueo no actúa, y la app solo lo decía con una etiqueta en
/// Ajustes. Esto decide qué se deja de hacer, en palabras, para decirlo en Hoy.
final class AccessibilityNeedTests: XCTestCase {
    private func task(
        protection: SessionProtection = .none,
        guardPanes: Bool = false,
        keywords: String = "",
        web: WebBlockAction = .warn,
        domains: String = "",
        searchMedia: Bool = false
    ) -> FocusTask {
        var t = FocusTask(title: "Estudiar", protection: protection)
        t.guardSystemPanes = guardPanes
        t.blockedTitleKeywords = keywords
        t.webBlockAction = web
        t.domains = domains
        t.blockSearchMedia = searchMedia
        return t
    }

    private func rule(
        protection: SessionProtection = .none,
        guardPanes: Bool = false,
        keywords: String = "",
        web: WebBlockAction = .warn,
        webMode: WebListMode = .blockListed,
        domains: String = ""
    ) -> GeneralBlockRule {
        GeneralBlockRule(
            name: "Regla",
            enabled: true,
            kind: .alwaysOn,
            webListMode: webMode,
            domains: domains,
            webBlockAction: web,
            blockedTitleKeywords: keywords,
            protection: protection,
            guardSystemPanes: guardPanes
        )
    }

    func testATaskThatBlocksNothingNeedsNothing() {
        XCTAssertEqual(AccessibilityNeed.features(of: task(), inspectEmbeddedPages: true), [])
    }

    func testEachThingThatStopsWorkingIsNamed() {
        XCTAssertEqual(AccessibilityNeed.features(of: task(keywords: "poker"), inspectEmbeddedPages: false),
                       [AccessibilityNeed.titleBlock])
        XCTAssertEqual(AccessibilityNeed.features(of: task(protection: .challenge, guardPanes: true), inspectEmbeddedPages: false),
                       [AccessibilityNeed.settingsGuard])
        XCTAssertEqual(AccessibilityNeed.features(of: task(web: .redirect, domains: "youtube.com"), inspectEmbeddedPages: false),
                       [AccessibilityNeed.otherBrowsers])
        XCTAssertEqual(AccessibilityNeed.features(of: task(web: .redirect, domains: "youtube.com"), inspectEmbeddedPages: true),
                       [AccessibilityNeed.otherBrowsers, AccessibilityNeed.embeddedPages])
    }

    func testPanesWithoutProtectionAndWebsOnlyWarnedAboutDoNotCount() {
        XCTAssertEqual(AccessibilityNeed.features(of: task(protection: .none, guardPanes: true), inspectEmbeddedPages: false), [],
                       "sin protección esa defensa no se aplica")
        XCTAssertEqual(AccessibilityNeed.features(of: task(web: .warn, domains: "youtube.com"), inspectEmbeddedPages: false), [],
                       "solo avisar no bloquea nada")
    }

    func testRulesCountTheSameWay() {
        XCTAssertEqual(AccessibilityNeed.features(of: rule(protection: .challenge, guardPanes: true), inspectEmbeddedPages: false),
                       [AccessibilityNeed.settingsGuard])
        XCTAssertEqual(AccessibilityNeed.features(of: rule(web: .redirect, domains: ""), inspectEmbeddedPages: false), [],
                       "una regla sin webs en la lista no bloquea ninguna")
        XCTAssertEqual(AccessibilityNeed.features(of: rule(web: .redirect, webMode: .blockAll), inspectEmbeddedPages: false),
                       [AccessibilityNeed.otherBrowsers])
    }

    func testTheMandatoryLoLRuleNeedsIt() {
        XCTAssertEqual(AccessibilityNeed.features(of: GeneralBlockRule.mandatoryStudyThenLoLRule, inspectEmbeddedPages: true),
                       [AccessibilityNeed.settingsGuard])
    }

    func testOnlyWhatIsActiveCounts() {
        var off = rule(keywords: "poker")
        off.enabled = false
        let on = rule(protection: .challenge, guardPanes: true)
        let features = AccessibilityNeed.features(session: nil, rules: [off, on], inspectEmbeddedPages: false)
        XCTAssertEqual(features, [AccessibilityNeed.settingsGuard], "una regla apagada no pide nada")
    }

    func testTheSessionAndTheRulesAreJoinedWithoutRepeats() {
        let features = AccessibilityNeed.features(
            session: task(protection: .challenge, guardPanes: true, keywords: "poker"),
            rules: [rule(protection: .challenge, guardPanes: true), rule(keywords: "casino")],
            inspectEmbeddedPages: false
        )
        XCTAssertEqual(features, [AccessibilityNeed.titleBlock, AccessibilityNeed.settingsGuard])
    }

    func testTheWarningSaysWhatStopsWorkingAndHowToFixIt() {
        XCTAssertNil(AccessibilityNeed.warning(for: []))
        let one = AccessibilityNeed.warning(for: [AccessibilityNeed.titleBlock])
        XCTAssertEqual(one, "Falta el permiso de Accesibilidad. Sin él no funciona \(AccessibilityNeed.titleBlock). Actívalo en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.")
        let many = AccessibilityNeed.warning(for: [AccessibilityNeed.titleBlock, AccessibilityNeed.settingsGuard, AccessibilityNeed.otherBrowsers])
        XCTAssertEqual(many, "Falta el permiso de Accesibilidad. Sin él no funcionan \(AccessibilityNeed.titleBlock), \(AccessibilityNeed.settingsGuard) y \(AccessibilityNeed.otherBrowsers). Actívalo en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.")
    }
}
