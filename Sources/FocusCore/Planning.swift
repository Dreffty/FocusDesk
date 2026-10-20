import Foundation

/// Last values written by FocusDesk. Compare before changing an external event.
public struct CalendarSnapshot: Codable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public init(title: String, start: Date, end: Date, allDay: Bool = false) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay
    }
    public func matches(_ other: CalendarSnapshot) -> Bool {
        title == other.title && allDay == other.allDay && abs(start.timeIntervalSince(other.start)) < 1 && abs(end.timeIntervalSince(other.end)) < 1
    }
}

public enum CalendarProjection: Equatable {
    case unchanged, remove, event(CalendarSnapshot)
    public static func make(task: FocusTask, session: WorkSession?, now: Date) -> Self {
        if let session, session.task.id == task.id {
            if let end = session.endedAt { return .event(CalendarSnapshot(title: task.title, start: session.startedAt, end: max(end, session.startedAt.addingTimeInterval(1)))) }
            if session.paused { return .remove }
            // Use the last resume anchor, not a stale UI tick, to keep the deadline exact.
            let deadline = (session.runningSince ?? now).addingTimeInterval(session.budget - session.accumulated)
            return .event(CalendarSnapshot(title: task.title, start: session.startedAt, end: max(deadline, session.startedAt.addingTimeInterval(1))))
        }
        if !task.completed && task.scheduledAt > now { return .event(CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end)) }
        return .unchanged
    }
}

public struct PlannedReminder: Equatable {
    public var id: String
    public var title: String
    public var body: String
    public var at: Date
}

public enum ReminderPlan {
    public static func make(tasks: [FocusTask], sessionTaskID: UUID?, now: Date) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for task in tasks where !task.completed && task.id != sessionTaskID && task.scheduledAt > now {
            if task.leadMinutes > 0 {
                let before = task.scheduledAt.addingTimeInterval(-Double(task.leadMinutes) * 60)
                if before > now {
                    result.append(PlannedReminder(id: task.id.uuidString + "before", title: "En \(task.leadMinutes) min · \(task.title)", body: "Prepara tu espacio. Tendrás \(task.minutes) minutos.", at: before))
                }
            }
            result.append(PlannedReminder(id: task.id.uuidString + "start", title: "Es el momento · \(task.title)", body: "Abre FocusDesk desde el Dock o la barra para empezar.", at: task.scheduledAt))
        }
        // Apply the system limit after filtering old tasks and sorting individual reminders.
        return Array(result.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }.prefix(60))
    }
}
