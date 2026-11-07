import XCTest
@testable import FocusCore

/// FD-12: las copias diarias copiaban el fichero sin comprobar que se leía, y solo se conservan las 14 últimas: dos semanas
/// de copias malas borraban todas las buenas. Es lo que pasó en octubre con la protección de datos de macOS 26.
final class DailySnapshotSafetyTests: XCTestCase {
    private var folder: URL!
    private var store: WorkspaceStore!
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("focusdesk-daily-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = WorkspaceStore(url: folder.appendingPathComponent("workspace.json"))
        var w = Workspace()
        w.tasks = [FocusTask(title: "Grabar", minutes: 30)]
        try store.save(w)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func date(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: day)! }

    private func name(_ offset: Int) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date(offset))
        return String(format: "daily-%04d-%02d-%02d.json", c.year!, c.month!, c.day!)
    }

    private var snapshots: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.backupsDirectoryURL.path)) ?? []).filter { $0.hasPrefix("daily-") }.sorted()
    }

    func testADamagedFileIsNotCopiedAndGoodCopiesStay() throws {
        for offset in 0..<3 { _ = try store.createDailySnapshotIfNeeded(at: date(offset), keeping: 3) }
        XCTAssertEqual(snapshots.count, 3)

        try Data("basura".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.createDailySnapshotIfNeeded(at: date(3), keeping: 3))
        XCTAssertEqual(snapshots, [name(0), name(1), name(2)], "ni copia nueva ni copias buenas borradas")
    }

    func testAPartlyReadableFileIsNotPassedOffAsACopy() throws {
        var w = Workspace()
        w.tasks = [FocusTask(title: "Sana", minutes: 20)]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as? [String: Any])
        json["tasks"] = (json["tasks"] as? [[String: Any]] ?? []) + [["title": 7]]
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)

        XCTAssertThrowsError(try store.createDailySnapshotIfNeeded(at: date(0)))
        XCTAssertTrue(snapshots.isEmpty, "le faltaría lo que no se pudo leer, y nadie se enteraría hasta necesitarla")
    }

    func testUnreadableCopiesDoNotPushOutGoodOnes() throws {
        for offset in 0..<5 { _ = try store.createDailySnapshotIfNeeded(at: date(offset), keeping: 100) }
        // Dos semanas de copias que han dejado de leerse, como pasó con macOS 26.
        for offset in 5..<19 {
            try Data("ilegible".utf8).write(to: store.backupsDirectoryURL.appendingPathComponent(name(offset)))
        }
        _ = try store.createDailySnapshotIfNeeded(at: date(19), keeping: 3)

        let kept = Set(snapshots)
        XCTAssertTrue(kept.contains(name(19)))
        XCTAssertTrue(kept.contains(name(4)), "de las buenas se conservan las más recientes")
        XCTAssertTrue(kept.contains(name(3)))
        XCTAssertFalse(kept.contains(name(2)), "con tres legibles, lo anterior ya sobra")
        XCTAssertFalse(kept.contains(name(0)))
    }

    func testACopyIsSelfContainedAndHoldsItsHistory() throws {
        var w = try store.load()
        var s = WorkSession(task: FocusTask(title: "Sesión", minutes: 20), now: day)
        s.finish(at: day.addingTimeInterval(60))
        w.history = [SessionRecord(session: s, completed: true, cancelled: false, note: "", changedFiles: [], confirmedFiles: [], manualFiles: [])]
        try store.save(w)

        let copy = try XCTUnwrap(try store.createDailySnapshotIfNeeded(at: date(0)))
        let read = try store.validateBackup(at: copy)
        XCTAssertEqual(read.history.count, 1)
        XCTAssertEqual(read.tasks.count, 1)
    }
}
