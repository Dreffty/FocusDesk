import AppKit
import EventKit
import FocusCore

@MainActor
final class CalendarBridge: ObservableObject {
    let store = EKEventStore()
    @Published var sources: [EKSource] = []
    @Published var existing: [EKCalendar] = []
    @Published var message = "Sin conectar"
    @Published var issues: [UUID: String] = [:]
    @Published var lastSync: Date?
    @Published var requesting = false
    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    init() { refresh() }
    func refresh() {
        guard authorized else { sources = []; existing = []; return }
        sources = store.sources.filter { $0.sourceType == .local || $0.sourceType == .calDAV || $0.sourceType == .exchange }
        existing = store.calendars(for: .event).filter { $0.title == "FocusDesk" && $0.allowsContentModifications }
    }
    func request() async {
        guard !requesting else { return }
        requesting = true; defer { requesting = false }
        do {
            guard try await store.requestFullAccessToEvents() else { message = "Permiso denegado. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Calendarios."; return }
            refresh(); message = "Elige un calendario FocusDesk o crea uno en tu cuenta"
        } catch { message = error.localizedDescription }
    }
    func connected(_ id: String?) -> EKCalendar? {
        guard authorized, let id else { return nil }
        return store.calendar(withIdentifier: id)
    }
    func create(in source: EKSource) throws -> String {
        guard authorized else { throw BridgeError.calendarUnavailable }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "FocusDesk"; calendar.cgColor = NSColor.systemMint.cgColor; calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        refresh(); return calendar.calendarIdentifier
    }
    private func snapshot(_ event: EKEvent) -> CalendarSnapshot {
        CalendarSnapshot(title: event.title ?? "", start: event.startDate, end: event.endDate, allDay: event.isAllDay)
    }
    private func ownedEvent(_ task: FocusTask, calendarID: String) throws -> EKEvent? {
        guard let id = task.calendarEventID else {
            // Recover an ID lost after an external save, or after reconnecting the same calendar.
            guard let calendar = connected(calendarID) else { throw BridgeError.calendarUnavailable }
            let anchors = [task.scheduledAt, task.calendarSnapshot?.start ?? Date()]
            var matches: [String: EKEvent] = [:]
            for anchor in anchors {
                let predicate = store.predicateForEvents(withStart: anchor.addingTimeInterval(-86400), end: anchor.addingTimeInterval(86400), calendars: [calendar])
                for event in store.events(matching: predicate) where event.url?.absoluteString == "focusdesk://task/" + task.id.uuidString {
                    if let id = event.eventIdentifier { matches[id] = event }
                }
            }
            guard matches.count <= 1 else { throw BridgeError.ownership }
            if let event = matches.values.first {
                guard !event.hasRecurrenceRules, !event.isDetached else { throw BridgeError.ownership }
                return event
            }
            return nil
        }
        guard let event = store.event(withIdentifier: id) else { throw BridgeError.deleted }
        guard event.calendar.calendarIdentifier == calendarID, event.url?.absoluteString == "focusdesk://task/" + task.id.uuidString,
              !event.hasRecurrenceRules, !event.isDetached else { throw BridgeError.ownership }
        return event
    }
    private func check(_ event: EKEvent, task: FocusTask, force: Bool) throws {
        guard !force else { return }
        let baseline = task.calendarSnapshot ?? CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end)
        guard baseline.matches(snapshot(event)) else { throw BridgeError.changed }
    }
    func project(_ task: FocusTask, calendarID: String, value: CalendarSnapshot, force: Bool = false) throws -> (String, CalendarSnapshot) {
        guard authorized, let calendar = connected(calendarID), calendar.allowsContentModifications else { throw BridgeError.calendarUnavailable }
        let event: EKEvent
        if let old = try ownedEvent(task, calendarID: calendarID) { try check(old, task: task, force: force); event = old }
        else {
            event = EKEvent(eventStore: store); event.calendar = calendar
            event.url = URL(string: "focusdesk://task/" + task.id.uuidString)
            event.notes = "Bloque gestionado por FocusDesk. Abre FocusDesk para iniciar, pausar o terminar."
        }
        if event.eventIdentifier == nil || !snapshot(event).matches(value) {
            event.title = value.title; event.startDate = value.start; event.endDate = value.end; event.isAllDay = false
            try store.save(event, span: .thisEvent, commit: true)
        }
        return (event.eventIdentifier, snapshot(event))
    }
    func remove(_ task: FocusTask, calendarID: String, force: Bool = false) throws {
        guard authorized else { throw BridgeError.calendarUnavailable }
        // An already deleted projection is already absent; no need to recreate it.
        guard let id = task.calendarEventID, store.event(withIdentifier: id) != nil else { return }
        guard let event = try ownedEvent(task, calendarID: calendarID) else { return }
        try check(event, task: task, force: force)
        try store.remove(event, span: .thisEvent, commit: true)
    }
    func validate(_ task: FocusTask, calendarID: String) throws {
        if let event = try ownedEvent(task, calendarID: calendarID) { try check(event, task: task, force: false) }
    }
    func openEvent(_ task: FocusTask) {
        guard let id = task.calendarEventID, let event = store.event(withIdentifier: id),
              let key = event.calendarItemIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "ical://ekevent/\(key)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }
    enum BridgeError: LocalizedError {
        case calendarUnavailable, ownership, changed, deleted
        var errorDescription: String? {
            switch self {
            case .calendarUnavailable: return "Calendario no disponible o sin permiso de escritura. Revisa la conexión."
            case .ownership: return "El evento fue trasladado, convertido en serie o perdió su marca. No se ha modificado."
            case .changed: return "El evento cambió en Calendar. Se ha conservado. Puedes aplicar el horario de FocusDesk explícitamente."
            case .deleted: return "El evento fue eliminado en Calendar. No se ha recreado automáticamente."
            }
        }
    }
}
