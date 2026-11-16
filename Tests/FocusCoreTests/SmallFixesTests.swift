import XCTest
@testable import FocusCore

/// Los fallos pequeños de la revisión del 7-nov, cada uno con la situación que lo dejaba ver.
final class SmallFixesTests: XCTestCase {

    // MARK: - FD-14: el vigilante no decodifica el fichero si no cambió

    func testTheWatcherOnlyDecodesTheFileWhenItChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("focusdesk-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkspaceStore(url: folder.appendingPathComponent("workspace.json"))
        var w = Workspace()
        w.tasks = [FocusTask(title: "Una", minutes: 20)]
        try store.save(w)

        let reader = WorkspaceWatchReader(store: store)
        XCTAssertEqual(reader.read()?.tasks.count, 1)
        XCTAssertEqual(reader.read()?.tasks.count, 1)
        XCTAssertEqual(reader.decodeCount, 1, "cada 2 s con la app cerrada, para nada")

        Thread.sleep(forTimeInterval: 0.02)
        w.tasks.append(FocusTask(title: "Dos", minutes: 20))
        try store.save(w)
        XCTAssertEqual(reader.read()?.tasks.count, 2)
        XCTAssertEqual(reader.decodeCount, 2)

        Thread.sleep(forTimeInterval: 0.02)
        try Data("basura".utf8).write(to: store.url)
        XCTAssertNil(reader.read(), "ilegible: no se inventa nada")
        XCTAssertNil(reader.read())
        XCTAssertEqual(reader.decodeCount, 3)
    }

    // MARK: - FD-15: udm=2 se lee de verdad

    func testGoogleOnlyCountsTheRealParameter() {
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=zapatos&udm=28"), "udm=28 es Shopping")
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=udm=2"), "es lo que se buscó, no un parámetro")
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=tbm=isch"))
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos&udm=70"))
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos#udm=2"))
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?udm=2&q=gatos"), "Google Imágenes")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.es", pathAndQuery: "/search?q=gatos&UDM=2"), "Google Imágenes")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos&tbm=isch"), "Google Imágenes")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos&udm=7"), "Google Vídeos")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos&udm=39"), "Google Vídeos")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=gatos&tbm=vid"), "Google Vídeos")
        XCTAssertEqual(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/imghp"), "Google Imágenes")
    }

    func testTheOtherSearchEnginesToo() {
        XCTAssertNil(SearchMediaRules.matches(host: "duckduckgo.com", pathAndQuery: "/?q=ia=images"))
        XCTAssertEqual(SearchMediaRules.matches(host: "duckduckgo.com", pathAndQuery: "/?q=gatos&ia=images&iax=images"), "DuckDuckGo Imágenes")
        XCTAssertEqual(SearchMediaRules.matches(host: "duckduckgo.com", pathAndQuery: "/?q=gatos&iax=videos"), "DuckDuckGo Vídeos")
        XCTAssertNil(SearchMediaRules.matches(host: "www.bing.com", pathAndQuery: "/search?q=ia=videos"))
        XCTAssertEqual(SearchMediaRules.matches(host: "www.bing.com", pathAndQuery: "/images/search?q=gatos"), "Bing Imágenes")
        XCTAssertNil(SearchMediaRules.matches(host: "search.yahoo.com", pathAndQuery: "/search?p=/search/images"))
        XCTAssertEqual(SearchMediaRules.matches(host: "search.yahoo.com", pathAndQuery: "/search/images?p=gatos"), "Yahoo Imágenes")
    }

    // MARK: - FD-16: la protección de portapapeles solo mira a FocusDesk

    private func clipboard(_ text: String) -> String? {
        ClipboardGuardRules.violation(in: text, domains: "", webListMode: .blockListed, webBlockAction: .warn)
    }

    func testCommandsAboutOtherAppsAreLeftAlone() {
        XCTAssertNil(clipboard("launchctl bootout gui/501/com.docker.vmnetd"))
        XCTAssertNil(clipboard("launchctl unload ~/Library/LaunchAgents/homebrew.mxcl.postgresql.plist"))
        XCTAssertNil(clipboard("launchctl remove com.spotify.webhelper"))
    }

    func testCommandsAboutFocusDeskAreStillCaught() {
        XCTAssertNotNil(clipboard("launchctl bootout gui/$(id -u)/com.articdia.focusdesk.guard"))
        XCTAssertNotNil(clipboard("launchctl unload ~/Library/LaunchAgents/com.articdia.focusdesk.guard.plist"))
        XCTAssertNotNil(clipboard("launchctl remove com.articdia.focusdesk.guard"))
        XCTAssertNotNil(clipboard("launchctl bootout gui/$(id -u)/local.focusdesk.guard"))
        XCTAssertNotNil(clipboard("sudo killall FocusDesk"))
        XCTAssertNotNil(clipboard("pkill -9 focusdesk"))
    }

    // MARK: - FD-18: la huella de las reglas incluye las apps

    func testEditingOnlyTheAppsOfAWitnessedRuleIsDetected() {
        let steam = AllowedApp(id: "com.valvesoftware.steam", name: "Steam", path: "/Applications/Steam.app")
        let rule = GeneralBlockRule(name: "Juegos", enabled: true, kind: .alwaysOn, blockApps: true, apps: [steam], protection: .challenge)
        var witness = ProtectedRulesWitness(rules: [rule], savedAt: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertTrue(witness.intact)

        witness.rules[0].apps = []
        XCTAssertFalse(witness.intact, "quitar Steam de la regla guardada no puede pasar desapercibido")

        var otherMode = ProtectedRulesWitness(rules: [rule])
        otherMode.rules[0].appListMode = .allowListed
        XCTAssertFalse(otherMode.intact)

        var noBlock = ProtectedRulesWitness(rules: [rule])
        noBlock.rules[0].blockApps = false
        XCTAssertFalse(noBlock.intact)
    }

    func testTheOrderOfTheAppsDoesNotMatter() {
        let a = AllowedApp(id: "a", name: "A", path: "/a"), b = AllowedApp(id: "b", name: "B", path: "/b")
        let rule = GeneralBlockRule(name: "Juegos", enabled: true, kind: .alwaysOn, blockApps: true, apps: [a, b], protection: .challenge)
        var witness = ProtectedRulesWitness(rules: [rule])
        witness.rules[0].apps = [b, a]
        XCTAssertTrue(witness.intact)
    }

    // MARK: - FD-20: el permiso de automatización dice para qué es

    func testTheAutomationPermissionNamesWhatItTalksTo() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let text = try XCTUnwrap(values["NSAppleEventsUsageDescription"] as? String)
        for name in ["Safari", "Chrome", "Brave", "Finder"] {
            XCTAssertTrue(text.contains(name), "el texto del permiso no menciona \(name): \(text)")
        }
    }

    // MARK: - FD-22: un intento que macOS da por bueno y no cambia de app cuenta igual

    func testEveryRedirectAttemptCountsUntilAnAllowedAppIsSeen() {
        var tracker = StrictRedirectTracker()
        tracker.recordRedirectAttempt()
        tracker.recordRedirectAttempt()
        XCTAssertEqual(tracker.consecutiveFailures, 2)
        tracker.registerAllowedAppObserved()
        XCTAssertEqual(tracker.consecutiveFailures, 0)
    }
}

/// D9: «325 min» se lee mejor como «5 h 25».
final class DurationTextTests: XCTestCase {
    func testLongDurationsReadAsHours() {
        XCTAssertEqual(FocusRules.durationText(minutes: 325), "5 h 25")
        XCTAssertEqual(FocusRules.durationText(minutes: 61), "1 h 01")
        XCTAssertEqual(FocusRules.durationText(minutes: 90), "1 h 30")
    }

    func testRoundHoursAndShortDurations() {
        XCTAssertEqual(FocusRules.durationText(minutes: 120), "2 h")
        XCTAssertEqual(FocusRules.durationText(minutes: 60), "1 h")
        XCTAssertEqual(FocusRules.durationText(minutes: 45), "45 min")
        XCTAssertEqual(FocusRules.durationText(minutes: 0), "0 min")
        XCTAssertEqual(FocusRules.durationText(minutes: -5), "0 min", "nunca una duración negativa")
    }
}
