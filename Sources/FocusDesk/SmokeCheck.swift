import AppKit
import Foundation
import FocusCore

/// Opt-in integration check inside the real app bundle, using temporary data only.
@MainActor
enum SmokeCheck {
    static func run(_ model: AppModel, statusVisible: Bool) async -> String {
        do {
            guard model.preview else { throw Failure.message("Smoke check requires --preview") }
            guard NSApp.activationPolicy() == .regular else { throw Failure.message("Dock activation policy") }
            guard statusVisible else { throw Failure.message("Status item not visible") }
            let folder = model.store.url.deletingLastPathComponent().appendingPathComponent("results")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let task = FocusTask(title: "Prueba automática aislada", scheduledAt: Date().addingTimeInterval(600), minutes: 1, folder: folder.path, checklist: "Guardar resultado", repeatRule: .daily)
            model.saveTask(task)
            model.start(task)
            try await idle(model)
            guard model.session?.task.id == task.id else { throw Failure.message("Start session") }
            model.pause()
            guard model.session?.paused == true else { throw Failure.message("Pause") }
            let elapsed = model.session!.accumulated
            try await Task.sleep(nanoseconds: 100_000_000)
            guard model.session!.elapsed(at: Date()) == elapsed else { throw Failure.message("Paused clock advanced") }
            model.resume(); model.addTime(); model.setCheck("0", value: true)
            guard model.session?.budget == 660 else { throw Failure.message("Extend budget") }
            try Data("resultado de prueba".utf8).write(to: folder.appendingPathComponent("resultado.txt"))
            model.finish(); try await idle(model)
            guard model.showCompletion, model.session?.endedAt != nil, model.changedFiles.count == 1 else { throw Failure.message("Finish or file evidence") }
            model.confirm(completed: true, note: "Comprobación automática")
            let restored = try model.store.load()
            guard restored.session == nil, restored.history.count == 1, restored.history[0].completed,
                  restored.history[0].changedFiles.count == 1, restored.tasks.count == 2,
                  restored.tasks.filter({ !$0.completed }).first!.scheduledAt > Date() else { throw Failure.message("Completion persistence or recurrence") }
            return "PASS: Dock regular; status item visible; create; start; pause; resume; extend; checklist; file evidence; finish; confirm; recurrence; persisted history."
        } catch { return "FAIL: \(error.localizedDescription)" }
    }
    private static func idle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.message("Timed out waiting for file scanner")
    }
    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
