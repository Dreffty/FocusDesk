import Foundation

public struct AllowedApp: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
}

public enum RepeatRule: String, Codable, CaseIterable {
    case never, daily, weekly
    public var label: String { switch self { case .never: return "No repetir"; case .daily: return "Cada día"; case .weekly: return "Cada semana" } }
}

public struct FocusTask: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var category: String
    public var scheduledAt: Date
    public var minutes: Int
    public var leadMinutes: Int
    public var strict: Bool
    public var apps: [AllowedApp]
    public var domains: String
    public var folder: String?
    public var checklist: String
    public var repeatRule: RepeatRule
    public var completed = false
    public var calendarEventID: String?
    public init(title: String = "", category: String = "Personal", scheduledAt: Date = Date().addingTimeInterval(600), minutes: Int = 60, leadMinutes: Int = 10, strict: Bool = false, apps: [AllowedApp] = [], domains: String = "", folder: String? = nil, checklist: String = "", repeatRule: RepeatRule = .never) {
        self.title = title; self.category = category; self.scheduledAt = scheduledAt; self.minutes = minutes
        self.leadMinutes = leadMinutes; self.strict = strict; self.apps = apps; self.domains = domains
        self.folder = folder; self.checklist = checklist; self.repeatRule = repeatRule
    }
    public var end: Date { scheduledAt.addingTimeInterval(Double(minutes) * 60) }
    public var valid: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (1...720).contains(minutes) && (0...60).contains(leadMinutes) && (!strict || !apps.isEmpty) }
    public func nextOccurrence(calendar: Calendar = .current) -> FocusTask? {
        guard repeatRule != .never, let date = calendar.date(byAdding: repeatRule == .daily ? .day : .weekOfYear, value: 1, to: scheduledAt) else { return nil }
        var next = self; next.id = UUID(); next.scheduledAt = date; next.completed = false; next.calendarEventID = nil
        return next
    }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public var modified: Date
    public var bytes: Int64
    public init(modified: Date, bytes: Int64) { self.modified = modified; self.bytes = bytes }
}

public struct Activity: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var at: Date
    public var appID: String
    public var name: String
    public var title: String?
    public var domain: String?
    public var interruption: Bool
    public init(at: Date = Date(), appID: String, name: String, title: String? = nil, domain: String? = nil, interruption: Bool = false) {
        self.at = at; self.appID = appID; self.name = name; self.title = title; self.domain = domain; self.interruption = interruption
    }
}

public struct WorkSession: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var task: FocusTask
    public var startedAt: Date
    public var runningSince: Date?
    public var accumulated: TimeInterval = 0
    public var budget: TimeInterval
    public var baseline: [String: FileStamp] = [:]
    public var baselineValid = false
    public var activities: [Activity] = []
    public var interruptionCount = 0
    public var checked: Set<String> = []
    public var endedAt: Date?
    public var finalChangedFiles: [String]?
    public var finalEvidenceMessage: String?
    public init(task: FocusTask, now: Date = Date()) {
        self.task = task; startedAt = now; runningSince = now; budget = Double(task.minutes) * 60
    }
    public var paused: Bool { runningSince == nil }
    public func elapsed(at now: Date) -> TimeInterval { accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
    public func remaining(at now: Date) -> TimeInterval { budget - elapsed(at: now) }
    public mutating func pause(at now: Date) { accumulated = elapsed(at: now); runningSince = nil }
    public mutating func resume(at now: Date) { guard runningSince == nil, endedAt == nil else { return }; runningSince = now }
    public mutating func finish(at now: Date) { guard endedAt == nil else { return }; pause(at: now); endedAt = now }
    public mutating func add(minutes: Int) { budget += Double(max(0, minutes)) * 60 }
    public mutating func record(_ activity: Activity) {
        guard !paused, endedAt == nil else { return }
        if activity.interruption { interruptionCount += 1 }
        activities.append(activity)
        if activities.count > 3000 { activities.removeFirst(activities.count - 3000) }
    }
}

public struct SessionRecord: Codable, Identifiable {
    public var id: UUID
    public var session: WorkSession
    public var completed: Bool
    public var note: String
    public var changedFiles: [String]
    public init(session: WorkSession, completed: Bool, note: String, changedFiles: [String]) {
        id = session.id; self.session = session; self.completed = completed; self.note = note; self.changedFiles = changedFiles
    }
}

public struct Settings: Codable {
    public var calendarID: String?
    public var observeTitles = false
    public var observeBrave = false
    public var detailDays = 30
    public init() {}
}

public struct Workspace: Codable {
    public var schema = 1
    public var tasks: [FocusTask] = []
    public var session: WorkSession?
    public var history: [SessionRecord] = []
    public var settings = Settings()
    public init() {}
    public mutating func prune(at now: Date) {
        let cutoff = now.addingTimeInterval(-Double(settings.detailDays) * 86400)
        for index in history.indices where (history[index].session.endedAt ?? now) < cutoff {
            history[index].session.activities = []; history[index].session.baseline = [:]
        }
    }
}

public enum FocusRules {
    public static func clock(_ seconds: TimeInterval) -> String {
        let value = Int(abs(seconds).rounded(.up))
        let prefix = seconds < 0 ? "+" : ""
        return value >= 3600 ? String(format: "%@%d:%02d:%02d", prefix, value / 3600, value / 60 % 60, value % 60) : String(format: "%@%02d:%02d", prefix, value / 60, value % 60)
    }
    public static func domainAllowed(_ host: String, list: String) -> Bool {
        let allowed = list.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        return allowed.isEmpty || allowed.contains { host.lowercased() == $0 || host.lowercased().hasSuffix("." + $0) }
    }
    public static func changed(before: [String: FileStamp], after: [String: FileStamp]) -> [String] {
        after.keys.filter { before[$0] != after[$0] }.sorted()
    }
    public static func overlaps(_ a: FocusTask, _ b: FocusTask) -> Bool { a.id != b.id && !a.completed && !b.completed && a.scheduledAt < b.end && b.scheduledAt < a.end }
}
