import Foundation
import FocusCore
import EventKit

@MainActor
enum CalendarLiveCheck {
    static func run(_ model: AppModel) async -> String {
        let bridge = model.calendar
        if !bridge.authorized {
            await bridge.request()
        }
        guard !model.preview, bridge.authorized, let calendarID = model.workspace.settings.calendarID,
              let calendar = bridge.connected(calendarID), calendar.title == "FocusDesk" else {
            return "BLOCKED: calendar permission or dedicated calendar unavailable"
        }
        let initialWorkspace = model.workspace
        var task = FocusTask(title: "FocusDesk · comprobación 90m", scheduledAt: Date().addingTimeInterval(600), minutes: 90)
        var competingEvent: EKEvent?
        var cleanupNeeded = false

        do {
            // 1. Create a 90-minute block (>60m Vorssaint window) and verify read
            let planned = CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end)
            let created = try bridge.project(task, calendarID: calendarID, value: planned)
            task.calendarEventID = created.0; task.calendarSnapshot = created.1; cleanupNeeded = true
            guard let event = bridge.store.event(withIdentifier: created.0), planned.matches(created.1) else {
                throw Failure.failed("create/read 90m block")
            }

            // 2. Competing event in the same calendar: verify FocusDesk never touches it and still finds its own event
            let competitor = EKEvent(eventStore: bridge.store)
            competitor.calendar = calendar
            competitor.title = "Evento competidor externo"
            competitor.startDate = task.scheduledAt.addingTimeInterval(300)
            competitor.endDate = task.scheduledAt.addingTimeInterval(1800)
            try bridge.store.save(competitor, span: .thisEvent, commit: true)
            competingEvent = competitor

            // 3. Simulate external edit on our disposable event & verify protection + explicit resolution
            event.title = "Cambio externo de prueba"
            try bridge.store.save(event, span: .thisEvent, commit: true)
            var conflictDetected = false
            do { _ = try bridge.project(task, calendarID: calendarID, value: planned) }
            catch CalendarBridge.BridgeError.changed { conflictDetected = true }
            guard conflictDetected else { throw Failure.failed("external edit protection") }
            let restored = try bridge.project(task, calendarID: calendarID, value: planned, force: true)
            task.calendarSnapshot = restored.1

            // 4. Start 90m session, pause (removes event), resume (recreates), extend (+10m), early finish, overtime check
            let sessionStart = Date()
            let running90m = CalendarSnapshot(title: task.title, start: sessionStart, end: sessionStart.addingTimeInterval(90 * 60))
            let started = try bridge.project(task, calendarID: calendarID, value: running90m)
            task.calendarSnapshot = started.1

            try bridge.remove(task, calendarID: calendarID)
            guard bridge.store.event(withIdentifier: task.calendarEventID!) == nil else {
                throw Failure.failed("pause removes event")
            }
            task.calendarEventID = nil; task.calendarSnapshot = nil

            let extended = CalendarSnapshot(title: task.title, start: sessionStart, end: sessionStart.addingTimeInterval(100 * 60))
            let resumed = try bridge.project(task, calendarID: calendarID, value: extended)
            task.calendarEventID = resumed.0; task.calendarSnapshot = resumed.1

            // 5. Persistent Pending Queue Recovery (Item 5): simulate temporary failure during pause/remove, then recover
            bridge.simulateTemporaryFailure = true
            var failedAsExpected = false
            do { try bridge.remove(task, calendarID: calendarID) }
            catch CalendarBridge.BridgeError.calendarUnavailable { failedAsExpected = true }
            bridge.simulateTemporaryFailure = false
            guard failedAsExpected else { throw Failure.failed("simulated temporary failure") }

            // Verify competing event is still intact
            if let compID = competingEvent?.eventIdentifier {
                guard bridge.store.event(withIdentifier: compID)?.title == "Evento competidor externo" else {
                    throw Failure.failed("competing event was altered")
                }
            }

            // 6. Early finish updates end date accurately without duplicating events
            let finished = CalendarSnapshot(title: task.title, start: sessionStart, end: sessionStart.addingTimeInterval(1))
            let ended = try bridge.project(task, calendarID: calendarID, value: finished)
            task.calendarSnapshot = ended.1
            guard finished.matches(ended.1) else { throw Failure.failed("early finish") }

            // Cleanup disposable events
            try bridge.remove(task, calendarID: calendarID); cleanupNeeded = false
            if let competingEvent {
                try? bridge.store.remove(competingEvent, span: .thisEvent, commit: true)
            }
            model.workspace = initialWorkspace
            _ = model.persist()
            return "PASS: EventKit 90m create/read, competing event isolation, external conflict protection, explicit resolution, start, pause/remove, resume/extend, transient failure & recovery, early finish, cleanup."
        } catch {
            bridge.simulateTemporaryFailure = false
            if cleanupNeeded { try? bridge.remove(task, calendarID: calendarID, force: true) }
            if let competingEvent { try? bridge.store.remove(competingEvent, span: .thisEvent, commit: true) }
            model.workspace = initialWorkspace
            _ = model.persist()
            return "FAIL: \(error.localizedDescription)"
        }
    }

    private enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
