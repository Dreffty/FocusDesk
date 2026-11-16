import XCTest
@testable import FocusCore

/// Protection that starts before the task does, and folders that close when opened: the two pieces of FocusMe that
/// were still missing. Each test is a way out someone would try at 8:55 for a task that starts at 9:00.
final class RunUpAndFolderTests: XCTestCase {
    let nine = Date(timeIntervalSince1970: 1_800_000_000)
    var fiveToNine: Date { nine.addingTimeInterval(-5 * 60) }

    private func task(protection: SessionProtection = .challenge, minutes: Int = 60, autoStart: Bool = false) -> FocusTask {
        FocusTask(
            title: "Estudiar redes",
            scheduledAt: nine,
            minutes: minutes,
            strict: true,
            apps: [AllowedApp(id: "com.apple.Preview", name: "Vista Previa", path: "/System/Applications/Preview.app")],
            autoStart: autoStart,
            protection: protection
        )
    }

    // MARK: - When it is armed

    func testArmedFromTheLeadUntilThePlannedEnd() {
        let t = task(minutes: 60)
        XCTAssertFalse(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(-11 * 60)), "antes del margen, libre")
        XCTAssertTrue(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(-10 * 60)), "al entrar en el margen")
        XCTAssertTrue(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(-60)))
        XCTAssertTrue(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(30 * 60)),
                      "pasada la hora sin empezarla sigue protegida: esperar a las 9:01 no es una salida")
        XCTAssertFalse(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(60 * 60)), "acabada su hora, libre")
    }

    func testNeverArmedWhenItCannotBeStoppedFreelyAnyway() {
        XCTAssertFalse(RunUp.isArmed(task(protection: .none), minutes: 10, now: nine.addingTimeInterval(-60)),
                       "«Se puede parar» no se protege antes de empezar")
        XCTAssertFalse(RunUp.isArmed(task(), minutes: 0, now: nine.addingTimeInterval(-60)), "0 minutos lo apaga")
        var inbox = task(); inbox.isScheduled = false
        XCTAssertFalse(RunUp.isArmed(inbox, minutes: 10, now: nine.addingTimeInterval(-60)))
        var done = task(); done.completed = true
        XCTAssertFalse(RunUp.isArmed(done, minutes: 10, now: nine.addingTimeInterval(-60)))
    }

    func testASessionStartedInTheWindowAlreadyPaid() {
        let t = task()
        let started = nine.addingTimeInterval(-2 * 60)
        XCTAssertFalse(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(5 * 60), sessionStarts: [started]),
                       "empezada y parada con su código: quitarla luego no cobra otra vez")
        let yesterday = nine.addingTimeInterval(-86_400)
        XCTAssertTrue(RunUp.isArmed(t, minutes: 10, now: nine.addingTimeInterval(-60), sessionStarts: [yesterday]),
                      "una sesión de otro día no cuenta")
    }

    // MARK: - What it refuses

    func testRefusesEveryWayOfPuttingItOff() {
        let current = task(autoStart: true)
        XCTAssertEqual(RunUp.loosening(current: current, proposed: nil, now: fiveToNine), "Borrarla")

        var inbox = current; inbox.isScheduled = false
        XCTAssertEqual(RunUp.loosening(current: current, proposed: inbox, now: fiveToNine), "Pasarla a la bandeja")

        var done = current; done.completed = true
        XCTAssertEqual(RunUp.loosening(current: current, proposed: done, now: fiveToNine), "Marcarla como hecha sin hacerla")

        var later = current; later.scheduledAt = nine.addingTimeInterval(10 * 60)
        XCTAssertEqual(RunUp.loosening(current: current, proposed: later, now: fiveToNine), "Retrasarla")

        var manual = current; manual.autoStart = false
        XCTAssertEqual(RunUp.loosening(current: current, proposed: manual, now: fiveToNine), "Quitarle el inicio automático")

        var skipped = current; skipped.skippedDates.insert(FocusRules.dayKey(for: nine))
        XCTAssertEqual(RunUp.loosening(current: current, proposed: skipped, now: fiveToNine), "Saltársela")

        var softer = current; softer.protection = .none
        XCTAssertEqual(RunUp.loosening(current: current, proposed: softer, now: fiveToNine), "Rebajar su protección")

        var shorter = current; shorter.minutes = 30
        XCTAssertEqual(RunUp.loosening(current: current, proposed: shorter, now: fiveToNine), "Acortarla")
    }

    /// FD-02: a las 8:55, adelantar a las 5:00 una tarea protegida de las 9:00 la dejaba fuera de su ventana, y
    /// entonces borrarla era gratis. Mover la hora al pasado es sacarla de su hora, no hacerla antes.
    func testMovingItIntoThePastCostsTheSameAsStoppingIt() {
        let current = task(minutes: 60)
        var finished = current; finished.scheduledAt = nine.addingTimeInterval(-4 * 3600)
        XCTAssertEqual(RunUp.loosening(current: current, proposed: finished, now: fiveToNine), "Sacarla de su hora",
                       "acabaría antes de ahora: al minuto siguiente borrarla sería gratis")

        var oneMinuteLeft = current; oneMinuteLeft.scheduledAt = fiveToNine.addingTimeInterval(-59 * 60)
        XCTAssertEqual(RunUp.loosening(current: current, proposed: oneMinuteLeft, now: fiveToNine), "Sacarla de su hora",
                       "no vale con que aún no haya terminado: bastaría con esperar un minuto")

        var stretchedBack = current; stretchedBack.scheduledAt = nine.addingTimeInterval(-4 * 3600); stretchedBack.minutes = 245
        XCTAssertEqual(RunUp.loosening(current: current, proposed: stretchedBack, now: fiveToNine), "Sacarla de su hora",
                       "alargarla a la vez que se mueve al pasado tampoco la deja a su hora")

        var running = task(minutes: 60)
        running.scheduledAt = nine.addingTimeInterval(-10 * 60)
        var evenEarlier = running; evenEarlier.scheduledAt = nine.addingTimeInterval(-40 * 60)
        XCTAssertEqual(RunUp.loosening(current: running, proposed: evenEarlier, now: nine), "Sacarla de su hora",
                       "una tarea cuya hora ya llegó tampoco se escapa moviéndola más atrás")
    }

    func testMovingItToATimeStillAheadStaysFree() {
        let current = task(minutes: 60)
        var soon = current; soon.scheduledAt = nine.addingTimeInterval(-2 * 60)
        XCTAssertNil(RunUp.loosening(current: current, proposed: soon, now: fiveToNine), "a las 8:58 sigue por delante")
        var rightNow = current; rightNow.scheduledAt = fiveToNine
        XCTAssertNil(RunUp.loosening(current: current, proposed: rightNow, now: fiveToNine), "empezarla ahora mismo es hacerla antes")
        var justPast = current; justPast.scheduledAt = fiveToNine.addingTimeInterval(-3 * 60)
        XCTAssertNil(RunUp.loosening(current: current, proposed: justPast, now: fiveToNine),
                     "unos minutos de margen: ponerla a la hora en que te has sentado no es escapar")
        var untouched = task(minutes: 60)
        untouched.scheduledAt = nine.addingTimeInterval(-30 * 60)
        var renamed = untouched; renamed.title = "Otro título"
        XCTAssertNil(RunUp.loosening(current: untouched, proposed: renamed, now: nine),
                     "si no se mueve, que su hora ya haya pasado no la encarece")
    }

    func testDoingItSoonerLongerOrStricterStaysFree() {
        let current = task(protection: .challenge)
        var earlier = current; earlier.scheduledAt = nine.addingTimeInterval(-15 * 60)
        XCTAssertNil(RunUp.loosening(current: current, proposed: earlier, now: nine.addingTimeInterval(-20 * 60)))
        var longer = current; longer.minutes = 90
        XCTAssertNil(RunUp.loosening(current: current, proposed: longer, now: fiveToNine))
        var harder = current; harder.protection = .forced
        XCTAssertNil(RunUp.loosening(current: current, proposed: harder, now: fiveToNine))
        var renamed = current; renamed.title = "Estudiar redes (tema 6)"
        XCTAssertNil(RunUp.loosening(current: current, proposed: renamed, now: fiveToNine))
        var rounded = current; rounded.scheduledAt = nine.addingTimeInterval(20)
        XCTAssertNil(RunUp.loosening(current: current, proposed: rounded, now: fiveToNine), "redondear la hora no es retrasarla")
        var moreFolders = current; moreFolders.blockedFolders = ["/tmp/series"]
        XCTAssertNil(RunUp.loosening(current: current, proposed: moreFolders, now: fiveToNine))
    }

    // MARK: - The ratchet and blocked folders

    func testRatchetRefusesUnblockingAFolderMidSession() {
        let current = FocusTask(title: "Estudiar", protection: .challenge, blockedFolders: ["/tmp/Series", "/tmp/Juegos"])
        var fewer = current; fewer.blockedFolders = ["/tmp/Series"]
        XCTAssertEqual(Ratchet.judge(current: current, proposed: fewer),
                       .refused("No se pueden desbloquear carpetas con la sesión en marcha. Bloquear más sí."))
        var more = current; more.blockedFolders = ["/tmp/series/", "/tmp/Juegos", "/tmp/Comics"]
        XCTAssertTrue(Ratchet.judge(current: current, proposed: more).isAccepted,
                      "la misma carpeta escrita distinto (mayúsculas, barra final) no es quitarla")
    }

    func testExistingRatchetMessagesAreUnchanged() {
        let current = task()
        var shorter = current; shorter.minutes = 30
        XCTAssertEqual(Ratchet.judge(current: current, proposed: shorter),
                       .refused("No se puede acortar la sesión en marcha. Alargarla sí."))
        var unblocked = current; unblocked.strict = false
        XCTAssertEqual(Ratchet.judge(current: current, proposed: unblocked),
                       .refused("No se puede quitar el bloqueo de apps mientras la sesión está en marcha."))
    }

    // MARK: - Folder rules

    func testFolderMatchingIsWholeFoldersAndIgnoresCase() {
        let folders = ["/Users/luis/Series"]
        XCTAssertEqual(FolderRules.blockingFolder(for: "/Users/luis/Series", in: folders), "/Users/luis/Series")
        XCTAssertNotNil(FolderRules.blockingFolder(for: "/Users/luis/series/T1/ep1.mp4", in: folders))
        XCTAssertNil(FolderRules.blockingFolder(for: "/Users/luis/Series 2/ep1.mp4", in: folders), "«Series 2» es otra carpeta")
        XCTAssertNil(FolderRules.blockingFolder(for: "/Users/luis", in: folders), "la carpeta de arriba no está bloqueada")
        XCTAssertNil(FolderRules.blockingFolder(for: "", in: folders))
    }

    func testSymlinkToABlockedFolderIsTheSameFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fd-folders-\(UUID().uuidString)")
        let real = base.appendingPathComponent("Series")
        let link = base.appendingPathComponent("atajo")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertNotNil(FolderRules.blockingFolder(for: link.appendingPathComponent("ep1.mp4").path, in: [real.path]),
                        "un enlace a la carpeta no la esquiva")
    }

    func testNormalizeCleansAndDeduplicates() {
        let home = NSHomeDirectory()
        XCTAssertEqual(FolderRules.normalize("~/Series/"), FolderRules.normalize(home + "/Series"))
        XCTAssertEqual(FolderRules.normalizeList(["/tmp/a", "/TMP/A", " ", "/tmp/a/"]).count, 1)
    }

    func testVitalFoldersCannotBeBlocked() {
        let home = "/Users/luis"
        for vital in ["/", "/Users", "/System", "/Applications", home, home + "/Library"] {
            XCTAssertNotNil(FolderRules.problem(with: vital, home: home), "\(vital) dejaría el Mac inutilizable")
        }
        XCTAssertNil(FolderRules.problem(with: home + "/Movies/Series", home: home))
        XCTAssertNotNil(FolderRules.problem(with: "  ", home: home))
    }

    func testOldDataWithoutTheNewFieldsStillLoads() throws {
        let json = #"{"title":"Antigua","protection":"challenge"}"#.data(using: .utf8)!
        let loaded = try JSONDecoder().decode(FocusTask.self, from: json)
        XCTAssertEqual(loaded.blockedFolders, [])
        let settings = try JSONDecoder().decode(Settings.self, from: #"{}"#.data(using: .utf8)!)
        XCTAssertEqual(settings.runUpMinutes, RunUp.defaultMinutes)
    }

    func testProfilesCarryTheirBlockedFolders() {
        let profile = FocusProfile(name: "Estudiar", blockedFolders: ["/tmp/Series"])
        var t = FocusTask(title: "")
        t.apply(profile)
        XCTAssertEqual(t.blockedFolders, FolderRules.normalizeList(["/tmp/Series"]))
        XCTAssertTrue(t.enforces, "una tarea que bloquea carpetas se vigila aunque no bloquee nada más")
    }
}
