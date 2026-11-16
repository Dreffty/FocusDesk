import XCTest
@testable import FocusCore

/// FD-03: pasar de lista negra a lista blanca desbloqueaba justo lo que estaba bloqueado. La regla: antes de aceptar,
/// todo lo que hoy está bloqueado tiene que seguir bloqueado. Cada prueba es una forma de intentarlo.
final class ListModeRatchetTests: XCTestCase {
    let steam = AllowedApp(id: "com.valvesoftware.steam", name: "Steam", path: "/Applications/Steam.app")
    let xcode = AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")

    private func task(
        webMode: WebListMode = .blockListed,
        domains: String = "",
        appMode: AppListMode = .blockListed,
        apps: [AllowedApp] = [],
        strict: Bool = false
    ) -> FocusTask {
        FocusTask(
            title: "Estudiar",
            strict: strict,
            apps: apps,
            domains: domains,
            protection: .challenge,
            webBlockAction: .redirect,
            appListMode: appMode,
            webListMode: webMode
        )
    }

    private func rule(
        webMode: WebListMode = .blockListed,
        domains: String = "",
        appMode: AppListMode = .blockListed,
        apps: [AllowedApp] = [],
        blockApps: Bool = false
    ) -> GeneralBlockRule {
        GeneralBlockRule(
            name: "Regla",
            enabled: true,
            kind: .alwaysOn,
            blockApps: blockApps,
            appListMode: appMode,
            apps: apps,
            webListMode: webMode,
            domains: domains,
            webBlockAction: .redirect
        )
    }

    private func webChange(
        from: (WebListMode, String),
        to: (WebListMode, String),
        file: StaticString = #filePath,
        line: UInt = #line,
        refused: Bool
    ) {
        let currentTask = task(webMode: from.0, domains: from.1)
        var nextTask = currentTask
        nextTask.webListMode = to.0
        nextTask.domains = to.1
        XCTAssertEqual(Ratchet.loosening(current: currentTask, proposed: nextTask) != nil, refused, "tarea", file: file, line: line)

        let currentRule = rule(webMode: from.0, domains: from.1)
        var nextRule = currentRule
        nextRule.webListMode = to.0
        nextRule.domains = to.1
        XCTAssertEqual(GeneralBlockRule.loosening(current: currentRule, proposed: nextRule) != nil, refused, "regla", file: file, line: line)
    }

    // MARK: - Webs

    func testBlackToWhiteWithTheSameListIsRefused() {
        webChange(from: (.blockListed, "youtube.com"), to: (.allowListed, "youtube.com"), refused: true)
    }

    func testBlackToEmptyWhiteOpensEveryWebAndIsRefused() {
        webChange(from: (.blockListed, "youtube.com"), to: (.allowListed, ""), refused: true)
    }

    func testBlackToWhiteOverlappingIsRefused() {
        webChange(from: (.blockListed, "youtube.com"), to: (.allowListed, "m.youtube.com"), refused: true)
        webChange(from: (.blockListed, "youtube.com/shorts"), to: (.allowListed, "youtube.com"), refused: true)
        webChange(from: (.blockListed, "youtube.com"), to: (.allowListed, "youtube.com/watch"), refused: true)
        webChange(from: (.blockListed, "youtube.com/shorts"), to: (.allowListed, "m.youtube.com"), refused: true)
        webChange(from: (.blockListed, "x.com, youtube.com"), to: (.allowListed, "claude.ai, x.com"), refused: true)
    }

    func testBlackToWhiteWithSomethingElseOnlyHardensAndIsAccepted() {
        webChange(from: (.blockListed, "youtube.com"), to: (.allowListed, "claude.ai"), refused: false)
        webChange(from: (.blockListed, "youtube.com/shorts"), to: (.allowListed, "youtube.com/watch"), refused: false)
        webChange(from: (.blockListed, "m.youtube.com"), to: (.allowListed, "claude.ai, docs.swift.org"), refused: false)
    }

    func testWildcardsCannotBeUsedToSlipThrough() {
        webChange(from: (.blockListed, "*poker*.com"), to: (.allowListed, "pokerstars.com"), refused: true)
        webChange(from: (.blockListed, "pokerstars.com"), to: (.allowListed, "*.com"), refused: true)
        webChange(from: (.blockListed, "*poker*.com"), to: (.allowListed, "*stars*.com"), refused: true)
        webChange(from: (.blockListed, "*poker*.com"), to: (.allowListed, "claude.ai"), refused: false)
    }

    func testEmptyingAWhiteListOpensEveryWebAndIsRefused() {
        webChange(from: (.allowListed, "claude.ai"), to: (.allowListed, ""), refused: true)
    }

    func testHardeningToBlockAllIsAlwaysAccepted() {
        webChange(from: (.blockListed, "youtube.com"), to: (.blockAll, ""), refused: false)
        webChange(from: (.allowListed, "claude.ai"), to: (.blockAll, ""), refused: false)
    }

    func testWhenNothingWasBlockedAnyListIsFine() {
        webChange(from: (.blockListed, ""), to: (.allowListed, ""), refused: false)
        webChange(from: (.blockListed, ""), to: (.allowListed, "claude.ai"), refused: false)
        webChange(from: (.allowListed, ""), to: (.blockListed, "youtube.com"), refused: false)
    }

    func testTheOtherWaysStayRefused() {
        webChange(from: (.blockAll, ""), to: (.allowListed, "claude.ai"), refused: true)
        webChange(from: (.blockAll, ""), to: (.blockListed, "youtube.com"), refused: true)
        webChange(from: (.allowListed, "claude.ai"), to: (.blockListed, "youtube.com"), refused: true)
        webChange(from: (.allowListed, "claude.ai"), to: (.allowListed, "claude.ai, youtube.com"), refused: true)
        webChange(from: (.blockListed, "x.com, youtube.com"), to: (.blockListed, "x.com"), refused: true)
    }

    // MARK: - Apps

    private func appChange(
        from: (AppListMode, [AllowedApp]),
        to: (AppListMode, [AllowedApp]),
        file: StaticString = #filePath,
        line: UInt = #line,
        refused: Bool
    ) {
        let currentTask = task(appMode: from.0, apps: from.1, strict: true)
        var nextTask = currentTask
        nextTask.appListMode = to.0
        nextTask.apps = to.1
        XCTAssertEqual(Ratchet.loosening(current: currentTask, proposed: nextTask) != nil, refused, "tarea", file: file, line: line)

        let currentRule = rule(appMode: from.0, apps: from.1, blockApps: true)
        var nextRule = currentRule
        nextRule.appListMode = to.0
        nextRule.apps = to.1
        XCTAssertEqual(GeneralBlockRule.loosening(current: currentRule, proposed: nextRule) != nil, refused, "regla", file: file, line: line)
    }

    func testBlackToWhiteWithTheSameAppIsRefused() {
        appChange(from: (.blockListed, [steam]), to: (.allowListed, [steam]), refused: true)
    }

    func testBlackToEmptyWhiteLeavesEveryAppOpenAndIsRefused() {
        appChange(from: (.blockListed, [steam]), to: (.allowListed, []), refused: true)
    }

    func testBlackToWhiteWithOtherAppsOnlyHardensAndIsAccepted() {
        appChange(from: (.blockListed, [steam]), to: (.allowListed, [xcode]), refused: false)
    }

    func testEmptyingAWhiteListOfARuleOpensEveryAppAndIsRefused() {
        let current = rule(appMode: .allowListed, apps: [xcode], blockApps: true)
        var next = current
        next.apps = []
        XCTAssertNotNil(GeneralBlockRule.loosening(current: current, proposed: next),
                        "una regla sin apps no bloquea ninguna: vaciar la lista blanca la abre entera")
    }

    func testEmptyingAWhiteListOfATaskThatAlsoBlocksGamesIsRefused() {
        var current = task(appMode: .allowListed, apps: [xcode], strict: true)
        current.blockGameLibraries = true
        var next = current
        next.apps = []
        XCTAssertNotNil(Ratchet.loosening(current: current, proposed: next),
                        "bloquear los juegos no compensa abrir todas las demás apps")
    }

    func testTaskOnlyBlockingGamesCanStillHaveAnEmptyList() {
        var current = task(appMode: .allowListed, apps: [], strict: true)
        current.blockGameLibraries = true
        XCTAssertNil(Ratchet.loosening(current: current, proposed: current))
    }

    func testARuleThatBlocksNoAppsCanChangeItsListFreely() {
        let current = rule(appMode: .blockListed, apps: [steam], blockApps: false)
        var next = current
        next.appListMode = .allowListed
        next.apps = [steam]
        XCTAssertNil(GeneralBlockRule.loosening(current: current, proposed: next))
    }

    /// FD-17: con la tarea sin bloqueo de apps la lista no hace nada, así que tocarla no puede costar nada.
    func testATaskThatBlocksNoAppsCanChangeItsListFreely() {
        let current = task(appMode: .allowListed, apps: [xcode], strict: false)
        var next = current
        next.apps = [xcode, steam]
        XCTAssertNil(Ratchet.loosening(current: current, proposed: next))
        next.appListMode = .blockListed
        XCTAssertNil(Ratchet.loosening(current: current, proposed: next))
    }

    func testAStrictTaskStillRefusesMoreAllowedApps() {
        let current = task(appMode: .allowListed, apps: [xcode], strict: true)
        var next = current
        next.apps = [xcode, steam]
        XCTAssertEqual(Ratchet.loosening(current: current, proposed: next), .moreAllowedApps)
        next.apps = []
        XCTAssertEqual(Ratchet.loosening(current: current, proposed: next), .noAllowedApps)
    }

    // MARK: - Pieces

    func testEntriesOverlap() {
        XCTAssertTrue(FocusRules.domainEntriesOverlap("youtube.com", "youtube.com"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("youtube.com", "m.youtube.com"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("m.youtube.com", "youtube.com"))
        XCTAssertFalse(FocusRules.domainEntriesOverlap("notyoutube.com", "youtube.com"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("youtube.com/shorts", "youtube.com"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("youtube.com/shorts", "youtube.com/shorts/abc"))
        XCTAssertFalse(FocusRules.domainEntriesOverlap("youtube.com/shorts", "youtube.com/shortstop"))
        XCTAssertFalse(FocusRules.domainEntriesOverlap("youtube.com/shorts", "youtube.com/watch"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("*poker*.com", "pokerstars.com"))
        XCTAssertFalse(FocusRules.domainEntriesOverlap("*poker*.com", "claude.ai"))
        XCTAssertTrue(FocusRules.domainEntriesOverlap("*poker*.com", "*stars*"), "dos patrones: no se puede saber, así que se supone que sí")
    }
}
