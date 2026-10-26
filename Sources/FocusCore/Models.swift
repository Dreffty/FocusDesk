import Foundation

public struct AllowedApp: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) {
        self.id = id; self.name = name; self.path = path
    }
}

public enum RepeatRule: String, Codable, CaseIterable, Sendable {
    case never, daily, weekly, weekdays, customDays
    public var label: String {
        switch self {
        case .never: return "No repetir"
        case .daily: return "Cada día"
        case .weekly: return "Cada semana"
        case .weekdays: return "Días laborables"
        case .customDays: return "Días concretos"
        }
    }
}

public struct FocusProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: String
    public var minutes: Int
    public var leadMinutes: Int
    public var strict: Bool
    public var apps: [AllowedApp]
    public var domains: String
    public var folder: String?
    public var checklist: String
    public var autoStart: Bool
    public var protection: SessionProtection
    public var unlockChars: Int
    public var stopDelayMinutes: Int
    public var blockAction: AppBlockAction
    public var webBlockAction: WebBlockAction
    public var guardSystemPanes: Bool
    public var punisherEnabled: Bool
    /// Folders that close as soon as they are opened during the session (`FolderRules`).
    public var blockedFolders: [String]
    public var appListMode: AppListMode
    public var webListMode: WebListMode
    public var blockedTitleKeywords: String
    public var customRedirectURL: String
    public var motivationalMessage: String

    public init(
        id: UUID = UUID(),
        name: String,
        category: String = "Personal",
        minutes: Int = 60,
        leadMinutes: Int = 10,
        strict: Bool = false,
        apps: [AllowedApp] = [],
        domains: String = "",
        folder: String? = nil,
        checklist: String = "",
        autoStart: Bool = false,
        protection: SessionProtection = .none,
        unlockChars: Int = 24,
        stopDelayMinutes: Int = 5,
        blockAction: AppBlockAction = .hide,
        webBlockAction: WebBlockAction = .warn,
        guardSystemPanes: Bool = true,
        punisherEnabled: Bool = true,
        blockedFolders: [String] = [],
        appListMode: AppListMode = .allowListed,
        webListMode: WebListMode = .allowListed,
        blockedTitleKeywords: String = "",
        customRedirectURL: String = "",
        motivationalMessage: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.minutes = minutes
        self.leadMinutes = leadMinutes
        self.strict = strict
        self.apps = apps
        self.domains = FocusRules.normalizeDomains(domains)
        self.folder = folder
        self.checklist = checklist
        self.autoStart = autoStart
        self.protection = protection
        self.unlockChars = UnlockChallenge.clampedLength(unlockChars)
        self.stopDelayMinutes = max(1, min(120, stopDelayMinutes))
        self.blockAction = blockAction
        self.webBlockAction = webBlockAction
        self.guardSystemPanes = guardSystemPanes
        self.punisherEnabled = punisherEnabled
        self.blockedFolders = FolderRules.normalizeList(blockedFolders)
        self.appListMode = appListMode
        self.webListMode = webListMode
        self.blockedTitleKeywords = FocusRules.normalizeTitleKeywords(blockedTitleKeywords)
        self.customRedirectURL = customRedirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.motivationalMessage = motivationalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, minutes, leadMinutes, strict, apps, domains, folder, checklist, autoStart
        case protection, unlockChars, stopDelayMinutes, blockAction, webBlockAction, guardSystemPanes, punisherEnabled
        case blockedFolders, appListMode, webListMode, blockedTitleKeywords, customRedirectURL, motivationalMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Personal"
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 60
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 10
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false
        apps = try c.decodeIfPresent([AllowedApp].self, forKey: .apps) ?? []
        domains = try c.decodeIfPresent(String.self, forKey: .domains) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        checklist = try c.decodeIfPresent(String.self, forKey: .checklist) ?? ""
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        protection = try c.decodeIfPresent(SessionProtection.self, forKey: .protection) ?? .none
        unlockChars = UnlockChallenge.clampedLength(try c.decodeIfPresent(Int.self, forKey: .unlockChars) ?? 24)
        stopDelayMinutes = max(1, min(120, try c.decodeIfPresent(Int.self, forKey: .stopDelayMinutes) ?? 5))
        blockAction = try c.decodeIfPresent(AppBlockAction.self, forKey: .blockAction) ?? .hide
        webBlockAction = try c.decodeIfPresent(WebBlockAction.self, forKey: .webBlockAction) ?? .warn
        guardSystemPanes = try c.decodeIfPresent(Bool.self, forKey: .guardSystemPanes) ?? true
        punisherEnabled = try c.decodeIfPresent(Bool.self, forKey: .punisherEnabled) ?? true
        blockedFolders = try c.decodeIfPresent([String].self, forKey: .blockedFolders) ?? []
        appListMode = try c.decodeIfPresent(AppListMode.self, forKey: .appListMode) ?? .allowListed
        webListMode = try c.decodeIfPresent(WebListMode.self, forKey: .webListMode) ?? .allowListed
        blockedTitleKeywords = try c.decodeIfPresent(String.self, forKey: .blockedTitleKeywords) ?? ""
        customRedirectURL = (try c.decodeIfPresent(String.self, forKey: .customRedirectURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        motivationalMessage = (try c.decodeIfPresent(String.self, forKey: .motivationalMessage) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let defaults: [FocusProfile] = [
        FocusProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111101")!,
            name: "Grabar vídeo",
            category: "Contenido",
            minutes: 60,
            leadMinutes: 10,
            strict: false,
            apps: [],
            domains: "chatgpt.com, claude.ai",
            checklist: "Preparar el guion\nGrabar las tomas\nGuardar el material"
        ),
        FocusProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111102")!,
            name: "Estudiar",
            category: "Estudio",
            minutes: 45,
            leadMinutes: 10,
            strict: false,
            apps: [],
            domains: "",
            checklist: "Repasar el tema\nResolver ejercicios\nAnotar las dudas"
        ),
        FocusProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111103")!,
            name: "Tienda",
            category: "Tienda",
            minutes: 30,
            leadMinutes: 10,
            strict: false,
            apps: [],
            domains: "",
            checklist: "Revisar pedidos\nResponder mensajes\nActualizar stock"
        )
    ]
}

public struct CategoryItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(name: String, red: Double, green: Double, blue: Double) {
        self.name = name; self.red = red; self.green = green; self.blue = blue
    }

    public static let defaults: [CategoryItem] = [
        CategoryItem(name: "Personal", red: 0.70, green: 0.78, blue: 0.87),
        CategoryItem(name: "Contenido", red: 1.00, green: 0.65, blue: 0.48),
        CategoryItem(name: "Estudio", red: 0.65, green: 0.69, blue: 0.98),
        CategoryItem(name: "Tienda", red: 0.40, green: 0.78, blue: 0.90)
    ]

    /// The colour "Tienda" had while it matched the app's accent; migrated to the default above.
    public static let retiredTiendaColor = (red: 0.64, green: 0.89, blue: 0.73)
}

public struct BreakPeriod: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var startHour: Int
    public var startMinute: Int
    public var durationMinutes: Int

    public init(id: UUID = UUID(), title: String = "Descanso", startHour: Int = 14, startMinute: Int = 0, durationMinutes: Int = 60) {
        self.id = id
        self.title = title
        self.startHour = max(0, min(23, startHour))
        self.startMinute = max(0, min(59, startMinute))
        self.durationMinutes = max(5, min(240, durationMinutes))
    }

    public func interval(on date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(bySettingHour: startHour, minute: startMinute, second: 0, of: date) else { return nil }
        let end = start.addingTimeInterval(Double(max(5, durationMinutes)) * 60)
        return DateInterval(start: start, end: end)
    }

    public func isActive(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let window = interval(on: now, calendar: calendar) else { return false }
        return now >= window.start && now < window.end
    }

    public func remainingSeconds(at now: Date, calendar: Calendar = .current) -> TimeInterval {
        guard let window = interval(on: now, calendar: calendar), now >= window.start, now < window.end else { return 0 }
        return max(0, window.end.timeIntervalSince(now))
    }
}

public struct FocusTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var category: String
    public var scheduledAt: Date
    public var isScheduled: Bool
    public var dueDate: Date?
    public var minutes: Int
    public var leadMinutes: Int
    public var strict: Bool
    public var apps: [AllowedApp]
    public var domains: String
    public var folder: String?
    public var checklist: String
    public var repeatRule: RepeatRule
    public var repeatDays: Set<Int>
    public var skippedDates: Set<String>
    public var seriesID: UUID?
    public var profileID: UUID?
    public var isFixedAppointment: Bool
    public var completed: Bool
    public var calendarEventID: String?
    public var calendarSnapshot: CalendarSnapshot?
    /// Starts the session by itself at `scheduledAt` (only on an unlocked Mac with no other session running).
    public var autoStart: Bool
    /// What FocusDesk asks for before letting this session stop early (`SessionProtection`).
    public var protection: SessionProtection
    /// Length of the random string `.challenge` asks you to type.
    public var unlockChars: Int
    /// Minutes `.delay` makes you wait between asking to stop and stopping.
    public var stopDelayMinutes: Int
    /// What happens to an app outside the list: hide it, close it or force it to quit.
    public var blockAction: AppBlockAction
    /// What happens to a tab on a site outside `domains`: warn, redirect it or close it.
    public var webBlockAction: WebBlockAction
    /// Closes System Settings on the panes that would end the block (Privacy, Date & Time, Users).
    public var guardSystemPanes: Bool
    /// Makes the block harder for a while after several attempts in a row.
    public var punisherEnabled: Bool
    /// Folders that close as soon as they are opened during the session — in the Finder, or as the document of
    /// any app (a film in QuickTime). FocusMe's «Finder locations».
    public var blockedFolders: [String]
    /// Whether `apps` is a whitelist (`.allowListed`) or a blacklist (`.blockListed`).
    public var appListMode: AppListMode
    /// Whether `domains` is a whitelist (`.allowListed`), a blacklist (`.blockListed`), or blocks all sites (`.blockAll`).
    public var webListMode: WebListMode
    /// Comma-separated keywords that trigger a block when found in the frontmost window title.
    public var blockedTitleKeywords: String
    /// Optional productive URL (`https://...`) to redirect blocked tabs to instead of the local block page (`websiteRedirectUrl` in FocusMe).
    public var customRedirectURL: String
    /// Custom motivational message or quote shown on the block page.
    public var motivationalMessage: String

    public init(
        id: UUID = UUID(),
        title: String = "",
        category: String = "Personal",
        scheduledAt: Date = Date().addingTimeInterval(600),
        isScheduled: Bool = true,
        dueDate: Date? = nil,
        minutes: Int = 60,
        leadMinutes: Int = 10,
        strict: Bool = false,
        apps: [AllowedApp] = [],
        domains: String = "",
        folder: String? = nil,
        checklist: String = "",
        repeatRule: RepeatRule = .never,
        repeatDays: Set<Int> = [],
        skippedDates: Set<String> = [],
        seriesID: UUID? = nil,
        profileID: UUID? = nil,
        isFixedAppointment: Bool = false,
        completed: Bool = false,
        calendarEventID: String? = nil,
        calendarSnapshot: CalendarSnapshot? = nil,
        autoStart: Bool = false,
        protection: SessionProtection = .none,
        unlockChars: Int = 24,
        stopDelayMinutes: Int = 5,
        blockAction: AppBlockAction = .hide,
        webBlockAction: WebBlockAction = .warn,
        guardSystemPanes: Bool = true,
        punisherEnabled: Bool = true,
        blockedFolders: [String] = [],
        appListMode: AppListMode = .allowListed,
        webListMode: WebListMode = .allowListed,
        blockedTitleKeywords: String = "",
        customRedirectURL: String = "",
        motivationalMessage: String = ""
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.scheduledAt = scheduledAt
        self.isScheduled = isScheduled
        self.dueDate = dueDate
        self.minutes = minutes
        self.leadMinutes = leadMinutes
        self.strict = strict
        self.apps = apps
        self.domains = domains
        self.folder = folder
        self.checklist = checklist
        self.repeatRule = repeatRule
        self.repeatDays = repeatDays
        self.skippedDates = skippedDates
        self.seriesID = seriesID
        self.profileID = profileID
        self.isFixedAppointment = isFixedAppointment
        self.completed = completed
        self.calendarEventID = calendarEventID
        self.calendarSnapshot = calendarSnapshot
        self.autoStart = autoStart
        self.protection = protection
        self.unlockChars = UnlockChallenge.clampedLength(unlockChars)
        self.stopDelayMinutes = max(1, min(120, stopDelayMinutes))
        self.blockAction = blockAction
        self.webBlockAction = webBlockAction
        self.guardSystemPanes = guardSystemPanes
        self.punisherEnabled = punisherEnabled
        self.blockedFolders = FolderRules.normalizeList(blockedFolders)
        self.appListMode = appListMode
        self.webListMode = webListMode
        self.blockedTitleKeywords = FocusRules.normalizeTitleKeywords(blockedTitleKeywords)
        self.customRedirectURL = customRedirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.motivationalMessage = motivationalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, category, scheduledAt, isScheduled, dueDate, minutes, leadMinutes, strict
        case apps, domains, folder, checklist, repeatRule, repeatDays, skippedDates, seriesID
        case profileID, isFixedAppointment, completed, calendarEventID, calendarSnapshot, autoStart
        case protection, unlockChars, stopDelayMinutes, blockAction, webBlockAction, guardSystemPanes, punisherEnabled
        case blockedFolders, appListMode, webListMode, blockedTitleKeywords, customRedirectURL, motivationalMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "Personal"
        scheduledAt = try c.decodeIfPresent(Date.self, forKey: .scheduledAt) ?? Date()
        isScheduled = try c.decodeIfPresent(Bool.self, forKey: .isScheduled) ?? true
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 60
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? 10
        strict = try c.decodeIfPresent(Bool.self, forKey: .strict) ?? false
        apps = try c.decodeIfPresent([AllowedApp].self, forKey: .apps) ?? []
        domains = try c.decodeIfPresent(String.self, forKey: .domains) ?? ""
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        checklist = try c.decodeIfPresent(String.self, forKey: .checklist) ?? ""
        repeatRule = try c.decodeIfPresent(RepeatRule.self, forKey: .repeatRule) ?? .never
        repeatDays = try c.decodeIfPresent(Set<Int>.self, forKey: .repeatDays) ?? []
        skippedDates = try c.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        seriesID = try c.decodeIfPresent(UUID.self, forKey: .seriesID)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        isFixedAppointment = try c.decodeIfPresent(Bool.self, forKey: .isFixedAppointment) ?? false
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        calendarEventID = try c.decodeIfPresent(String.self, forKey: .calendarEventID)
        calendarSnapshot = try c.decodeIfPresent(CalendarSnapshot.self, forKey: .calendarSnapshot)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        protection = try c.decodeIfPresent(SessionProtection.self, forKey: .protection) ?? .none
        unlockChars = UnlockChallenge.clampedLength(try c.decodeIfPresent(Int.self, forKey: .unlockChars) ?? 24)
        stopDelayMinutes = max(1, min(120, try c.decodeIfPresent(Int.self, forKey: .stopDelayMinutes) ?? 5))
        blockAction = try c.decodeIfPresent(AppBlockAction.self, forKey: .blockAction) ?? .hide
        webBlockAction = try c.decodeIfPresent(WebBlockAction.self, forKey: .webBlockAction) ?? .warn
        guardSystemPanes = try c.decodeIfPresent(Bool.self, forKey: .guardSystemPanes) ?? true
        punisherEnabled = try c.decodeIfPresent(Bool.self, forKey: .punisherEnabled) ?? true
        blockedFolders = try c.decodeIfPresent([String].self, forKey: .blockedFolders) ?? []
        appListMode = try c.decodeIfPresent(AppListMode.self, forKey: .appListMode) ?? .allowListed
        webListMode = try c.decodeIfPresent(WebListMode.self, forKey: .webListMode) ?? .allowListed
        blockedTitleKeywords = try c.decodeIfPresent(String.self, forKey: .blockedTitleKeywords) ?? ""
        customRedirectURL = (try c.decodeIfPresent(String.self, forKey: .customRedirectURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        motivationalMessage = (try c.decodeIfPresent(String.self, forKey: .motivationalMessage) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var end: Date { scheduledAt.addingTimeInterval(Double(minutes) * 60) }

    public var valid: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validDuration = (1...720).contains(minutes) && (0...60).contains(leadMinutes)
        let validStrict = !strict || !apps.isEmpty
        let validRepeat = repeatRule != .customDays || !repeatDays.isEmpty
        // Blocking websites needs a list of domains unless blocking all websites (`webListMode == .blockAll`).
        let validWeb = webBlockAction == .warn || webListMode == .blockAll || !FocusRules.parseDomains(domains).valid.isEmpty
        return hasTitle && validDuration && validStrict && validRepeat && validWeb
    }

    /// Whether this task defends itself at all: it blocks something, or it resists being stopped.
    public var enforces: Bool {
        strict || webBlockAction != .warn || protection != .none || !blockedFolders.isEmpty
            || !FocusRules.parseTitleKeywords(blockedTitleKeywords).isEmpty
    }

    /// Snoozes an overdue or unscheduled task relative to `now`, or shifts a future task forward from `scheduledAt`.
    public func snoozed(minutes deltaMinutes: Int = 10, now: Date = Date()) -> FocusTask {
        var copy = self
        let delta = Double(max(1, deltaMinutes)) * 60
        if !copy.isScheduled || copy.scheduledAt <= now {
            copy.scheduledAt = now.addingTimeInterval(delta)
        } else {
            copy.scheduledAt = copy.scheduledAt.addingTimeInterval(delta)
        }
        copy.isScheduled = true
        return copy
    }

    public mutating func apply(_ profile: FocusProfile) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { title = profile.name }
        category = profile.category
        minutes = profile.minutes
        leadMinutes = profile.leadMinutes
        strict = profile.strict
        if !profile.apps.isEmpty { apps = profile.apps }
        domains = profile.domains
        if let folder = profile.folder { self.folder = folder }
        checklist = profile.checklist
        autoStart = profile.autoStart
        protection = profile.protection
        unlockChars = profile.unlockChars
        stopDelayMinutes = profile.stopDelayMinutes
        blockAction = profile.blockAction
        webBlockAction = profile.webBlockAction
        guardSystemPanes = profile.guardSystemPanes
        punisherEnabled = profile.punisherEnabled
        blockedFolders = profile.blockedFolders
        appListMode = profile.appListMode
        webListMode = profile.webListMode
        blockedTitleKeywords = profile.blockedTitleKeywords
        customRedirectURL = profile.customRedirectURL
        motivationalMessage = profile.motivationalMessage
        profileID = profile.id
    }

    public func nextOccurrence(after: Date? = nil, calendar: Calendar = .current, workdays: Set<Int> = [2, 3, 4, 5, 6]) -> FocusTask? {
        guard repeatRule != .never, isScheduled else { return nil }
        let allowedWeekdays: Set<Int>? = {
            switch repeatRule {
            case .weekdays: return workdays.isEmpty ? [2, 3, 4, 5, 6] : workdays
            case .customDays: return repeatDays.isEmpty ? [calendar.component(.weekday, from: scheduledAt)] : repeatDays
            default: return nil
            }
        }()

        let reference = after.map { max(scheduledAt, $0) } ?? scheduledAt
        var candidate: Date?

        if let allowedWeekdays {
            let timeParts = calendar.dateComponents([.hour, .minute, .second], from: scheduledAt)
            var cursor = calendar.startOfDay(for: reference)
            for _ in 0..<400 {
                if let dateOnDay = calendar.date(bySettingHour: timeParts.hour ?? 9, minute: timeParts.minute ?? 0, second: timeParts.second ?? 0, of: cursor) {
                    let weekday = calendar.component(.weekday, from: dateOnDay)
                    let key = FocusRules.dayKey(for: dateOnDay, calendar: calendar)
                    if dateOnDay > scheduledAt && dateOnDay > reference && allowedWeekdays.contains(weekday) && !skippedDates.contains(key) {
                        candidate = dateOnDay
                        break
                    }
                }
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = nextDay
            }
        } else {
            let unit: Calendar.Component = repeatRule == .daily ? .day : .weekOfYear
            let initialSteps = after.map { max(1, calendar.dateComponents([unit], from: scheduledAt, to: $0).value(for: unit) ?? 1) } ?? 1
            var steps = initialSteps
            for _ in 0..<400 {
                guard let date = calendar.date(byAdding: unit, value: steps, to: scheduledAt) else { break }
                let key = FocusRules.dayKey(for: date, calendar: calendar)
                if date > reference && !skippedDates.contains(key) {
                    candidate = date
                    break
                }
                steps += 1
            }
        }

        guard let nextDate = candidate else { return nil }
        var next = self
        next.id = UUID()
        // Completing an occurrence makes this the new head with a new id; the series key stays the same, so the
        // occurrences already detached from it still belong to the series.
        next.seriesID = seriesID ?? id
        next.scheduledAt = nextDate
        if let due = dueDate {
            let diff = due.timeIntervalSince(scheduledAt)
            next.dueDate = nextDate.addingTimeInterval(diff)
        }
        next.completed = false
        next.calendarEventID = nil
        next.calendarSnapshot = nil
        return next
    }

    /// Generates projected future occurrences in `interval` for calendar preview without mutating the stored task.
    public func upcomingOccurrences(in interval: DateInterval, calendar: Calendar = .current, workdays: Set<Int> = [2, 3, 4, 5, 6], maxCount: Int = 60) -> [FocusTask] {
        guard repeatRule != .never, isScheduled, !completed else { return [] }
        var results: [FocusTask] = []
        // Jump straight to the requested window. Walking every occurrence since `scheduledAt` made the cost grow
        // with the age of the series, which the day and week views pay on every redraw.
        var cursor = nextOccurrence(
            after: max(scheduledAt, interval.start.addingTimeInterval(-1)),
            calendar: calendar,
            workdays: workdays
        )
        var safety = 0
        while let next = cursor, results.count < maxCount, safety < 366 {
            safety += 1
            if next.scheduledAt > interval.end { break }
            if next.scheduledAt >= interval.start {
                var previewOccurrence = next
                previewOccurrence.seriesID = self.seriesID ?? self.id
                results.append(previewOccurrence)
            }
            cursor = next.nextOccurrence(after: next.scheduledAt, calendar: calendar, workdays: workdays)
        }
        return results
    }

    /// Detaches a single occurrence at `occurrenceDate` from a recurring series so it can be edited independently.
    public func detachOccurrence(at occurrenceDate: Date, calendar: Calendar = .current, workdays: Set<Int> = [2, 3, 4, 5, 6]) -> (updatedSeries: FocusTask, detachedTask: FocusTask) {
        var series = self
        let key = FocusRules.dayKey(for: occurrenceDate, calendar: calendar)
        series.skippedDates.insert(key)
        if calendar.isDate(occurrenceDate, inSameDayAs: scheduledAt),
           let advanced = series.nextOccurrence(after: scheduledAt, calendar: calendar, workdays: workdays) {
            series.scheduledAt = advanced.scheduledAt
            series.calendarEventID = nil
            series.calendarSnapshot = nil
        }
        var single = self
        single.id = UUID()
        single.scheduledAt = occurrenceDate
        single.repeatRule = .never
        single.repeatDays = []
        single.skippedDates = []
        single.seriesID = self.seriesID ?? self.id
        single.calendarEventID = nil
        single.calendarSnapshot = nil
        return (series, single)
    }
}

public struct FileStamp: Codable, Equatable, Sendable {
    public var modified: Date
    public var bytes: Int64
    public init(modified: Date, bytes: Int64) { self.modified = modified; self.bytes = bytes }
}

public struct Activity: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var appID: String
    public var name: String
    public var title: String?
    public var domain: String?
    public var interruption: Bool
    public var duration: TimeInterval
    public var titleStatus: String?
    public var domainStatus: String?

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        appID: String,
        name: String,
        title: String? = nil,
        domain: String? = nil,
        interruption: Bool = false,
        duration: TimeInterval = 0,
        titleStatus: String? = nil,
        domainStatus: String? = nil
    ) {
        self.id = id
        self.at = at
        self.appID = appID
        self.name = name
        self.title = title
        self.domain = domain
        self.interruption = interruption
        self.duration = duration
        self.titleStatus = titleStatus
        self.domainStatus = domainStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, at, appID, name, title, domain, interruption, duration, titleStatus, domainStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        at = try c.decode(Date.self, forKey: .at)
        appID = try c.decode(String.self, forKey: .appID)
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        interruption = try c.decodeIfPresent(Bool.self, forKey: .interruption) ?? false
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        titleStatus = try c.decodeIfPresent(String.self, forKey: .titleStatus)
        domainStatus = try c.decodeIfPresent(String.self, forKey: .domainStatus)
    }
}

public struct WorkSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var task: FocusTask
    public var startedAt: Date
    public var runningSince: Date?
    public var runningUptime: TimeInterval?
    public var accumulated: TimeInterval
    public var budget: TimeInterval
    public var baseline: [String: FileStamp]
    public var baselineValid: Bool
    public var activities: [Activity]
    public var interruptionCount: Int
    public var inDistractionEpisode: Bool
    public var lastActivityAt: Date?
    public var lastActivityUptime: TimeInterval?
    public var checked: Set<String>
    public var endedAt: Date?
    public var finalChangedFiles: [String]?
    public var finalEvidenceMessage: String?
    public var selectedFiles: [String]
    public var manualFiles: [String]
    /// A pending "I want to stop" on a session protected with a wait. Kept on disk so quitting does not clear it.
    public var stopRequest: StopRequest?
    /// Counts repeated attempts at blocked apps and sites, and hardens the block for a while.
    public var punisher: DistractionPunisher
    /// How many times FocusDesk acted on a distracting app or tab during this session.
    public var blocksApplied: Int
    /// A forward jump of the Mac's clock seen while this session ran, in seconds (for the history).
    public var clockJump: TimeInterval?
    /// Anchors to tell a clock change from real time passing.
    public var wallAnchor: Date
    public var continuousAnchor: Double
    /// Set when macOS closed FocusDesk (restart, shutdown, log-out) in the middle of a protected session: until
    /// this moment the session comes back by itself at the next launch instead of waiting paused.
    public var resumeOnLaunchUntil: Date?

    public init(task: FocusTask, now: Date = Date(), uptime: TimeInterval? = nil, continuous: Double = TrustedClock.continuousSeconds()) {
        self.id = UUID()
        self.task = task
        self.startedAt = now
        self.runningSince = now
        self.runningUptime = uptime
        self.accumulated = 0
        self.budget = Double(task.minutes) * 60
        self.baseline = [:]
        self.baselineValid = false
        self.activities = []
        self.interruptionCount = 0
        self.inDistractionEpisode = false
        self.lastActivityAt = nil
        self.lastActivityUptime = nil
        self.checked = []
        self.endedAt = nil
        self.finalChangedFiles = nil
        self.finalEvidenceMessage = nil
        self.selectedFiles = []
        self.manualFiles = []
        self.stopRequest = nil
        self.punisher = DistractionPunisher()
        self.blocksApplied = 0
        self.clockJump = nil
        self.wallAnchor = now
        self.continuousAnchor = continuous
        self.resumeOnLaunchUntil = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, task, startedAt, runningSince, runningUptime, accumulated, budget
        case baseline, baselineValid, activities, interruptionCount, inDistractionEpisode
        case lastActivityAt, lastActivityUptime, checked, endedAt
        case finalChangedFiles, finalEvidenceMessage, selectedFiles, manualFiles
        case stopRequest, punisher, blocksApplied, clockJump, wallAnchor, continuousAnchor, resumeOnLaunchUntil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try c.decode(FocusTask.self, forKey: .task)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        runningSince = try c.decodeIfPresent(Date.self, forKey: .runningSince)
        runningUptime = try c.decodeIfPresent(TimeInterval.self, forKey: .runningUptime)
        accumulated = try c.decodeIfPresent(TimeInterval.self, forKey: .accumulated) ?? 0
        budget = try c.decodeIfPresent(TimeInterval.self, forKey: .budget) ?? Double(task.minutes) * 60
        baseline = try c.decodeIfPresent([String: FileStamp].self, forKey: .baseline) ?? [:]
        baselineValid = try c.decodeIfPresent(Bool.self, forKey: .baselineValid) ?? false
        activities = try c.decodeIfPresent([Activity].self, forKey: .activities) ?? []
        interruptionCount = try c.decodeIfPresent(Int.self, forKey: .interruptionCount) ?? 0
        inDistractionEpisode = try c.decodeIfPresent(Bool.self, forKey: .inDistractionEpisode) ?? false
        lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt)
        lastActivityUptime = try c.decodeIfPresent(TimeInterval.self, forKey: .lastActivityUptime)
        checked = try c.decodeIfPresent(Set<String>.self, forKey: .checked) ?? []
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        finalChangedFiles = try c.decodeIfPresent([String].self, forKey: .finalChangedFiles)
        finalEvidenceMessage = try c.decodeIfPresent(String.self, forKey: .finalEvidenceMessage)
        selectedFiles = try c.decodeIfPresent([String].self, forKey: .selectedFiles) ?? []
        manualFiles = try c.decodeIfPresent([String].self, forKey: .manualFiles) ?? []
        stopRequest = try c.decodeIfPresent(StopRequest.self, forKey: .stopRequest)
        punisher = try c.decodeIfPresent(DistractionPunisher.self, forKey: .punisher) ?? DistractionPunisher()
        blocksApplied = try c.decodeIfPresent(Int.self, forKey: .blocksApplied) ?? 0
        clockJump = try c.decodeIfPresent(TimeInterval.self, forKey: .clockJump)
        wallAnchor = try c.decodeIfPresent(Date.self, forKey: .wallAnchor) ?? startedAt
        continuousAnchor = try c.decodeIfPresent(Double.self, forKey: .continuousAnchor) ?? TrustedClock.continuousSeconds()
        resumeOnLaunchUntil = try c.decodeIfPresent(Date.self, forKey: .resumeOnLaunchUntil)
    }

    public var paused: Bool { runningSince == nil }

    /// This session is defending itself right now: it is running, has time left and the task asks for it.
    public func enforcing(at now: Date, uptime: TimeInterval? = nil) -> Bool {
        !paused && endedAt == nil && task.enforces && remaining(at: now, uptime: uptime) > 0
    }

    /// When the session would have ended had it kept running, as last saved. Past this moment a protected session
    /// is not worth bringing back on its own: it would have finished anyway.
    public var recoveryDeadline: Date? {
        if let resumeOnLaunchUntil { return resumeOnLaunchUntil }
        guard let runningSince else { return nil }
        return runningSince.addingTimeInterval(budget - accumulated)
    }

    /// A protected session that FocusDesk lost without the user stopping it — killed, crashed or closed by a
    /// restart — and that still has time left. Call it on the session as it was read from disk, before anything
    /// pauses it. Coming back paused used to be a free way out: force-quit, reopen, and the block was gone.
    public func shouldResumeAfterRelaunch(now: Date = Date()) -> Bool {
        guard endedAt == nil, task.protection != .none, budget - accumulated > 0,
              let deadline = recoveryDeadline else { return false }
        return now < deadline
    }

    /// The deadline the Keychain witness is built from, anchored to the clock the user cannot wind forward.
    public func witnessDeadline(at now: Date, uptime: TimeInterval? = nil, continuous: Double = TrustedClock.continuousSeconds()) -> TrustedDeadline {
        TrustedDeadline(seconds: max(0, remaining(at: now, uptime: uptime)), wall: now, continuous: continuous)
    }

    /// Records one applied block, letting the punisher decide whether it is time to make things harder.
    /// Returns true the moment the punisher switches on.
    @discardableResult
    public mutating func registerBlock(at continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        blocksApplied += 1
        guard task.punisherEnabled else { return false }
        return punisher.register(at: continuous)
    }

    /// The block action to apply right now: the one chosen for the task, one step harder while the punisher is on.
    public func activeBlockAction(at continuous: Double = TrustedClock.continuousSeconds()) -> AppBlockAction {
        task.punisherEnabled && punisher.isActive(at: continuous) ? task.blockAction.escalated : task.blockAction
    }

    /// Computes elapsed session work time. Uses monotonic `uptime` when available so wall-clock adjustments cannot distort work duration.
    public func elapsed(at now: Date, uptime: TimeInterval? = nil) -> TimeInterval {
        guard let runningSince else { return accumulated }
        if let uptime, let runningUptime {
            return accumulated + max(0, uptime - runningUptime)
        }
        return accumulated + max(0, now.timeIntervalSince(runningSince))
    }

    public func remaining(at now: Date, uptime: TimeInterval? = nil) -> TimeInterval {
        budget - elapsed(at: now, uptime: uptime)
    }

    private mutating func closeOpenActivityInterval(at now: Date, uptime: TimeInterval? = nil) {
        guard !activities.isEmpty else { return }
        let delta: TimeInterval
        if let uptime, let lastActivityUptime {
            delta = max(0, uptime - lastActivityUptime)
        } else if let lastActivityAt {
            delta = max(0, now.timeIntervalSince(lastActivityAt))
        } else {
            delta = 0
        }
        activities[activities.count - 1].duration += delta
        lastActivityAt = now
        lastActivityUptime = uptime
    }

    public mutating func pause(at now: Date, uptime: TimeInterval? = nil) {
        if !paused {
            closeOpenActivityInterval(at: now, uptime: uptime)
        }
        accumulated = elapsed(at: now, uptime: uptime)
        runningSince = nil
        runningUptime = nil
        lastActivityAt = nil
        lastActivityUptime = nil
        inDistractionEpisode = false
    }

    public mutating func resume(at now: Date, uptime: TimeInterval? = nil) {
        guard runningSince == nil, endedAt == nil else { return }
        runningSince = now
        runningUptime = uptime
        resumeOnLaunchUntil = nil
        lastActivityAt = now
        lastActivityUptime = uptime
        inDistractionEpisode = false
    }

    public mutating func checkpoint(at now: Date, uptime: TimeInterval? = nil) {
        guard !paused, endedAt == nil else { return }
        closeOpenActivityInterval(at: now, uptime: uptime)
        accumulated = elapsed(at: now, uptime: uptime)
        runningSince = now
        runningUptime = uptime
    }

    public mutating func finish(at now: Date, uptime: TimeInterval? = nil) {
        guard endedAt == nil else { return }
        pause(at: now, uptime: uptime)
        endedAt = now
    }

    /// Undoes `finish`: the session runs again from where it stopped. Worked time is kept; the stop is not counted.
    public mutating func reopen(at now: Date, uptime: TimeInterval? = nil) {
        guard endedAt != nil else { return }
        endedAt = nil
        finalChangedFiles = nil
        finalEvidenceMessage = nil
        selectedFiles = []
        resume(at: now, uptime: uptime)
    }

    public mutating func add(minutes: Int) {
        budget += Double(max(0, minutes)) * 60
    }

    public mutating func record(_ activity: Activity, at now: Date? = nil, uptime: TimeInterval? = nil) {
        guard !paused, endedAt == nil else { return }
        let eventTime = now ?? activity.at
        closeOpenActivityInterval(at: eventTime, uptime: uptime)
        if activity.interruption { interruptionCount += 1 }
        activities.append(activity)
        lastActivityAt = eventTime
        lastActivityUptime = uptime
        if activities.count > 3000 { activities.removeFirst(activities.count - 3000) }
    }

    /// Observes the active application and records a single interruption per continuous exit from the allowed workspace.
    /// Returns `true` only when a new distraction episode begins.
    @discardableResult
    public mutating func observeForeground(
        appID: String,
        name: String,
        title: String? = nil,
        titleStatus: String? = nil,
        allowed: Bool,
        at now: Date = Date(),
        uptime: TimeInterval? = nil
    ) -> Bool {
        guard !paused, endedAt == nil else { return false }
        let isNewInterruption: Bool
        if allowed {
            inDistractionEpisode = false
            isNewInterruption = false
        } else {
            isNewInterruption = !inDistractionEpisode
            inDistractionEpisode = true
        }
        let last = activities.last
        let sameSignature = last?.appID == appID && last?.title == title && last?.titleStatus == titleStatus && last?.domain == nil
        if isNewInterruption || !sameSignature {
            record(
                Activity(
                    at: now,
                    appID: appID,
                    name: name,
                    title: title,
                    interruption: isNewInterruption,
                    titleStatus: titleStatus
                ),
                at: now,
                uptime: uptime
            )
        } else {
            closeOpenActivityInterval(at: now, uptime: uptime)
        }
        return isNewInterruption
    }
}

public struct StrictRedirectTracker: Equatable, Sendable {
    public var consecutiveFailures: Int = 0
    public var lastRedirectAt: Date = .distantPast
    public var maxConsecutiveFailures: Int = 3
    public var cooldown: TimeInterval = 1.5

    public init(maxConsecutiveFailures: Int = 3, cooldown: TimeInterval = 1.5) {
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.cooldown = cooldown
    }

    public enum Decision: Equatable, Sendable {
        case none
        case cooldown
        case redirect
        case pauseSession(String)
    }

    public mutating func registerAllowedAppObserved() {
        consecutiveFailures = 0
    }

    public mutating func evaluateUnallowed(hasRunningAllowedApp: Bool, at now: Date) -> Decision {
        guard hasRunningAllowedApp else {
            consecutiveFailures = 0
            return .pauseSession("Sesión pausada: no hay ninguna app permitida abierta. Abre una y reanuda.")
        }
        if consecutiveFailures >= maxConsecutiveFailures {
            consecutiveFailures = 0
            return .pauseSession("Sesión pausada: no se pudo volver a la app permitida tras varios intentos. Así conservas siempre el control.")
        }
        guard now.timeIntervalSince(lastRedirectAt) >= cooldown else {
            return .cooldown
        }
        lastRedirectAt = now
        return .redirect
    }

    public mutating func recordRedirectAttempt(succeeded: Bool) {
        if succeeded {
            // Still increment consecutive attempts if the OS reported true but never actually switched away from the unallowed app;
            // `registerAllowedAppObserved()` resets it to 0 as soon as an allowed app becomes active.
            consecutiveFailures += 1
        } else {
            consecutiveFailures += 1
        }
    }
}

public struct AppUsageSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String { appID }
    public var appID: String
    public var name: String
    public var seconds: TimeInterval
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var session: WorkSession
    public var completed: Bool
    public var cancelled: Bool
    public var note: String
    public var changedFiles: [String]
    public var confirmedFiles: [String]
    public var manualFiles: [String]
    /// Per-app totals kept after the detailed activity is pruned (30 days by default), so the history keeps
    /// "CapCut · 34 min" and its observed time instead of silently dropping to zero.
    public var savedSummaries: [AppUsageSummary]?
    public var savedObservedSeconds: TimeInterval?

    public init(
        session: WorkSession,
        completed: Bool,
        cancelled: Bool = false,
        note: String,
        changedFiles: [String],
        confirmedFiles: [String] = [],
        manualFiles: [String] = []
    ) {
        self.id = session.id
        self.session = session
        self.completed = completed
        self.cancelled = cancelled
        self.note = note
        self.changedFiles = changedFiles
        self.confirmedFiles = confirmedFiles
        self.manualFiles = manualFiles
        self.savedSummaries = nil
        self.savedObservedSeconds = nil
        preserveSummary()
    }

    enum CodingKeys: String, CodingKey {
        case id, session, completed, cancelled, note, changedFiles, confirmedFiles, manualFiles
        case savedSummaries, savedObservedSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSession = try c.decode(WorkSession.self, forKey: .session)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? decodedSession.id
        session = decodedSession
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        changedFiles = try c.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
        confirmedFiles = try c.decodeIfPresent([String].self, forKey: .confirmedFiles) ?? []
        manualFiles = try c.decodeIfPresent([String].self, forKey: .manualFiles) ?? []
        savedSummaries = try c.decodeIfPresent([AppUsageSummary].self, forKey: .savedSummaries)
        savedObservedSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .savedObservedSeconds)
    }

    /// Stores the per-app totals while the detailed activity still exists. Call before clearing activities.
    public mutating func preserveSummary() {
        guard !session.activities.isEmpty else { return }
        savedSummaries = liveSummaries
        savedObservedSeconds = session.activities.reduce(0) { $0 + $1.duration }
    }

    public var observedSeconds: TimeInterval {
        session.activities.isEmpty ? (savedObservedSeconds ?? 0) : session.activities.reduce(0) { $0 + $1.duration }
    }

    public var appSummaries: [AppUsageSummary] {
        session.activities.isEmpty ? (savedSummaries ?? []) : liveSummaries
    }

    /// The checklist as it stood when the session was confirmed: each step and whether it was ticked.
    public var checklistSteps: [(text: String, done: Bool)] {
        session.task.checklist.split(separator: "\n").map(String.init).enumerated().map { index, text in
            (text, session.checked.contains(String(index)))
        }
    }

    private var liveSummaries: [AppUsageSummary] {
        var totals: [String: (name: String, seconds: TimeInterval)] = [:]
        for act in session.activities where act.duration > 0 {
            let current = totals[act.appID] ?? (act.name, 0)
            totals[act.appID] = (current.name, current.seconds + act.duration)
        }
        return totals.map { AppUsageSummary(appID: $0.key, name: $0.value.name, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }
}

public enum HotKeyTarget: String, Codable, CaseIterable, Sendable {
    case mainWindow, compactPanel
    public var label: String {
        switch self {
        case .mainWindow: return "Ventana principal (planificador)"
        case .compactPanel: return "Panel compacto (barra de menús)"
        }
    }
}

public struct HotKeyPreset: Equatable, Identifiable, Sendable {
    public var id: String { label }
    public var label: String
    public var keyCode: UInt32
    public var modifiers: UInt32

    public static let presets: [HotKeyPreset] = [
        // Only three-modifier combinations: a global shortcut is captured before the frontmost app sees it, so ⇧⌘F
        // or ⌥⌘F silently broke "Find in files" in VS Code and Xcode. None of these clashes with ⌃⌥⌘P/T/S/M/A.
        HotKeyPreset(label: "⌃⌥⌘F", keyCode: 3, modifiers: 4096 | 2048 | 256),       // controlKey | optionKey | cmdKey + F
        HotKeyPreset(label: "⌃⌥⌘Espacio", keyCode: 49, modifiers: 4096 | 2048 | 256), // controlKey | optionKey | cmdKey + Space
        HotKeyPreset(label: "⌃⌥⌘J", keyCode: 38, modifiers: 4096 | 2048 | 256),      // controlKey | optionKey | cmdKey + J
        HotKeyPreset(label: "⌃⌥⌘K", keyCode: 40, modifiers: 4096 | 2048 | 256)       // controlKey | optionKey | cmdKey + K
    ]

    /// True for combinations the app no longer offers because they override shortcuts of other apps.
    public static func isRetired(modifiers: UInt32) -> Bool {
        modifiers & (4096 | 2048 | 256) != (4096 | 2048 | 256)
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var calendarID: String?
    public var observeTitles: Bool
    public var observeBrave: Bool
    public var detailDays: Int
    public var excludedTitleApps: [AllowedApp]
    public var hotKeyEnabled: Bool
    public var hotKeyCode: UInt32
    public var hotKeyModifiers: UInt32
    public var hotKeyLabel: String
    public var hotKeyTarget: HotKeyTarget
    public var categories: [CategoryItem]
    public var workdays: Set<Int>
    public var workStartHour: Int
    public var workEndHour: Int
    public var breaks: [BreakPeriod]
    /// Text size multiplier (1, 1.15, 1.3): macOS has no Dynamic Type, so the app offers its own.
    public var textScale: Double
    /// Whether the countdown lives in the menu bar; people decide that, not the app.
    public var showMenuBarItem: Bool
    /// Turns Do Not Disturb on while a session blocks distracting apps (strict mode), through two shortcuts.
    public var focusDuringStrict: Bool
    /// Also looks at windows that are on screen without the keyboard focus (a video in the corner, a second
    /// monitor), not only at the app in front.
    public var watchBackgroundWindows: Bool
    /// Reads the address of web pages opened inside apps built on Electron (Discord, Slack, Notion…) and of
    /// Chromium web apps, so a blocked site cannot come back in disguise.
    public var inspectEmbeddedPages: Bool
    /// Keeps a login item that brings FocusDesk back if it is killed while a protected session is running.
    public var relaunchGuard: Bool
    /// Emergency codes used, with the day they were used on: an escape hatch that leaves a trace.
    public var emergencyUses: [String]
    /// Minutes before a protected task starts from which it already defends itself (`RunUp`); 0 switches it off.
    public var runUpMinutes: Int
    /// Shows an active break timer banner/alert when a scheduled `BreakPeriod` is running.
    public var enforceBreaks: Bool
    /// Shows a discreet floating countdown pill on screen when consuming a daily limit, launch visit or micro-pause (`showTimer` in FocusMe).
    public var showFloatingTimerPill: Bool
    /// Sends pre-block warnings when 5 min and 1 min remain on a daily limit or launch visit (`timeLimitReminders` in FocusMe).
    public var preBlockRemindersEnabled: Bool
    /// Triggers a rest break after `continuousWorkMinutes` of continuous screen usage (`tickAsScreenBreak` in FocusMe).
    public var continuousBreakEnabled: Bool
    /// Minutes of continuous work before a screen break triggers (`15...180`).
    public var continuousWorkMinutes: Int
    /// Duration of each continuous screen break in minutes (`1...30`).
    public var continuousBreakDurationMinutes: Int
    /// Maximum number of times per day the user can skip a continuous screen break (`0...10`, `skipCount` in FocusMe).
    public var continuousBreakMaxSkipsPerDay: Int
    /// Motivational messages rotated during breaks (`breakMessages` / `pickBreakMessage` in FocusMe).
    public var breakMessages: [String]

    public static let defaultBreakMessages: [String] = [
        "Descansa la vista 20 segundos mirando a lo lejos.",
        "Levántate, estira los hombros y bebe un vaso de agua.",
        "Respira hondo tres veces: el descanso también es parte del foco.",
        "Suelta el teclado un momento para volver con la mente despejada."
    ]

    public init() {
        self.calendarID = nil
        self.observeTitles = false
        self.observeBrave = false
        self.detailDays = 30
        self.excludedTitleApps = []
        self.hotKeyEnabled = true
        self.hotKeyCode = 3
        self.hotKeyModifiers = 4096 | 2048 | 256
        self.hotKeyLabel = "⌃⌥⌘F"
        self.hotKeyTarget = .mainWindow
        self.categories = CategoryItem.defaults
        self.workdays = [2, 3, 4, 5, 6]
        self.workStartHour = 9
        self.workEndHour = 19
        self.breaks = [BreakPeriod(title: "Descanso / Comida", startHour: 14, startMinute: 0, durationMinutes: 60)]
        self.textScale = 1
        self.showMenuBarItem = true
        self.focusDuringStrict = true
        self.watchBackgroundWindows = true
        self.inspectEmbeddedPages = true
        self.relaunchGuard = false
        self.emergencyUses = []
        self.runUpMinutes = RunUp.defaultMinutes
        self.enforceBreaks = true
        self.showFloatingTimerPill = true
        self.preBlockRemindersEnabled = true
        self.continuousBreakEnabled = false
        self.continuousWorkMinutes = 50
        self.continuousBreakDurationMinutes = 5
        self.continuousBreakMaxSkipsPerDay = 2
        self.breakMessages = Self.defaultBreakMessages
    }

    enum CodingKeys: String, CodingKey {
        case calendarID, observeTitles, observeBrave, detailDays, excludedTitleApps
        case hotKeyEnabled, hotKeyCode, hotKeyModifiers, hotKeyLabel, hotKeyTarget
        case categories, workdays, workStartHour, workEndHour, breaks, textScale, showMenuBarItem, focusDuringStrict
        case watchBackgroundWindows, inspectEmbeddedPages, relaunchGuard, emergencyUses, runUpMinutes
        case enforceBreaks, showFloatingTimerPill, preBlockRemindersEnabled
        case continuousBreakEnabled, continuousWorkMinutes, continuousBreakDurationMinutes, continuousBreakMaxSkipsPerDay, breakMessages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calendarID = try c.decodeIfPresent(String.self, forKey: .calendarID)
        observeTitles = try c.decodeIfPresent(Bool.self, forKey: .observeTitles) ?? false
        observeBrave = try c.decodeIfPresent(Bool.self, forKey: .observeBrave) ?? false
        detailDays = try c.decodeIfPresent(Int.self, forKey: .detailDays) ?? 30
        excludedTitleApps = try c.decodeIfPresent([AllowedApp].self, forKey: .excludedTitleApps) ?? []
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? true
        hotKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyCode) ?? 3
        hotKeyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .hotKeyModifiers) ?? (4096 | 2048 | 256)
        hotKeyLabel = try c.decodeIfPresent(String.self, forKey: .hotKeyLabel) ?? "⌃⌥⌘F"
        hotKeyTarget = try c.decodeIfPresent(HotKeyTarget.self, forKey: .hotKeyTarget) ?? .mainWindow
        categories = try c.decodeIfPresent([CategoryItem].self, forKey: .categories) ?? CategoryItem.defaults
        workdays = try c.decodeIfPresent(Set<Int>.self, forKey: .workdays) ?? [2, 3, 4, 5, 6]
        workStartHour = try c.decodeIfPresent(Int.self, forKey: .workStartHour) ?? 9
        workEndHour = try c.decodeIfPresent(Int.self, forKey: .workEndHour) ?? 19
        breaks = try c.decodeIfPresent([BreakPeriod].self, forKey: .breaks) ?? [BreakPeriod(title: "Descanso / Comida", startHour: 14, startMinute: 0, durationMinutes: 60)]
        textScale = min(1.3, max(1, try c.decodeIfPresent(Double.self, forKey: .textScale) ?? 1))
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? true
        focusDuringStrict = try c.decodeIfPresent(Bool.self, forKey: .focusDuringStrict) ?? true
        watchBackgroundWindows = try c.decodeIfPresent(Bool.self, forKey: .watchBackgroundWindows) ?? true
        inspectEmbeddedPages = try c.decodeIfPresent(Bool.self, forKey: .inspectEmbeddedPages) ?? true
        relaunchGuard = try c.decodeIfPresent(Bool.self, forKey: .relaunchGuard) ?? false
        emergencyUses = try c.decodeIfPresent([String].self, forKey: .emergencyUses) ?? []
        runUpMinutes = RunUp.clampedMinutes(try c.decodeIfPresent(Int.self, forKey: .runUpMinutes) ?? RunUp.defaultMinutes)
        enforceBreaks = try c.decodeIfPresent(Bool.self, forKey: .enforceBreaks) ?? true
        showFloatingTimerPill = try c.decodeIfPresent(Bool.self, forKey: .showFloatingTimerPill) ?? true
        preBlockRemindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .preBlockRemindersEnabled) ?? true
        continuousBreakEnabled = try c.decodeIfPresent(Bool.self, forKey: .continuousBreakEnabled) ?? false
        continuousWorkMinutes = max(15, min(180, try c.decodeIfPresent(Int.self, forKey: .continuousWorkMinutes) ?? 50))
        continuousBreakDurationMinutes = max(1, min(30, try c.decodeIfPresent(Int.self, forKey: .continuousBreakDurationMinutes) ?? 5))
        continuousBreakMaxSkipsPerDay = max(0, min(10, try c.decodeIfPresent(Int.self, forKey: .continuousBreakMaxSkipsPerDay) ?? 2))
        let decodedMessages = try c.decodeIfPresent([String].self, forKey: .breakMessages) ?? Self.defaultBreakMessages
        breakMessages = decodedMessages.isEmpty ? Self.defaultBreakMessages : decodedMessages
    }
}

public enum PendingCalendarAction: String, Codable, Equatable, Sendable {
    case upsert
    case remove
}

public struct PendingCalendarOp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { taskID }
    public var taskID: UUID
    public var action: PendingCalendarAction
    public var snapshot: CalendarSnapshot?
    public var eventID: String?
    public var baselineSnapshot: CalendarSnapshot?
    public var force: Bool
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(
        taskID: UUID,
        action: PendingCalendarAction,
        snapshot: CalendarSnapshot? = nil,
        eventID: String? = nil,
        baselineSnapshot: CalendarSnapshot? = nil,
        force: Bool = false,
        attempts: Int = 0,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.taskID = taskID
        self.action = action
        self.snapshot = snapshot
        self.eventID = eventID
        self.baselineSnapshot = baselineSnapshot
        self.force = force
        self.attempts = attempts
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// Decodes an array keeping every element that reads and skipping (and counting) the ones that do not, so one
/// damaged task does not make the whole agenda unreadable.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)   // advances past the unreadable element
                skipped += 1
            }
        }
    }
}

public struct Workspace: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public var schema: Int
    public var tasks: [FocusTask]
    public var profiles: [FocusProfile]
    public var session: WorkSession?
    public var history: [SessionRecord]
    public var settings: Settings
    public var pendingCalendarOps: [PendingCalendarOp]
    /// General blocking rules & daily limit timers that work independently of agenda tasks.
    public var generalRules: [GeneralBlockRule]
    /// Daily usage seconds per rule: `[dayKey: [ruleID.uuidString: seconds]]`.
    public var dailyRuleUsage: [String: [String: TimeInterval]]
    /// Daily launch counts per rule: `[dayKey: [ruleID.uuidString: launches]]`.
    public var dailyRuleLaunches: [String: [String: Int]]
    /// Daily micro-pauses used per rule: `[dayKey: [ruleID.uuidString: pauses]]`.
    public var dailyMicroPausesUsed: [String: [String: Int]]
    /// Daily skips used for continuous screen breaks: `[dayKey: skips]`.
    public var dailyContinuousBreakSkips: [String: Int]
    /// Auto-expiring temporary allow entries (`setAllowExpiryMinutes` in FocusMe).
    public var temporaryAllows: [TemporaryAllowEntry]
    /// Elements that could not be read when this workspace was loaded (not saved). Above zero, the app keeps a copy
    /// of the original file before writing anything.
    public var decodingSkipped = 0

    public init() {
        self.schema = Self.currentSchema
        self.tasks = []
        self.profiles = FocusProfile.defaults
        self.session = nil
        self.history = []
        self.settings = Settings()
        self.pendingCalendarOps = []
        self.generalRules = GeneralBlockRule.defaults
        self.dailyRuleUsage = [:]
        self.dailyRuleLaunches = [:]
        self.dailyMicroPausesUsed = [:]
        self.dailyContinuousBreakSkips = [:]
        self.temporaryAllows = []
    }

    enum CodingKeys: String, CodingKey {
        case schema, tasks, profiles, session, history, settings, pendingCalendarOps
        case generalRules, dailyRuleUsage, dailyRuleLaunches, dailyMicroPausesUsed
        case dailyContinuousBreakSkips, temporaryAllows
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        let lossyTasks = try c.decodeIfPresent(LossyArray<FocusTask>.self, forKey: .tasks)
        let lossyProfiles = try c.decodeIfPresent(LossyArray<FocusProfile>.self, forKey: .profiles)
        let lossyHistory = try c.decodeIfPresent(LossyArray<SessionRecord>.self, forKey: .history)
        let lossyOps = try c.decodeIfPresent(LossyArray<PendingCalendarOp>.self, forKey: .pendingCalendarOps)
        let lossyRules = try c.decodeIfPresent(LossyArray<GeneralBlockRule>.self, forKey: .generalRules)
        tasks = lossyTasks?.elements ?? []
        profiles = lossyProfiles?.elements ?? FocusProfile.defaults
        // A damaged running session is dropped rather than blocking everything; it is counted below.
        let readableSession = try? c.decodeIfPresent(WorkSession.self, forKey: .session)
        session = readableSession ?? nil
        history = lossyHistory?.elements ?? []
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
        pendingCalendarOps = lossyOps?.elements ?? []
        generalRules = lossyRules?.elements ?? GeneralBlockRule.defaults
        dailyRuleUsage = (try? c.decodeIfPresent([String: [String: TimeInterval]].self, forKey: .dailyRuleUsage)) ?? [:]
        dailyRuleLaunches = (try? c.decodeIfPresent([String: [String: Int]].self, forKey: .dailyRuleLaunches)) ?? [:]
        dailyMicroPausesUsed = (try? c.decodeIfPresent([String: [String: Int]].self, forKey: .dailyMicroPausesUsed)) ?? [:]
        dailyContinuousBreakSkips = (try? c.decodeIfPresent([String: Int].self, forKey: .dailyContinuousBreakSkips)) ?? [:]
        temporaryAllows = (try? c.decodeIfPresent([TemporaryAllowEntry].self, forKey: .temporaryAllows)) ?? []
        let brokenSession = c.contains(.session) && readableSession == nil && (try? c.decodeNil(forKey: .session)) != true ? 1 : 0
        decodingSkipped = (lossyTasks?.skipped ?? 0) + (lossyProfiles?.skipped ?? 0) + (lossyHistory?.skipped ?? 0)
            + (lossyOps?.skipped ?? 0) + (lossyRules?.skipped ?? 0) + brokenSession
    }

    public func usedSecondsToday(for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        return dailyRuleUsage[key]?[ruleID.uuidString] ?? 0
    }

    @discardableResult
    public mutating func addUsedSeconds(_ delta: TimeInterval, for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        var dayMap = dailyRuleUsage[key] ?? [:]
        let updated = max(0, (dayMap[ruleID.uuidString] ?? 0) + max(0, delta))
        dayMap[ruleID.uuidString] = updated
        dailyRuleUsage[key] = dayMap
        return updated
    }

    public func launchesToday(for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        return dailyRuleLaunches[key]?[ruleID.uuidString] ?? 0
    }

    @discardableResult
    public mutating func incrementLaunches(for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        var dayMap = dailyRuleLaunches[key] ?? [:]
        let updated = (dayMap[ruleID.uuidString] ?? 0) + 1
        dayMap[ruleID.uuidString] = updated
        dailyRuleLaunches[key] = dayMap
        return updated
    }

    public func microPausesUsedToday(for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        return dailyMicroPausesUsed[key]?[ruleID.uuidString] ?? 0
    }

    @discardableResult
    public mutating func incrementMicroPauses(for ruleID: UUID, at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        var dayMap = dailyMicroPausesUsed[key] ?? [:]
        let updated = (dayMap[ruleID.uuidString] ?? 0) + 1
        dayMap[ruleID.uuidString] = updated
        dailyMicroPausesUsed[key] = dayMap
        return updated
    }

    public func continuousBreakSkipsToday(at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        return dailyContinuousBreakSkips[key] ?? 0
    }

    @discardableResult
    public mutating func incrementContinuousBreakSkips(at now: Date = Date(), calendar: Calendar = .current) -> Int {
        let key = FocusRules.dayKey(for: now, calendar: calendar)
        let updated = (dailyContinuousBreakSkips[key] ?? 0) + 1
        dailyContinuousBreakSkips[key] = updated
        return updated
    }

    public func isTemporarilyAllowed(
        host: String,
        path: String = "",
        at now: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> Bool {
        temporaryAllows.contains { entry in
            !entry.isAppBundleID && entry.isActive(wall: now, continuous: continuous)
                && FocusRules.entryMatches(host: host, path: path, entry: entry.target)
        }
    }

    public func isTemporarilyAllowed(
        bundleID: String,
        at now: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> Bool {
        temporaryAllows.contains { entry in
            entry.isAppBundleID && entry.isActive(wall: now, continuous: continuous) && entry.target == bundleID
        }
    }

    public mutating func pruneExpiredTemporaryAllows(
        at now: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        temporaryAllows.removeAll { !$0.isActive(wall: now, continuous: continuous) }
    }

    public mutating func prune(at now: Date) {
        let days = max(1, settings.detailDays)
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        for index in history.indices where (history[index].session.endedAt ?? now) < cutoff {
            history[index].preserveSummary()
            history[index].session.activities = []
            history[index].session.baseline = [:]
        }
        let minDayKey = FocusRules.dayKey(for: cutoff)
        dailyRuleUsage = dailyRuleUsage.filter { $0.key >= minDayKey }
        dailyRuleLaunches = dailyRuleLaunches.filter { $0.key >= minDayKey }
        dailyMicroPausesUsed = dailyMicroPausesUsed.filter { $0.key >= minDayKey }
        dailyContinuousBreakSkips = dailyContinuousBreakSkips.filter { $0.key >= minDayKey }
        pruneExpiredTemporaryAllows(at: now)
    }

    public mutating func enqueueCalendarOp(_ op: PendingCalendarOp) {
        if let index = pendingCalendarOps.firstIndex(where: { $0.taskID == op.taskID }) {
            pendingCalendarOps[index] = op
        } else {
            pendingCalendarOps.append(op)
        }
    }

    public mutating func clearCalendarOp(for taskID: UUID) {
        pendingCalendarOps.removeAll { $0.taskID == taskID }
    }
}

public enum FocusRules {
    public static let systemExemptBundleIDs: Set<String> = [
        "local.focusdesk.app",
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.Settings",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.CoreServicesUIAgent",
        "com.apple.universalaccessAuthWarn",
        "com.apple.TCC",
        "com.apple.notificationcenterui",
        // Shows notification alerts and permission prompts; answering one is not leaving the task (it counted as an
        // interruption in a real strict session).
        "com.apple.UserNotificationCenter",
        "com.apple.controlcenter",
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        // The open and save panels of some apps run in this separate process; one of FocusDesk's own panels left
        // open must neither be hidden nor stop the block.
        "com.apple.appkit.xpc.openAndSavePanelService",
        "com.apple.WindowManager",
        "com.vorssaint.utils",
        // Assistive tools must never count as a distraction: adjusting your screen reader is not leaving the task.
        "com.apple.VoiceOverUtility",
        "com.apple.VoiceOver",
        "com.apple.AccessibilityInspector"
    ]

    /// Apps FocusDesk may hide but must never close or force to quit. A wildcard rule that reached these would
    /// leave the Mac unusable, so — like FocusMe's `isExcludedTargetProcess` — the list is fixed in code.
    public static let neverTerminateBundleIDs: Set<String> = [
        "local.focusdesk.app",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.systempreferences",
        "com.apple.Settings",
        "com.apple.SecurityAgent",
        "com.apple.Spotlight",
        "com.apple.universalaccessAuthWarn",
        "com.apple.VoiceOver",
        "com.apple.VoiceOverUtility",
        "com.apple.AccessibilityInspector",
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]

    /// The action that may actually be applied to `bundleID`: anything on the list above is only ever hidden,
    /// however hard the task asks.
    public static func safeAction(_ action: AppBlockAction, for bundleID: String) -> AppBlockAction {
        neverTerminateBundleIDs.contains(bundleID) ? .hide : action
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        // Truncate like every other timer: a countdown has to pass through 00:00 instead of jumping from 00:01 to +00:01.
        let value = Int(abs(seconds))
        let prefix = seconds <= -1 ? "+" : ""
        return value >= 3600
            ? String(format: "%@%d:%02d:%02d", prefix, value / 3600, value / 60 % 60, value % 60)
            : String(format: "%@%02d:%02d", prefix, value / 60, value % 60)
    }

    /// Normalizes a domain or domain+subpath token:
    /// - Full URLs with scheme (`"https://www.claude.ai/chat?x=1"`) normalize to their domain (`"claude.ai"`).
    /// - Bare domain+subpath entries (`"youtube.com/shorts"`, `"www.instagram.com/reels/"`) preserve the subpath (`"youtube.com/shorts"`).
    public static func normalizeDomainEntry(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
        guard !token.isEmpty else { return nil }
        if token.hasPrefix("*.") {
            token = String(token.dropFirst(2))
        }
        let hostCandidate: String
        var pathCandidate = ""
        if token.contains("://"), let url = URL(string: token), let host = url.host {
            hostCandidate = host
        } else if token.contains("/"), !token.contains("://") {
            let parts = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            hostCandidate = String(parts[0])
            if parts.count > 1 {
                var sub = String(parts[1])
                if let q = sub.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                    sub = String(sub[..<q])
                }
                sub = sub.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                if !sub.isEmpty {
                    pathCandidate = "/" + sub
                }
            }
        } else if (token.contains(":") || token.contains("?")),
                  let url = URL(string: "https://" + token), let host = url.host {
            hostCandidate = host
        } else {
            hostCandidate = token
        }
        var cleaned = hostCandidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleaned.hasPrefix("www.") && cleaned.dropFirst(4).contains(".") {
            cleaned = String(cleaned.dropFirst(4))
        }
        guard cleaned.contains("."),
              !cleaned.contains(" "),
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              !cleaned.hasPrefix("-"),
              !cleaned.hasSuffix("-") else {
            return nil
        }
        if !pathCandidate.isEmpty {
            let validPath = pathCandidate.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "/" || $0 == "-" || $0 == "_" || $0 == "." || $0 == "~"
            }
            guard validPath else { return nil }
            return cleaned + pathCandidate
        }
        return cleaned
    }

    public static func parseDomains(_ list: String) -> (valid: [String], invalid: [String]) {
        let rawTokens = list.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).map(String.init)
        var valid: [String] = []
        var invalid: [String] = []
        for token in rawTokens where !token.isEmpty {
            if let norm = normalizeDomainEntry(token) {
                if !valid.contains(norm) { valid.append(norm) }
            } else {
                invalid.append(token)
            }
        }
        return (valid, invalid)
    }

    public static func normalizeDomains(_ list: String) -> String {
        parseDomains(list).valid.joined(separator: ", ")
    }

    /// True when `(host, path)` matches a normalized domain or domain+subpath entry (`"youtube.com"` or `"youtube.com/shorts"`).
    public static func entryMatches(host: String, path: String = "", entry: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty else { return false }
        let parts = entry.lowercased().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let entryHost = String(parts[0])
        let hostMatch = normalizedHost == entryHost || normalizedHost.hasSuffix("." + entryHost)
        guard hostMatch else { return false }
        if parts.count > 1, !parts[1].isEmpty {
            let entryPath = "/" + String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var normPath = path.lowercased()
            if let q = normPath.firstIndex(where: { $0 == "?" || $0 == "#" }) {
                normPath = String(normPath[..<q])
            }
            if !normPath.hasPrefix("/") { normPath = "/" + normPath }
            while normPath.count > 1 && normPath.hasSuffix("/") { normPath.removeLast() }
            return normPath == entryPath || normPath.hasPrefix(entryPath + "/")
        }
        return true
    }

    public static func domainAllowed(_ host: String, list: String) -> Bool {
        webAllowed(host: host, path: "", list: list, mode: .allowListed)
    }

    /// Evaluates whether a tab at `(host, path)` is allowed under the given `WebListMode`.
    public static func webAllowed(host: String, path: String = "", list: String, mode: WebListMode = .allowListed) -> Bool {
        switch mode {
        case .blockAll:
            return false
        case .allowListed:
            let parsed = parseDomains(list).valid
            guard !parsed.isEmpty else { return true }
            return parsed.contains { entryMatches(host: host, path: path, entry: $0) }
        case .blockListed:
            let parsed = parseDomains(list).valid
            guard !parsed.isEmpty else { return true }
            return !parsed.contains { entryMatches(host: host, path: path, entry: $0) }
        }
    }

    /// Evaluates whether `bundleID` is allowed under the given `AppListMode`.
    public static func appAllowed(bundleID: String, apps: [AllowedApp], mode: AppListMode) -> Bool {
        if systemExemptBundleIDs.contains(bundleID) { return true }
        let inList = apps.contains { $0.id == bundleID }
        switch mode {
        case .allowListed: return inList
        case .blockListed: return !inList
        }
    }

    /// Splits a comma/semicolon/newline-separated string of window title keywords.
    public static func parseTitleKeywords(_ raw: String) -> [String] {
        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        var result: [String] = []
        for token in tokens {
            let key = token.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            if seen.insert(key).inserted {
                result.append(token)
            }
        }
        return result
    }

    public static func normalizeTitleKeywords(_ raw: String) -> String {
        parseTitleKeywords(raw).joined(separator: ", ")
    }

    /// Returns the first keyword from `keywords` that appears in `title` (case- and accent-insensitive), or `nil`.
    public static func matchesTitleKeyword(_ title: String?, keywords: String) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let list = parseTitleKeywords(keywords)
        guard !list.isEmpty else { return nil }
        let foldedTitle = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
        return list.first { kw in
            let foldedKw = kw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            return !foldedKw.isEmpty && foldedTitle.contains(foldedKw)
        }
    }

    public static func changed(before: [String: FileStamp], after: [String: FileStamp]) -> [String] {
        after.keys.filter { before[$0] != after[$0] }.sorted()
    }

    public static func overlaps(_ a: FocusTask, _ b: FocusTask) -> Bool {
        a.id != b.id && a.isScheduled && b.isScheduled && !a.completed && !b.completed && a.scheduledAt < b.end && b.scheduledAt < a.end
    }

    /// Minute a block lands on when dropped inside an hour row, in `step`-minute increments, so it lands where
    /// you aimed instead of always snapping to the top of the hour.
    public static func dropMinute(offset: Double, rowHeight: Double, step: Int = 5) -> Int {
        guard rowHeight > 0, step > 0, step < 60, offset.isFinite else { return 0 }
        let fraction = max(0, min(59, Int((offset / rowHeight) * 60)))
        return min(60 - step, (fraction / step) * step)
    }

    /// Durations the planner offers: 5-minute steps from 5 minutes to 12 hours. Older tasks below 5 minutes stay
    /// valid (see `FocusTask.valid`), but every control proposes and clamps to this range.
    public static let minutesRange = 5...720

    public static func clampedMinutes(_ minutes: Int) -> Int {
        max(minutesRange.lowerBound, min(minutesRange.upperBound, minutes))
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Selects the most relevant next task without letting old overdue tasks hide an upcoming task today.
    public static func nextSuggestedTask(tasks: [FocusTask], sessionTaskID: UUID?, now: Date, calendar: Calendar = .current) -> FocusTask? {
        let pending = tasks.filter { !$0.completed && $0.id != sessionTaskID }
        guard !pending.isEmpty else { return nil }

        let scheduled = pending.filter(\.isScheduled)
        let unscheduled = pending.filter { !$0.isScheduled }

        // 1. Imminent or recently due scheduled tasks (from 2 hours ago up to 90 minutes ahead)
        let imminentWindowStart = now.addingTimeInterval(-2 * 3600)
        let imminentWindowEnd = now.addingTimeInterval(90 * 60)
        let imminent = scheduled.filter { $0.scheduledAt >= imminentWindowStart && $0.scheduledAt <= imminentWindowEnd }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        if let firstImminent = imminent.first { return firstImminent }

        // 2. Other tasks scheduled for today (future today first, then earlier today)
        let todayScheduled = scheduled.filter { calendar.isDate($0.scheduledAt, inSameDayAs: now) }
        if let nextTodayFuture = todayScheduled.filter({ $0.scheduledAt > now }).min(by: { $0.scheduledAt < $1.scheduledAt }) {
            return nextTodayFuture
        }
        if let earlierToday = todayScheduled.max(by: { $0.scheduledAt < $1.scheduledAt }) {
            return earlierToday
        }

        // 3. Unscheduled tasks with a due date today or overdue
        if let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let urgentUnscheduled = unscheduled.filter({ ($0.dueDate ?? .distantFuture) < endOfToday })
               .min(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
            return urgentUnscheduled
        }

        // 4. Future scheduled tasks before ancient overdue tasks if within the next 24h
        if let upcoming24h = scheduled.filter({ $0.scheduledAt > now && $0.scheduledAt <= now.addingTimeInterval(86400) })
            .min(by: { $0.scheduledAt < $1.scheduledAt }) {
            return upcoming24h
        }

        // 5. Fallback: earliest scheduled task or first unscheduled task
        if let earliestScheduled = scheduled.min(by: { $0.scheduledAt < $1.scheduledAt }) {
            return earliestScheduled
        }
        return unscheduled.sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }.first
    }
}
