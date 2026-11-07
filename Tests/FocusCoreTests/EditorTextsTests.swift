import XCTest
@testable import FocusCore

/// D3 y D4: lo que el editor de tareas dice de lo que está plegado, y las etiquetas de las listas sin jerga.
final class EditorTextsTests: XCTestCase {
    let xcode = AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")
    let notes = AllowedApp(id: "com.apple.Notes", name: "Notas", path: "/System/Applications/Notes.app")

    // MARK: - D4: sin «lista blanca» ni «lista negra»

    func testAppListLabelsSayWhatYouCanUse() {
        XCTAssertEqual(AppListMode.allowListed.label, "Solo estas apps")
        XCTAssertEqual(AppListMode.blockListed.label, "Todas menos estas")
    }

    func testWebListLabelsSayWhatYouCanOpen() {
        XCTAssertEqual(WebListMode.allowListed.label, "Solo estas webs")
        XCTAssertEqual(WebListMode.blockListed.label, "Todas menos estas")
        XCTAssertEqual(WebListMode.blockAll.label, "Ninguna")
    }

    func testNoLabelUsesTheJargon() {
        let labels = AppListMode.allCases.flatMap { [$0.label, $0.shortLabel, $0.explanation] }
            + WebListMode.allCases.flatMap { [$0.label, $0.shortLabel] }
        for text in labels {
            XCTAssertFalse(text.lowercased().contains("lista"), text)
        }
    }

    // MARK: - D3: el resumen de «Bloqueo»

    func testATaskThatBlocksNothingSaysSo() {
        XCTAssertEqual(FocusTask(title: "Leer", minutes: 30).blockingSummary, "Sin bloqueo")
    }

    func testTheSummaryNamesWhatIsInside() {
        var t = FocusTask(title: "Estudiar", minutes: 30, strict: true, apps: [xcode, notes], domains: "claude.ai, chatgpt.com", protection: .challenge)
        t.webBlockAction = .redirect
        t.webListMode = .allowListed
        t.appListMode = .allowListed
        XCTAssertEqual(t.blockingSummary, "Solo 2 apps · Solo 2 webs · Teclear un código")

        t.appListMode = .blockListed
        t.apps = [xcode]
        t.webListMode = .blockListed
        t.domains = "youtube.com"
        XCTAssertEqual(t.blockingSummary, "Todas menos 1 app · Todas menos 1 web · Teclear un código")

        t.webListMode = .blockAll
        t.strict = false
        t.protection = .none
        t.blockGameLibraries = true
        t.blockedTitleKeywords = "poker, casino"
        t.blockedFolders = ["/tmp/series"]
        XCTAssertEqual(t.blockingSummary, "Juegos · Ninguna web · 2 palabras · 1 carpeta")
    }

    func testWebsOnlyWarnedAboutDoNotCountAsABlock() {
        var t = FocusTask(title: "Estudiar", minutes: 30, domains: "youtube.com")
        t.webBlockAction = .warn
        XCTAssertEqual(t.blockingSummary, "Sin bloqueo")
    }

    func testAnIncompleteBlockIsKnown() {
        var t = FocusTask(title: "Estudiar", minutes: 30, strict: true)
        XCTAssertTrue(t.blockingIsIncomplete, "bloquear apps sin decir cuáles no deja guardar")
        t.apps = [xcode]
        XCTAssertFalse(t.blockingIsIncomplete)
        t.webBlockAction = .redirect
        t.domains = ""
        XCTAssertTrue(t.blockingIsIncomplete, "bloquear webs sin decir cuáles tampoco")
        t.webListMode = .blockAll
        XCTAssertFalse(t.blockingIsIncomplete)
    }

    // MARK: - D3: «Resultado» y «Más opciones»

    func testTheResultSummary() {
        XCTAssertEqual(FocusTask(title: "Leer", minutes: 30).resultSummary, "Sin checklist")
        XCTAssertEqual(FocusTask(title: "Leer", minutes: 30, checklist: "Uno").resultSummary, "1 paso")
        XCTAssertEqual(FocusTask(title: "Leer", minutes: 30, folder: "/tmp/x", checklist: "Uno\n\nDos\n").resultSummary, "2 pasos · Carpeta elegida")
    }

    func testTheOptionsSummary() {
        var t = FocusTask(title: "Leer", category: "Contenido", minutes: 30)
        t.leadMinutes = 10
        XCTAssertEqual(t.optionsSummary, "Contenido · Avisa 10 min antes")
        t.repeatRule = .daily
        t.autoStart = true
        t.pomodoroWorkMinutes = 25
        t.dueDate = Date(timeIntervalSince1970: 1_000_000)
        t.isFixedAppointment = true
        XCTAssertEqual(t.optionsSummary, "Contenido · \(RepeatRule.daily.label) · Avisa 10 min antes · Empieza sola · Pomodoro · Fecha límite · Cita fija")
        t.isScheduled = false
        t.repeatRule = .never
        t.autoStart = false
        t.isFixedAppointment = false
        XCTAssertEqual(t.optionsSummary, "Contenido · Pomodoro · Fecha límite", "lo que solo tiene sentido con hora no se dice sin ella")
    }
}
