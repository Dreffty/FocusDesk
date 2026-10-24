import XCTest
@testable import FocusCore

/// Protection that starts before the task does, and folders that close when opened: the two pieces of FocusMe that
/// were still missing. Each test is a way out someone would try at 8:55 for a task that starts at 9:00.
final class RunUpAndFolderTests: XCTestCase {
    let nine = Date(timeIntervalSince1970: 1_800_000_000)

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
        XCTAssertEqual(RunUp.loosening(current: current, proposed: nil), "Borrarla")

        var inbox = current; inbox.isScheduled = false
        XCTAssertEqual(RunUp.loosening(current: current, proposed: inbox), "Pasarla a la bandeja")

        var done = current; done.completed = true
        XCTAssertEqual(RunUp.loosening(current: current, proposed: done), "Marcarla como hecha sin hacerla")

        var later = current; later.scheduledAt = nine.addingTimeInterval(10 * 60)
        XCTAssertEqual(RunUp.loosening(current: current, proposed: later), "Retrasarla")

        var manual = current; manual.autoStart = false
        XCTAssertEqual(RunUp.loosening(current: current, proposed: manual), "Quitarle el inicio automático")

        var skipped = current; skipped.skippedDates.insert(FocusRules.dayKey(for: nine))
        XCTAssertEqual(RunUp.loosening(current: current, proposed: skipped), "Saltársela")

        var softer = current; softer.protection = .none
        XCTAssertEqual(RunUp.loosening(current: current, proposed: softer), "Rebajar su protección")

        var shorter = current; shorter.minutes = 30
        XCTAssertEqual(RunUp.loosening(current: current, proposed: shorter), "Acortarla")
    }

    func testDoingItSoonerLongerOrStricterStaysFree() {
        let current = task(protection: .challenge)
        var earlier = current; earlier.scheduledAt = nine.addingTimeInterval(-15 * 60)
        XCTAssertNil(RunUp.loosening(current: current, proposed: earlier))
        var longer = current; longer.minutes = 90
        XCTAssertNil(RunUp.loosening(current: current, proposed: longer))
        var harder = current; harder.protection = .forced
        XCTAssertNil(RunUp.loosening(current: current, proposed: harder))
        var renamed = current; renamed.title = "Estudiar redes (tema 6)"
        XCTAssertNil(RunUp.loosening(current: current, proposed: renamed))
        var rounded = current; rounded.scheduledAt = nine.addingTimeInterval(20)
        XCTAssertNil(RunUp.loosening(current: current, proposed: rounded), "redondear la hora no es retrasarla")
        var moreFolders = current; moreFolders.blockedFolders = ["/tmp/series"]
        XCTAssertNil(RunUp.loosening(current: current, proposed: moreFolders))
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
