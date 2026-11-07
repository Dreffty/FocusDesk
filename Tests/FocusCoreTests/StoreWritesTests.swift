import XCTest
@testable import FocusCore

/// FD-08: con una regla encendida se reescribía todo cada minuto, en dos ficheros, con formato legible y desde el hilo
/// principal: hasta 2,6 GB al día. Y cada 10 s en el Llavero aunque nada cambiara.
final class StoreWritesTests: XCTestCase {
    private var folder: URL!
    private var store: WorkspaceStore!
    let zero = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("focusdesk-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = WorkspaceStore(url: folder.appendingPathComponent("workspace.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func workspace(tasks: Int = 1, sessions: Int = 2) -> Workspace {
        var w = Workspace()
        w.tasks = (0..<tasks).map { FocusTask(title: "Tarea \($0)", minutes: 20) }
        w.history = (0..<sessions).map { index in
            var s = WorkSession(task: FocusTask(title: "Sesión \(index)", minutes: 20), now: zero)
            s.finish(at: zero.addingTimeInterval(60))
            return SessionRecord(session: s, completed: true, cancelled: false, note: "", changedFiles: [], confirmedFiles: [], manualFiles: [])
        }
        return w
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    // MARK: - No escribir si no cambió

    func testSavingTheSameTwiceDoesNotTouchTheFiles() throws {
        let w = workspace()
        try store.save(w)
        let main = try modified(store.url), backup = try modified(store.backupURL), history = try modified(store.historyURL)
        Thread.sleep(forTimeInterval: 0.02)
        try store.save(w)
        XCTAssertEqual(try modified(store.url), main)
        XCTAssertEqual(try modified(store.backupURL), backup)
        XCTAssertEqual(try modified(store.historyURL), history)
    }

    func testAChangeIsWritten() throws {
        var w = workspace()
        try store.save(w)
        w.tasks[0].title = "Otra"
        try store.save(w)
        XCTAssertEqual(try store.load().tasks.first?.title, "Otra")
        XCTAssertEqual(try store.validateBackup(at: store.backupURL).tasks.first?.title, "Otra")
    }

    func testAFileDeletedOrEditedBehindItsBackIsWrittenAgain() throws {
        let w = workspace()
        try store.save(w)
        try FileManager.default.removeItem(at: store.url)
        try store.save(w)
        XCTAssertEqual(try store.load().tasks.count, 1, "no vale con recordar que ya estaba guardado")

        Thread.sleep(forTimeInterval: 0.02)
        try Data(#"{"schema":1,"tasks":[]}"#.utf8).write(to: store.url)
        try store.save(w)
        XCTAssertEqual(try store.load().tasks.count, 1, "editarlo con la app abierta no se queda")
    }

    // MARK: - JSON compacto

    func testTheFilesAreCompact() throws {
        try store.save(workspace())
        XCTAssertFalse(try Data(contentsOf: store.url).contains(UInt8(ascii: "\n")))
        XCTAssertFalse(try Data(contentsOf: store.historyURL).contains(UInt8(ascii: "\n")))
    }

    // MARK: - El historial en su fichero

    func testTheHistoryLivesInItsOwnFile() throws {
        let w = workspace()
        try store.save(w)
        let main = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        XCTAssertEqual((main?["history"] as? [Any])?.count, 0)
        let loaded = try store.load()
        XCTAssertEqual(loaded.history.map(\.id), w.history.map(\.id))
        XCTAssertEqual(loaded.tasks, w.tasks)
    }

    func testAChangedTaskDoesNotRewriteTheHistory() throws {
        var w = workspace()
        try store.save(w)
        let history = try modified(store.historyURL)
        Thread.sleep(forTimeInterval: 0.02)
        w.tasks[0].title = "Otra"
        try store.save(w)
        XCTAssertEqual(try modified(store.historyURL), history)
    }

    func testAnOldFileWithTheHistoryInsideStillLoadsAndMoves() throws {
        let w = workspace()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(w).write(to: store.url)

        let old = try store.load()
        XCTAssertEqual(old.history.map(\.id), w.history.map(\.id))

        try store.save(old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.historyURL.path))
        XCTAssertEqual(try store.load().history.map(\.id), w.history.map(\.id))
    }

    func testAHistoryInsideTheMainFileWinsOverAStaleSidecar() throws {
        try store.save(workspace(sessions: 1))
        // Una copia antigua puesta a mano en su sitio trae su historial dentro.
        let full = workspace(sessions: 3)
        try JSONEncoder().encode(full).write(to: store.url)
        XCTAssertEqual(try store.load().history.map(\.id), full.history.map(\.id))
    }

    func testAnExportIsOneSelfContainedFile() throws {
        let w = workspace()
        let export = WorkspaceStore(url: folder.appendingPathComponent("FocusDesk-backup.json"))
        try export.save(w, rollingBackup: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.historyURL.path))
        XCTAssertEqual(try export.validateBackup(at: export.url).history.map(\.id), w.history.map(\.id))
    }

    func testRestoringASelfContainedCopyBringsItsHistory() throws {
        let original = workspace(sessions: 3)
        let exported = WorkspaceStore(url: folder.appendingPathComponent("copia.json"))
        try exported.save(original, rollingBackup: false)
        try store.save(workspace(sessions: 1))

        let imported = try store.validateBackup(at: exported.url)
        let (restored, previous) = try store.restore(imported, at: zero)
        XCTAssertEqual(restored.history.count, 3)
        XCTAssertEqual(try store.load().history.count, 3)
        let before = try XCTUnwrap(previous)
        XCTAssertEqual(try store.validateBackup(at: before).history.count, 1, "la copia previa también lleva su historial")
    }

    // MARK: - Si algo se daña

    func testADamagedHistoryIsTakenFromItsCopy() throws {
        let w = workspace()
        try store.save(w)
        try Data("basura".utf8).write(to: store.historyURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded.history.map(\.id), w.history.map(\.id))
        XCTAssertEqual(loaded.tasks, w.tasks)
    }

    func testAHistoryDamagedBeyondItsCopyDoesNotLockTheAgendaAndIsKept() throws {
        let w = workspace()
        try store.save(w)
        try Data("basura".utf8).write(to: store.historyURL)
        try Data("basura".utf8).write(to: store.historyBackupURL)

        let loaded = try store.load()
        XCTAssertEqual(loaded.tasks, w.tasks)
        XCTAssertTrue(loaded.history.isEmpty)
        XCTAssertGreaterThan(loaded.decodingSkipped, 0, "así la app guarda el original antes de escribir encima")

        let kept = try XCTUnwrap(try store.createTimestampedBackup(prefix: "lectura-parcial", at: zero))
        let sidecar = URL(fileURLWithPath: kept.path + WorkspaceStore.keptHistorySuffix)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data("basura".utf8), "el historial dañado se conserva tal cual")
    }

    func testRecoveringFromTheRollingCopyKeepsTheHistory() throws {
        let w = workspace()
        try store.save(w)
        try Data("corrupt-json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        let recovered = try store.recoverFromRollingBackup(at: zero)
        XCTAssertEqual(recovered.history.map(\.id), w.history.map(\.id))
        XCTAssertEqual(recovered.tasks, w.tasks)
    }

    func testACrashBetweenTheTwoFilesDoesNotDuplicateASession() throws {
        // Se escribe primero el historial. Si se corta ahí, la sesión ya terminada sigue también en el fichero principal.
        var w = workspace()
        var finished = WorkSession(task: FocusTask(title: "Terminada", minutes: 20), now: zero)
        finished.finish(at: zero.addingTimeInterval(60))
        w.session = finished
        try store.save(w)
        w.history.insert(SessionRecord(session: finished, completed: true, cancelled: false, note: "", changedFiles: [], confirmedFiles: [], manualFiles: []), at: 0)
        try JSONEncoder().encode(WorkspaceStore.HistoryFile(records: w.history)).write(to: store.historyURL)
        let loaded = try store.load()
        XCTAssertNil(loaded.session)
        XCTAssertEqual(loaded.history.first?.id, finished.id)
    }

    func testTheWatcherCanReadWithoutTheHistory() throws {
        try store.save(workspace())
        XCTAssertTrue(try store.loadWithoutHistory().history.isEmpty)
    }

    // MARK: - Fuera del hilo principal

    func testBackgroundSavesLandInOrderAndANowSaveWaitsForThem() throws {
        let saver = WorkspaceSaver(store: store)
        var w = workspace()
        let done = expectation(description: "todas")
        done.expectedFulfillmentCount = 30
        for index in 0..<30 {
            w.tasks[0].title = "Versión \(index)"
            saver.saveInBackground(w) { error in
                XCTAssertNil(error)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(try store.load().tasks[0].title, "Versión 29")

        w.tasks[0].title = "Definitiva"
        saver.saveInBackground(w) { _ in }
        w.tasks[0].title = "Definitiva 2"
        try saver.saveNow(w)
        saver.waitForPendingWrites()
        XCTAssertEqual(try store.load().tasks[0].title, "Definitiva 2", "la que se guarda ahora es la última, no la que estaba en cola")
    }

    func testABackgroundFailureIsReported() throws {
        let saver = WorkspaceSaver(store: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let failed = expectation(description: "falla")
        saver.saveInBackground(workspace()) { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
    }

    // MARK: - El Llavero

    private func witness(_ id: UUID, end: TimeInterval, continuous: Double, protection: SessionProtection = .challenge, title: String = "Tarea") -> SessionWitness {
        SessionWitness(sessionID: id, taskTitle: title, protection: protection, deadline: TrustedDeadline(seconds: end, wall: zero, continuous: continuous, bootID: "a"))
    }

    func testTheSameRunningBlockIsNotWrittenAgain() {
        let id = UUID()
        let stored = witness(id, end: 3000, continuous: 100)
        // Diez segundos después: le quedan diez menos, y acaba a la misma hora.
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: 2990, continuous: 110)), .keep)
    }

    func testAnythingThatChangesIsWritten() {
        let id = UUID()
        let stored = witness(id, end: 3000, continuous: 100)
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: 3600, continuous: 110)), .save, "se alargó")
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(UUID(), end: 2990, continuous: 110)), .save, "otra sesión")
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: 2990, continuous: 110, protection: .forced)), .save)
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: 2990, continuous: 110, title: "Otro")), .save)
        XCTAssertEqual(WitnessPlan.action(stored: nil, desired: stored), .save)
        var otherBoot = witness(id, end: 3000, continuous: 100)
        otherBoot.deadline.anchorBootID = "b"
        XCTAssertEqual(WitnessPlan.action(stored: otherBoot, desired: stored), .save, "tras reiniciar el reloj interno no vale")
    }

    func testClearingOnlyWhenThereIsSomethingToClear() {
        XCTAssertEqual(WitnessPlan.action(stored: nil, desired: nil), .keep)
        XCTAssertEqual(WitnessPlan.action(stored: witness(UUID(), end: 60, continuous: 0), desired: nil), .clear)
    }

    func testAnOpenEndedRuleIsWrittenRarely() {
        let id = UUID()
        let horizon = WitnessPlan.openEndedHorizon
        let stored = witness(id, end: horizon, continuous: 0)
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: horizon, continuous: 600), tolerance: horizon / 2), .keep)
        XCTAssertEqual(WitnessPlan.action(stored: stored, desired: witness(id, end: horizon, continuous: horizon / 2 + 1), tolerance: horizon / 2), .save)
    }

    func testRulesAreOnlyWrittenWhenTheyChange() {
        let rules = [GeneralBlockRule(name: "Regla", enabled: true, kind: .alwaysOn)]
        XCTAssertTrue(WitnessPlan.rulesNeedSaving(rules, lastSaved: nil))
        XCTAssertFalse(WitnessPlan.rulesNeedSaving(rules, lastSaved: rules))
        var edited = rules
        edited[0].domains = "youtube.com"
        XCTAssertTrue(WitnessPlan.rulesNeedSaving(edited, lastSaved: rules))
    }
}
