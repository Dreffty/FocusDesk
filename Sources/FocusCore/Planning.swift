import Foundation

/// Last values written by FocusDesk. Compare before changing an external event.
public struct CalendarSnapshot: Codable, Equatable, Sendable {
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

public enum CalendarProjection: Equatable, Sendable {
    case unchanged, remove, event(CalendarSnapshot)

    /// Projected end of a running session, from its own monotonic anchors rather than a UI tick.
    public static func deadline(for session: WorkSession, now: Date, uptime: TimeInterval? = nil) -> Date {
        if let uptime, session.runningUptime != nil {
            return now.addingTimeInterval(session.remaining(at: now, uptime: uptime))
        }
        // Use the last resume anchor, not a stale UI tick, to keep the deadline exact.
        return (session.runningSince ?? now).addingTimeInterval(session.budget - session.accumulated)
    }

    public static func make(task: FocusTask, session: WorkSession?, now: Date, uptime: TimeInterval? = nil) -> Self {
        if let session, session.task.id == task.id {
            if let end = session.endedAt {
                return .event(CalendarSnapshot(title: task.title, start: session.startedAt, end: max(end, session.startedAt.addingTimeInterval(1))))
            }
            if session.paused { return .remove }
            let deadline = deadline(for: session, now: now, uptime: uptime)
            return .event(CalendarSnapshot(title: task.title, start: session.startedAt, end: max(deadline, session.startedAt.addingTimeInterval(1))))
        }
        if !task.isScheduled {
            return task.calendarEventID != nil ? .remove : .unchanged
        }
        if !task.completed && task.scheduledAt > now {
            // One countdown at a time in the Dynamic Island. Vorssaint shows the nearest eligible moment among the
            // events of the calendar, so a task starting before the running session ends would steal the slot from it
            // and count down to something the user is not doing yet. Those blocks stay in FocusDesk and come back to
            // Calendar as soon as the session finishes.
            if let session, session.endedAt == nil, !session.paused,
               task.scheduledAt <= deadline(for: session, now: now, uptime: uptime) {
                return task.calendarEventID != nil ? .remove : .unchanged
            }
            return .event(CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end))
        }
        return .unchanged
    }
}

public struct PlannedReminder: Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case before
        case start
    }
    public var id: String
    public var taskID: UUID
    public var kind: Kind
    public var title: String
    public var body: String
    public var at: Date

    public init(id: String, taskID: UUID = UUID(), kind: Kind = .start, title: String, body: String, at: Date) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.body = body
        self.at = at
    }
}

public enum ReminderPlan {
    public static let maxScheduledReminders = 60

    public static func make(tasks: [FocusTask], sessionTaskID: UUID?, now: Date) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for task in tasks where !task.completed && task.isScheduled && task.id != sessionTaskID && task.scheduledAt > now {
            if task.leadMinutes > 0 {
                let before = task.scheduledAt.addingTimeInterval(-Double(task.leadMinutes) * 60)
                if before > now {
                    result.append(
                        PlannedReminder(
                            id: task.id.uuidString + "before",
                            taskID: task.id,
                            kind: .before,
                            title: "En \(task.leadMinutes) min · \(task.title)",
                            body: "Prepara tu espacio. Tendrás \(task.minutes) minutos.",
                            at: before
                        )
                    )
                }
            }
            result.append(
                PlannedReminder(
                    id: task.id.uuidString + "start",
                    taskID: task.id,
                    kind: .start,
                    title: "Es el momento · \(task.title)",
                    body: "Puedes empezar ahora o posponer 10 minutos desde este aviso.",
                    at: task.scheduledAt
                )
            )
        }
        // Apply the system limit after filtering old tasks and sorting individual reminders.
        return Array(result.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }.prefix(maxScheduledReminders))
    }

    /// Returns true when the desired set of up-to-60 upcoming reminders differs from the currently scheduled identifiers,
    /// e.g. because earlier reminders have fired and subsequent tasks in a busy day can now enter the 60-reminder window.
    public static func needsReplenishment(scheduledIDs: [String], tasks: [FocusTask], sessionTaskID: UUID?, now: Date) -> Bool {
        let desiredIDs = make(tasks: tasks, sessionTaskID: sessionTaskID, now: now).map(\.id)
        return desiredIDs != scheduledIDs
    }
}
