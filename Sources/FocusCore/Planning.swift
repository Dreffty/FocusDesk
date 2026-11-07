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
            // A task done in Pomodoro shows its current phase: Vorssaint counts down to the end of the event, so
            // the event is the focus block or the break in progress, and is rewritten at every change of phase.
            if let phase = task.pomodoroPhase(elapsed: session.elapsed(at: now, uptime: uptime)) {
                let phaseEnd = min(deadline, now.addingTimeInterval(phase.remainingInPhase))
                let title = phase.isBreak ? "\(phase.label) · \(task.title)" : "\(phase.label) \(phase.cycle) · \(task.title)"
                return .event(CalendarSnapshot(title: title, start: session.startedAt, end: max(phaseEnd, session.startedAt.addingTimeInterval(1))))
            }
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

/// Keeps recurring series alive after a missed day.
///
/// A series is a single task whose `scheduledAt` is its current occurrence, and it only advances when that occurrence
/// is confirmed as done. Skip one day — not started, "Sigue pendiente" or cancelled — and it stayed in the past for
/// good: no reminder, no Calendar block and no Vorssaint countdown on any later day, while the agenda still drew the
/// following days as projected, so it *looked* scheduled. Rolling moves the series to its first occurrence from today
/// on and leaves the missed one behind as an ordinary overdue task, so nothing silently disappears either.
public enum SeriesRoller {
    public struct Result: Equatable, Sendable {
        public var tasks: [FocusTask]
        /// Series that moved forward, keeping their identity (and their Calendar event, which the bridge moves).
        public var rolledSeriesIDs: [UUID]
        /// Overdue standalone copies left behind for missed occurrences.
        public var createdOverdueIDs: [UUID]
    }

    public static func roll(
        _ tasks: [FocusTask],
        sessionTaskID: UUID?,
        now: Date,
        calendar: Calendar = .current,
        workdays: Set<Int> = [2, 3, 4, 5, 6]
    ) -> Result {
        let startOfToday = calendar.startOfDay(for: now)
        var result = tasks
        var rolled: [UUID] = []
        var created: [UUID] = []

        for index in result.indices {
            let head = result[index]
            guard head.repeatRule != .never, head.isScheduled, !head.completed, head.id != sessionTaskID,
                  calendar.startOfDay(for: head.scheduledAt) < startOfToday,
                  // First occurrence from today on, honouring skipped (detached) days.
                  let next = head.nextOccurrence(after: startOfToday.addingTimeInterval(-1), calendar: calendar, workdays: workdays)
            else { continue }

            // One overdue reminder per series is enough: missing a daily task for a week should not bury the day
            // under seven copies of it.
            let seriesKey = head.seriesID ?? head.id
            let alreadyOverdue = result.contains { other in
                other.repeatRule == .never && !other.completed && other.isScheduled &&
                (other.seriesID == seriesKey || other.seriesID == head.id) &&
                other.scheduledAt < startOfToday
            }
            if !alreadyOverdue {
                var missed = head
                missed.id = UUID()
                missed.repeatRule = .never
                missed.repeatDays = []
                missed.skippedDates = []
                missed.seriesID = seriesKey
                missed.calendarEventID = nil
                missed.calendarSnapshot = nil
                result.append(missed)
                created.append(missed.id)
            }

            result[index].scheduledAt = next.scheduledAt
            result[index].dueDate = next.dueDate
            rolled.append(head.id)
        }
        return Result(tasks: result, rolledSeriesIDs: rolled, createdOverdueIDs: created)
    }
}

/// Side-by-side layout for the hourly view. Blocks were drawn full width on top of each other, so of two tasks at
/// the same time the one underneath could not be read, clicked or dragged.
public enum TimelineLayout {
    public struct Slot: Equatable, Sendable {
        public var column: Int
        public var columns: Int
        public init(column: Int, columns: Int) { self.column = column; self.columns = columns }
    }

    /// Assigns each interval a column inside its cluster of mutually overlapping intervals. `minimumMinutes` mirrors
    /// the minimum height a block is drawn with, so two short tasks that touch visually also get their own columns.
    public struct Interval: Equatable, Sendable {
        public var id: UUID
        public var start: Date
        public var end: Date
        public init(id: UUID, start: Date, end: Date) { self.id = id; self.start = start; self.end = end }
    }

    public static func columns(for intervals: [Interval], minimumMinutes: Double = 30) -> [UUID: Slot] {
        let minimum: TimeInterval = minimumMinutes * 60
        var items: [Interval] = intervals.map { interval in
            Interval(id: interval.id, start: interval.start, end: max(interval.end, interval.start.addingTimeInterval(minimum)))
        }
        items.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end > rhs.end
        }
        var result: [UUID: Slot] = [:]
        var cluster: [(id: UUID, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let width = max(1, columnEnds.count)
            for member in cluster { result[member.id] = Slot(column: member.column, columns: width) }
            cluster = []
            columnEnds = []
        }

        for item in items {
            if !cluster.isEmpty && item.start >= clusterEnd { closeCluster() }
            // Reuse the first column that is already free at this start; otherwise open a new one.
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = item.end
                cluster.append((item.id, free))
            } else {
                columnEnds.append(item.end)
                cluster.append((item.id, columnEnds.count - 1))
            }
            clusterEnd = cluster.count == 1 ? item.end : max(clusterEnd, item.end)
        }
        closeCluster()
        return result
    }
}

public extension FocusRules {
    /// Default start for a new task on `day`: right after the last pending task of that day (stepping over breaks),
    /// or the start of the working day; on today, never earlier than ten minutes from now. Planning four tasks for
    /// tomorrow used to put all four at 9:00, on top of each other.
    static func firstFreeSlot(
        on day: Date,
        tasks: [FocusTask],
        breaks: [BreakPeriod],
        workStartHour: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        let workStart = calendar.date(bySettingHour: workStartHour, minute: 0, second: 0, of: dayStart) ?? dayStart
        var slot = workStart
        let lastEnd = tasks
            .filter { $0.isScheduled && !$0.completed && calendar.isDate($0.scheduledAt, inSameDayAs: dayStart) }
            .map(\.end)
            .max()
        if let lastEnd, lastEnd > slot { slot = lastEnd }
        if calendar.isDate(dayStart, inSameDayAs: now) { slot = max(slot, now.addingTimeInterval(600)) }

        // Step over breaks (repeat in case one break ends where another starts).
        for _ in 0..<breaks.count + 1 {
            var moved = false
            for brk in breaks {
                guard let breakStart = calendar.date(bySettingHour: brk.startHour, minute: brk.startMinute, second: 0, of: dayStart) else { continue }
                let breakEnd = breakStart.addingTimeInterval(Double(brk.durationMinutes) * 60)
                if slot >= breakStart && slot < breakEnd { slot = breakEnd; moved = true }
            }
            if !moved { break }
        }

        // Round up to the next 5 minutes. Every current time-zone offset is a multiple of 15 minutes, so 5-minute
        // steps of absolute time are also 5-minute steps on the local clock.
        let step: TimeInterval = 300
        return Date(timeIntervalSinceReferenceDate: (slot.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
    }
}
