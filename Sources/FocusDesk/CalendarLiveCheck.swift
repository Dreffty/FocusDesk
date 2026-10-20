import Foundation
import FocusCore
import EventKit

@MainActor
enum CalendarLiveCheck {
    static func run(_ model: AppModel) -> String {
        let bridge = model.calendar
        guard !model.preview, bridge.authorized, let calendarID = model.workspace.settings.calendarID,
              bridge.connected(calendarID)?.title == "FocusDesk" else { return "BLOCKED: calendar permission or dedicated calendar unavailable" }
        var task = FocusTask(title: "FocusDesk · comprobación temporal", scheduledAt: Date().addingTimeInterval(600), minutes: 5)
        var cleanupNeeded = false
        do {
            let planned = CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end)
            let created = try bridge.project(task, calendarID: calendarID, value: planned)
            task.calendarEventID = created.0; task.calendarSnapshot = created.1; cleanupNeeded = true
            guard let event = bridge.store.event(withIdentifier: created.0), planned.matches(created.1) else { throw Failure.failed("create/read") }
            // Simulate an external edit on this disposable event only.
            event.title = "Cambio externo de prueba"
            try bridge.store.save(event, span: .thisEvent, commit: true)
            var conflictDetected = false
            do { _ = try bridge.project(task, calendarID: calendarID, value: planned) }
            catch CalendarBridge.BridgeError.changed { conflictDetected = true }
            guard conflictDetected else { throw Failure.failed("external edit protection") }
            let restored = try bridge.project(task, calendarID: calendarID, value: planned, force: true)
            task.calendarSnapshot = restored.1
            let running = CalendarSnapshot(title: task.title, start: Date(), end: Date().addingTimeInterval(300))
            let started = try bridge.project(task, calendarID: calendarID, value: running)
            task.calendarSnapshot = started.1
            try bridge.remove(task, calendarID: calendarID)
            guard bridge.store.event(withIdentifier: task.calendarEventID!) == nil else { throw Failure.failed("pause removes event") }
            task.calendarEventID = nil; task.calendarSnapshot = nil
            let resumed = try bridge.project(task, calendarID: calendarID, value: running)
            task.calendarEventID = resumed.0; task.calendarSnapshot = resumed.1
            let finished = CalendarSnapshot(title: task.title, start: running.start, end: running.start.addingTimeInterval(1))
            let ended = try bridge.project(task, calendarID: calendarID, value: finished)
            task.calendarSnapshot = ended.1
            guard finished.matches(ended.1) else { throw Failure.failed("early finish") }
            try bridge.remove(task, calendarID: calendarID); cleanupNeeded = false
            return "PASS: EventKit create/read, external conflict protection, explicit resolution, start, pause/remove, resume/recreate, early finish, cleanup. Vorssaint visual display still requires observation."
        } catch {
            if cleanupNeeded { try? bridge.remove(task, calendarID: calendarID, force: true) }
            return "FAIL: \(error.localizedDescription)"
        }
    }
    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
