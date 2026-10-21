import AppKit
import Combine
import EventKit
import FocusCore

enum NextTransitionAction: Equatable {
    case keepSchedule
    case startNextNow
    case rest10Min
}

@MainActor
final class AppModel: ObservableObject {
    @Published var workspace = Workspace()
    @Published var now = Date()
    @Published var error: String?
    @Published var notice: String?
    @Published var evidenceMessage: String?
    @Published var changedFiles: [String] = []
    @Published var writingFiles: [String] = []
    @Published var selectedDeliverables: Set<String> = []
    @Published var manualAttachments: [String] = []
    @Published var busy = false
    @Published var page = "Hoy"
    @Published var selectedDate = Date()
    @Published var editingTask: FocusTask?
    @Published var showCompletion = false
    @Published var accessible = MacActivity.accessibility
    @Published var braveStatus = "En espera"
    @Published var hasUnsavedChanges = false
    @Published var corruptFileDetected = false
    /// Task the user asked to start while another session was running. Drives the explicit hand-off question.
    @Published var handoffRequest: FocusTask?
    /// Stays on screen until acted upon, unlike `notice`, so a session paused by the Mac is never missed.
    @Published var resumePrompt: String?
    /// True while ⌃⌥⌘P and ⌃⌥⌘T are registered system-wide for the running session (set by the app delegate).
    var sessionHotKeysActive = false
    /// The Hoy banner about disabled reminders can be hidden for this launch.
    @Published var notificationBannerDismissed = false
    private var askedForNotifications = false
    /// Allowed apps offered as "Abrir …" buttons next to `resumePrompt` (strict pause with no allowed app open).
    @Published var promptApps: [AllowedApp] = []
    private var lastDistractionNotifyAt = Date.distantPast
    /// Host of the current visit outside the task's domains; one interruption and one notice per visit.
    private var domainEpisodeHost: String?
    private var screenIsLocked = false
    /// Tasks already started on their own (or skipped because another session was running), so it happens once.
    private var autoStartHandled: Set<String> = []

    /// One step of undo for direct agenda edits (drag, snooze, inbox, delete). Only valid while nothing else changed
    /// the agenda since, so it can never revert an unrelated edit made afterwards.
    struct AgendaUndo {
        let label: String
        let before: [FocusTask]
        var after: [FocusTask]
    }
    @Published private(set) var agendaUndo: AgendaUndo?

    let calendar = CalendarBridge()
    let reminders = ReminderService()
    let scanner = EvidenceScanner()
    let brave = BraveReader()
    let store: WorkspaceStore
    let preview: Bool

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var lastPrunedDay = Calendar.current.startOfDay(for: Date())
    private var writable = true
    private var lastAllowed: NSRunningApplication?
    private var strictTracker = StrictRedirectTracker()
    private var ticks = 0
    private var overtimeNotified = false
    private var hasInitialBaseline = false
    /// Task to start once the current session's result is confirmed (set by an accepted hand-off).
    private var queuedStartTaskID: UUID?
    /// True when the pause came from the Mac (sleep, lock, user switch) and not from the user pressing Pausar.
    private var pausedBySystem = false
    private var dayCache: [String: (real: [FocusTask], projected: [FocusTask])] = [:]
    var showWindow: (() -> Void)?
    var toggleCompactPanel: (() -> Void)?
    var onHotKeySettingsChanged: (() -> Void)?

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(directory: URL? = nil, preview: Bool = false) {
        self.preview = preview
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusDesk")
        store = WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
        do {
            workspace = try store.load()
            workspace.prune(at: Date())
            if workspace.session != nil {
                // Only intervals persisted before termination can count after recovery.
                workspace.session?.runningSince = nil
                workspace.session?.runningUptime = nil
                // The design promises to offer it back. A notice vanished after 7 s — often before the window was
                // even looked at when FocusDesk opens at login — leaving only "Pausa" in the menu bar.
                if let recovered = workspace.session, recovered.endedAt == nil {
                    let remaining = FocusRules.clock(max(0, recovered.remaining(at: Date())))
                    resumePrompt = "«\(recovered.task.title)» quedó a medias al cerrarse FocusDesk. Te quedan \(remaining). ¿Reanudamos?"
                    pausedBySystem = true
                }
                if let recovered = workspace.session, recovered.endedAt != nil {
                    changedFiles = recovered.finalChangedFiles ?? []
                    selectedDeliverables = Set(recovered.selectedFiles)
                    manualAttachments = recovered.manualFiles
                    evidenceMessage = recovered.finalEvidenceMessage ?? (recovered.finalChangedFiles == nil ? "La revisión de archivos no llegó a guardarse. Confirma el resultado manualmente." : nil)
                    showCompletion = true
                }
            }
        } catch {
            writable = false
            corruptFileDetected = true
            self.error = "No se han podido leer tus datos. Se han conservado intactos en \(store.url.path). Puedes recuperar la última copia automática o importar un respaldo desde el aviso o Ajustes. (\(error.localizedDescription))"
        }
        hasInitialBaseline = workspace.session?.baselineValid ?? false
        // Shortcuts like ⇧⌘F or ⌥⌘F are no longer offered: they hijacked other apps' commands system-wide.
        if writable, workspace.settings.hotKeyEnabled, HotKeyPreset.isRetired(modifiers: workspace.settings.hotKeyModifiers) {
            let previous = workspace.settings.hotKeyLabel
            workspace.settings.hotKeyCode = 3
            workspace.settings.hotKeyModifiers = 4096 | 2048 | 256
            workspace.settings.hotKeyLabel = "⌃⌥⌘F"
            notice = "El atajo \(previous) anulaba el mismo atajo en otras apps (por ejemplo, Buscar en VS Code). Ahora FocusDesk se abre con ⌃⌥⌘F."
        }
        calendar.pendingCount = workspace.pendingCalendarOps.count
        if preview { notice = "DEMOSTRACIÓN · Datos separados de tu agenda. Notificaciones desactivadas." }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        })
        // The display going dark on its own is not evidence of inactivity: recording, reading or studying happens
        // away from the keyboard. Only real sleep, a locked screen or a user switch stop the session.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForSystem() }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
                Task { await self?.reminders.refresh() }
                self?.schedule()
                self?.syncCalendar()
                self?.offerResumeAfterSystemPause(reason: "mientras el Mac estaba en reposo")
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Monotonic uptime keeps active session duration unaffected while wall-clock agenda & reminders adjust.
                self?.now = Date()
                self?.schedule()
                self?.syncCalendar()
            }
        })
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = heartbeat; RunLoop.main.add(heartbeat, forMode: .common)
        calendar.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        // Any change to tasks, settings or the session invalidates the projected-day cache. The clock (`now`)
        // is a separate publisher, so ticking does not throw the cache away.
        $workspace
            .sink { [weak self] _ in self?.dayCache.removeAll() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.checkCalendar()
                if self?.workspace.pendingCalendarOps.isEmpty == false {
                    self?.syncCalendar()
                }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.checkCalendar()
                if self?.workspace.pendingCalendarOps.isEmpty == false {
                    self?.syncCalendar()
                }
                Task { await self?.reminders.refresh() }
            }.store(in: &subscriptions)
        if writable {
            // One dated snapshot per day, taken at the first launch of the day too, not only if the app
            // happens to be running at midnight.
            if !preview { try? store.createDailySnapshotIfNeeded() }
            // After the snapshot, so the copy keeps the state as it was; series skipped while the app was closed
            // get their next occurrence back before reminders are planned below.
            rollMissedSeries()
            _ = persist()
            if !preview, workspace.settings.calendarID != nil, EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                Task {
                    await calendar.request()
                    self.syncCalendar(resetRetries: true)
                }
            } else {
                syncCalendar(resetRetries: true)
            }
        }
        schedule()
    }

    var session: WorkSession? { workspace.session }
    var tasks: [FocusTask] { workspace.tasks.filter { !$0.completed }.sorted { $0.scheduledAt < $1.scheduledAt } }
    var scheduledTasks: [FocusTask] { workspace.tasks.filter { !$0.completed && $0.isScheduled }.sorted { $0.scheduledAt < $1.scheduledAt } }
    var unscheduledTasks: [FocusTask] {
        workspace.tasks.filter { !$0.completed && !$0.isScheduled }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }
    var next: FocusTask? {
        FocusRules.nextSuggestedTask(tasks: workspace.tasks, sessionTaskID: session?.task.id, now: now)
    }
    var readOnly: Bool { !writable }

    func currentRemaining(for s: WorkSession) -> TimeInterval {
        s.remaining(at: now, uptime: uptime)
    }

    func currentElapsed(for s: WorkSession) -> TimeInterval {
        s.elapsed(at: now, uptime: uptime)
    }

    var menuTitle: String {
        if let s = session {
            return s.endedAt != nil ? "Confirmar" : s.paused ? "Pausa" : FocusRules.clock(currentRemaining(for: s))
        }
        if let upcoming = scheduledTasks.first(where: { $0.scheduledAt > now }),
           upcoming.scheduledAt.timeIntervalSince(now) <= Double(upcoming.leadMinutes) * 60 {
            return "En " + FocusRules.clock(upcoming.scheduledAt.timeIntervalSince(now))
        }
        return "FocusDesk"
    }

    func categoryColor(_ name: String) -> (red: Double, green: Double, blue: Double) {
        if let custom = workspace.settings.categories.first(where: { $0.name == name }) {
            return (custom.red, custom.green, custom.blue)
        }
        switch name {
        case "Contenido": return (1.0, 0.65, 0.48)
        case "Estudio": return (0.65, 0.69, 0.98)
        case "Tienda": return (0.64, 0.89, 0.73)
        default: return (0.7, 0.78, 0.87)
        }
    }

    @discardableResult
    func persist() -> Bool {
        guard writable || hasUnsavedChanges else { return false }
        do {
            try store.save(workspace)
            writable = true
            if hasUnsavedChanges {
                hasUnsavedChanges = false
                error = nil
            }
            corruptFileDetected = false
            return true
        } catch {
            if workspace.session != nil, workspace.session?.endedAt == nil, workspace.session?.paused == false {
                let pauseInstant = Date()
                workspace.session?.pause(at: pauseInstant, uptime: uptime)
                if let s = workspace.session {
                    enqueueProjectionForTask(s.task, session: s, now: pauseInstant)
                }
            }
            hasUnsavedChanges = true
            notice = nil
            let sessionNote = workspace.session != nil
                ? "La sesión se ha pausado y tus cambios permanecen en memoria"
                : "Tus cambios permanecen en memoria"
            self.error = "No se pudo guardar en disco. \(sessionNote); libera espacio o permisos y pulsa «Reintentar guardado» o «Exportar copia». (\(error.localizedDescription))"
            return false
        }
    }

    @discardableResult
    func retrySave() -> Bool {
        do {
            try store.save(workspace)
            writable = true
            hasUnsavedChanges = false
            corruptFileDetected = false
            error = nil
            notice = "Guardado recuperado correctamente."
            schedule()
            syncCalendar()
            return true
        } catch {
            self.error = "Sigue sin poderse escribir en \(store.url.path): \(error.localizedDescription)"
            return false
        }
    }

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        guard writable else { return }
        let before = workspace.settings
        mutate(&workspace.settings)
        _ = persist()
        if before.hotKeyEnabled != workspace.settings.hotKeyEnabled ||
           before.hotKeyCode != workspace.settings.hotKeyCode ||
           before.hotKeyModifiers != workspace.settings.hotKeyModifiers {
            onHotKeySettingsChanged?()
        }
    }

    func saveProfile(_ profile: FocusProfile) {
        guard writable else { return }
        var clean = profile
        clean.name = clean.name.trimmingCharacters(in: .whitespacesAndNewlines)
        clean.domains = FocusRules.normalizeDomains(clean.domains)
        guard !clean.name.isEmpty else { return }
        if let idx = workspace.profiles.firstIndex(where: { $0.id == clean.id }) {
            workspace.profiles[idx] = clean
        } else {
            workspace.profiles.append(clean)
        }
        if persist() {
            notice = "Perfil «\(clean.name)» guardado."
        }
    }

    func deleteProfile(_ id: UUID) {
        guard writable else { return }
        workspace.profiles.removeAll { $0.id == id }
        _ = persist()
    }

    func saveTask(_ input: FocusTask, detachFromSeriesID: UUID? = nil, occurrenceDate: Date? = nil) {
        guard writable, !busy, input.valid, input.id != session?.task.id else { return }
        var task = input
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.domains = FocusRules.normalizeDomains(task.domains)

        if let seriesID = detachFromSeriesID, let occDate = occurrenceDate,
           let sIdx = workspace.tasks.firstIndex(where: { $0.id == seriesID }) {
            let (updatedSeries, _) = workspace.tasks[sIdx].detachOccurrence(at: occDate, workdays: workspace.settings.workdays)
            workspace.tasks[sIdx] = updatedSeries
            enqueueProjectionForTask(updatedSeries)
            task.id = UUID()
            task.repeatRule = .never
            task.repeatDays = []
            task.skippedDates = []
            task.seriesID = seriesID
            task.calendarEventID = nil
            task.calendarSnapshot = nil
            workspace.tasks.append(task)
        } else if let index = workspace.tasks.firstIndex(where: { $0.id == task.id }) {
            workspace.tasks[index] = task
        } else {
            workspace.tasks.append(task)
        }

        enqueueProjectionForTask(task)
        editingTask = nil
        _ = persist()
        schedule()
        syncCalendar()
        askForNotificationsIfNeeded(after: task)
    }

    /// Reminders are the core promise ("antes de la tarea llega un aviso"), but permission was only requested from
    /// Ajustes: whoever never opened Ajustes got no reminder at all, silently. Ask the first time a task with a time
    /// is saved — the moment the reminder starts to matter. macOS shows its prompt only once; later calls just answer.
    private func askForNotificationsIfNeeded(after task: FocusTask) {
        guard !preview, !askedForNotifications, task.isScheduled, task.scheduledAt > Date(),
              reminders.status == .notDetermined else { return }
        askedForNotifications = true
        Task {
            await reminders.request()
            schedule()
        }
    }

    /// True when there is something to be reminded of and reminders cannot reach the user.
    var notificationsNeedAttention: Bool {
        guard !notificationBannerDismissed,
              reminders.status == .notDetermined || reminders.status == .denied else { return false }
        let reference = Date()
        return workspace.tasks.contains { !$0.completed && $0.isScheduled && $0.scheduledAt > reference }
    }

    func deleteTask(_ task: FocusTask) {
        guard writable, !busy, task.id != session?.task.id else { return }
        let before = workspace.tasks
        defer {
            if error == nil, before.count != workspace.tasks.count {
                rememberUndo("el borrado de «\(task.title)»", before: before)
                notice = "«\(task.title)» eliminada."
            }
        }
        let existingOp = workspace.pendingCalendarOps.first(where: { $0.taskID == task.id })
        let knownEventID = task.calendarEventID ?? existingOp?.eventID
        let knownBaseline = task.calendarSnapshot ?? existingOp?.baselineSnapshot
        workspace.clearCalendarOp(for: task.id)
        if workspace.settings.calendarID != nil, let knownEventID {
            workspace.enqueueCalendarOp(
                PendingCalendarOp(
                    taskID: task.id,
                    action: .remove,
                    eventID: knownEventID,
                    baselineSnapshot: knownBaseline,
                    force: false
                )
            )
        }
        calendar.pendingCount = workspace.pendingCalendarOps.count
        workspace.tasks.removeAll { $0.id == task.id }
        reminders.removeDelivered(forTaskID: task.id)
        _ = persist()
        schedule()
        syncCalendar()
    }

    func shift(_ task: FocusTask, to date: Date, durationMinutes: Int? = nil) {
        guard writable, !busy, task.id != session?.task.id else { return }
        let before = workspace.tasks
        let detached = isSeriesHead(task)
        var updated = occurrenceForDirectEdit(task)
        updated.scheduledAt = date
        updated.isScheduled = true
        if let durationMinutes {
            updated.minutes = FocusRules.clampedMinutes(durationMinutes)
        }
        saveTask(updated)
        guard error == nil else { return }
        let when = updated.scheduledAt.formatted(date: Calendar.current.isDateInToday(updated.scheduledAt) ? .omitted : .abbreviated, time: .shortened)
        let what = durationMinutes != nil && Calendar.current.isDate(updated.scheduledAt, equalTo: task.scheduledAt, toGranularity: .minute)
            ? "«\(updated.title)» ahora dura \(updated.minutes) min."
            : "«\(updated.title)» movida a \(when)."
        notice = detached ? what + " Solo esta ocurrencia; la serie sigue a su hora." : what
        rememberUndo("el cambio de «\(updated.title)»", before: before)
    }

    private func rememberUndo(_ label: String, before: [FocusTask]) {
        agendaUndo = AgendaUndo(label: label, before: before, after: workspace.tasks)
    }

    /// Calendar ids get filled in by the sync right after a change; they are not an edit by the user.
    private static func agendaSignature(_ tasks: [FocusTask]) -> [FocusTask] {
        tasks.map { task in
            var copy = task
            copy.calendarEventID = nil
            copy.calendarSnapshot = nil
            return copy
        }
    }

    var canUndoAgenda: Bool {
        guard let undo = agendaUndo else { return false }
        return Self.agendaSignature(undo.after) == Self.agendaSignature(workspace.tasks)
    }

    func undoAgendaChange() {
        guard writable, !busy, let undo = agendaUndo else { return }
        guard canUndoAgenda else {
            agendaUndo = nil
            notice = "Ya no se puede deshacer: la agenda cambió después."
            return
        }
        let current = workspace.tasks
        let reference = Date()
        // Keep what Calendar knows now: a restored task must not point at an event that was already removed.
        var restored = undo.before.map { task -> FocusTask in
            var copy = task
            let live = current.first { $0.id == task.id }
            copy.calendarEventID = live?.calendarEventID
            copy.calendarSnapshot = live?.calendarSnapshot
            return copy
        }
        // Never touch the running session's task.
        if let sessionTask = session?.task, let liveSession = current.first(where: { $0.id == sessionTask.id }) {
            restored.removeAll { $0.id == sessionTask.id }
            restored.append(liveSession)
        }
        // Tasks the change created (e.g. a detached occurrence) go away, with their Calendar events.
        for gone in current where !restored.contains(where: { $0.id == gone.id }) {
            if workspace.settings.calendarID != nil, let eventID = gone.calendarEventID {
                workspace.enqueueCalendarOp(PendingCalendarOp(taskID: gone.id, action: .remove, eventID: eventID, baselineSnapshot: gone.calendarSnapshot))
            } else {
                workspace.clearCalendarOp(for: gone.id)
            }
            reminders.removeDelivered(forTaskID: gone.id)
        }
        workspace.tasks = restored
        for task in restored where current.first(where: { $0.id == task.id }) != task {
            workspace.clearCalendarOp(for: task.id)
            enqueueProjectionForTask(task, now: reference)
        }
        calendar.pendingCount = workspace.pendingCalendarOps.count
        agendaUndo = nil
        _ = persist()
        schedule()
        syncCalendar()
        notice = "Deshecho \(undo.label)."
    }

    /// Jots something down from the menu-bar panel without leaving the current work: an inbox task, no time yet.
    @discardableResult
    func quickCapture(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writable, !busy, !trimmed.isEmpty else { return false }
        let task = FocusTask(title: trimmed, isScheduled: false, minutes: 15)
        saveTask(task)
        guard error == nil else { return false }
        notice = "«\(trimmed)» apuntada en la bandeja sin hora."
        return true
    }

    /// The task coming after the current one: the one queued by a hand-off, else the suggested next.
    var upcomingAfterSession: FocusTask? { queuedStartTask ?? next }

    /// Overdue quick actions: back on today's agenda in the first free slot, or tomorrow at the same time.
    func moveToFirstFreeSlotToday(_ task: FocusTask) {
        let slot = FocusRules.firstFreeSlot(
            on: Date(),
            tasks: workspace.tasks.filter { $0.id != task.id },
            breaks: workspace.settings.breaks,
            workStartHour: workspace.settings.workStartHour,
            now: Date()
        )
        shift(task, to: slot)
    }

    func moveToTomorrowSameTime(_ task: FocusTask) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: task.isScheduled ? task.scheduledAt : Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())),
              let target = calendar.date(bySettingHour: time.hour ?? workspace.settings.workStartHour, minute: time.minute ?? 0, second: 0, of: tomorrow) else { return }
        shift(task, to: target)
    }

    /// Worked session time on `day`: confirmed and cancelled sessions plus the one running now.
    func workedSeconds(on day: Date, calendar: Calendar = .current) -> TimeInterval {
        var total = workspace.history
            .filter { calendar.isDate($0.session.startedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.session.accumulated }
        // The current session is not in the history yet (running, paused or waiting for its result).
        if let s = session, calendar.isDate(s.startedAt, inSameDayAs: day) {
            total += s.endedAt == nil ? currentElapsed(for: s) : s.accumulated
        }
        return total
    }

    /// What the editor is looking at when the task belongs to a recurring series.
    enum SeriesEditKind: Equatable {
        case notInSeries
        /// The series itself (its current occurrence).
        case head(UUID)
        /// A future occurrence drawn from the series; it does not exist as a task of its own yet.
        case projected(seriesID: UUID)
        /// An occurrence already detached into its own task.
        case detached(seriesID: UUID)
    }

    func seriesEditKind(for draft: FocusTask) -> SeriesEditKind {
        let stored = workspace.tasks.first { $0.id == draft.id }
        if let stored, stored.repeatRule != .never { return .head(stored.id) }
        guard let seriesID = draft.seriesID,
              workspace.tasks.contains(where: { $0.id == seriesID && $0.repeatRule != .never && !$0.completed }) else {
            return .notInSeries
        }
        return stored == nil ? .projected(seriesID: seriesID) : .detached(seriesID: seriesID)
    }

    /// Saves an edit made in the task editor, applying the "toda la serie / solo esta ocurrencia" choice correctly.
    /// `originalOccurrenceDate` is the date the editor was opened with: the occurrence to detach is that one, even if
    /// the user moved it, and a series-wide move is the difference between it and the new date.
    func saveEdited(_ draft: FocusTask, originalOccurrenceDate: Date, onlyThisOccurrence: Bool, calendar: Calendar = .current) {
        switch seriesEditKind(for: draft) {
        case .notInSeries:
            saveTask(draft)
        case .head(let headID):
            if onlyThisOccurrence {
                saveTask(draft, detachFromSeriesID: headID, occurrenceDate: originalOccurrenceDate)
            } else {
                saveTask(draft)
            }
        case .projected(let seriesID):
            if onlyThisOccurrence {
                saveTask(draft, detachFromSeriesID: seriesID, occurrenceDate: originalOccurrenceDate)
            } else if var head = workspace.tasks.first(where: { $0.id == seriesID }) {
                // The series keeps its own current date; only what was edited carries over. Opening Friday and
                // changing the title must not make the series start on Friday and drop today and tomorrow.
                Self.copySharedFields(from: draft, to: &head)
                head.repeatRule = draft.repeatRule
                head.repeatDays = draft.repeatDays
                head.scheduledAt = Self.moved(head.scheduledAt, like: originalOccurrenceDate, to: draft.scheduledAt, calendar: calendar)
                saveTask(head)
            }
        case .detached(let seriesID):
            // Already its own task: "solo esta" is a plain save (detaching again would duplicate it). "Toda la serie"
            // also carries the edited fields to the series, but never its "No repetir" or its own moved time.
            saveTask(draft)
            if !onlyThisOccurrence, error == nil, var head = workspace.tasks.first(where: { $0.id == seriesID }) {
                Self.copySharedFields(from: draft, to: &head)
                saveTask(head)
            }
        }
    }

    private static func copySharedFields(from draft: FocusTask, to head: inout FocusTask) {
        head.title = draft.title
        head.category = draft.category
        head.minutes = draft.minutes
        head.leadMinutes = draft.leadMinutes
        head.strict = draft.strict
        head.apps = draft.apps
        head.domains = draft.domains
        head.folder = draft.folder
        head.checklist = draft.checklist
        head.profileID = draft.profileID
        head.isFixedAppointment = draft.isFixedAppointment
    }

    /// Applies to `date` the same move (whole days, then wall-clock time) that took `original` to `edited`.
    /// Works in calendar days, not seconds, so a change across a DST switch keeps the wall-clock time.
    private static func moved(_ date: Date, like original: Date, to edited: Date, calendar: Calendar) -> Date {
        guard abs(edited.timeIntervalSince(original)) >= 1 else { return date }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: original), to: calendar.startOfDay(for: edited)).day ?? 0
        let time = calendar.dateComponents([.hour, .minute, .second], from: edited)
        guard let shiftedDay = calendar.date(byAdding: .day, value: days, to: date),
              let result = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: time.second ?? 0, of: shiftedDay) else { return date }
        return result
    }

    /// A recurring series is one task whose `scheduledAt` is its current occurrence, and the time of the whole series
    /// comes from it. Dragging, snoozing or resizing a block on the agenda means "this one", so those edits act on a
    /// detached copy of the occurrence instead of moving the series. Series-wide edits go through the editor, which asks.
    private func isSeriesHead(_ task: FocusTask) -> Bool {
        task.isScheduled && task.repeatRule != .never && workspace.tasks.contains { $0.id == task.id }
    }

    /// Detaches `task`'s occurrence when it is a series head and returns the copy to edit; otherwise returns `task`.
    /// The series advances to its next occurrence and remembers the detached day, exactly as the editor's
    /// "solo esta ocurrencia" does.
    private func occurrenceForDirectEdit(_ task: FocusTask) -> FocusTask {
        guard isSeriesHead(task), let index = workspace.tasks.firstIndex(where: { $0.id == task.id }) else { return task }
        let (series, single) = workspace.tasks[index].detachOccurrence(at: task.scheduledAt, workdays: workspace.settings.workdays)
        workspace.tasks[index] = series
        enqueueProjectionForTask(series)
        workspace.tasks.append(single)
        return single
    }

    /// First usable slot on `date`: the start of the working day, or the next free moment when that hour already passed today.
    func startOfWorkingDay(on date: Date, calendar: Calendar = .current) -> Date {
        let reference = Date()
        let atWorkStart = calendar.date(bySettingHour: workspace.settings.workStartHour, minute: 0, second: 0, of: date) ?? date
        guard calendar.isDate(date, inSameDayAs: reference), atWorkStart <= reference else { return atWorkStart }
        // Never hand back a time already in the past: round up to the next 5 minutes from now.
        let slot = reference.addingTimeInterval(300)
        let minute = calendar.component(.minute, from: slot)
        let rounded = calendar.date(bySetting: .second, value: 0, of: slot) ?? slot
        return calendar.date(byAdding: .minute, value: (5 - minute % 5) % 5, to: rounded) ?? slot
    }

    func snoozeTask(_ task: FocusTask, minutes: Int = 10) {
        guard writable, !busy, task.id != session?.task.id else { return }
        let before = workspace.tasks
        defer { if error == nil { rememberUndo("el aplazamiento de «\(task.title)»", before: before) } }
        let detached = isSeriesHead(task)
        let updated = occurrenceForDirectEdit(task).snoozed(minutes: minutes, now: Date())
        reminders.removeDelivered(forTaskID: task.id)
        saveTask(updated)
        if error == nil {
            let time = updated.scheduledAt.formatted(date: .omitted, time: .shortened)
            notice = detached
                ? "«\(updated.title)» pospuesta a las \(time), solo esta vez. La serie sigue a su hora."
                : "«\(updated.title)» pospuesta a las \(time)."
        }
    }

    /// Sends one task to the inbox. For a series that means this occurrence only; the series keeps its schedule.
    func moveToInbox(_ task: FocusTask) {
        guard writable, !busy, task.id != session?.task.id else { return }
        let before = workspace.tasks
        let detached = isSeriesHead(task)
        var unscheduled = occurrenceForDirectEdit(task)
        unscheduled.isScheduled = false
        saveTask(unscheduled)
        guard error == nil else { return }
        notice = detached
            ? "Esta ocurrencia de «\(unscheduled.title)» pasa a la bandeja. La serie sigue programada."
            : "«\(unscheduled.title)» pasa a la bandeja sin hora."
        rememberUndo("el paso a la bandeja de «\(unscheduled.title)»", before: before)
    }

    /// Returns real tasks on `date` plus projected future occurrences of recurring tasks for preview.
    /// Cached per day: the view bodies that call this re-run on every clock tick, and projecting a recurring
    /// series is far too expensive to redo once a second. `$workspace` clears the cache on any change.
    func tasksForDay(_ date: Date, calendar: Calendar = .current) -> (real: [FocusTask], projected: [FocusTask]) {
        let cacheKey = FocusRules.dayKey(for: date, calendar: calendar)
        if let hit = dayCache[cacheKey] { return hit }
        let value = computeTasksForDay(date, calendar: calendar)
        if dayCache.count > 60 { dayCache.removeAll() }
        dayCache[cacheKey] = value
        return value
    }

    private func computeTasksForDay(_ date: Date, calendar: Calendar) -> (real: [FocusTask], projected: [FocusTask]) {
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return ([], []) }
        let interval = DateInterval(start: dayStart, end: dayEnd.addingTimeInterval(-1))
        let real = workspace.tasks
            .filter { $0.isScheduled && calendar.isDate($0.scheduledAt, inSameDayAs: date) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        var projected: [FocusTask] = []
        for task in workspace.tasks where !task.completed && task.isScheduled && task.repeatRule != .never {
            let occurrences = task.upcomingOccurrences(in: interval, calendar: calendar, workdays: workspace.settings.workdays)
            for occ in occurrences where !real.contains(where: { $0.seriesID == task.id && calendar.isDate($0.scheduledAt, inSameDayAs: occ.scheduledAt) }) {
                if !calendar.isDate(task.scheduledAt, inSameDayAs: occ.scheduledAt) {
                    projected.append(occ)
                }
            }
        }
        projected.sort { $0.scheduledAt < $1.scheduledAt }
        return (real, projected)
    }

    /// Moves recurring series past a missed day so later days keep their reminders and Calendar block.
    /// Returns true when something changed (the caller persists, reschedules and syncs).
    @discardableResult
    func rollMissedSeries(now reference: Date = Date()) -> Bool {
        guard writable else { return false }
        let rolled = SeriesRoller.roll(
            workspace.tasks,
            sessionTaskID: session?.task.id,
            now: reference,
            workdays: workspace.settings.workdays
        )
        guard !rolled.rolledSeriesIDs.isEmpty else { return false }
        workspace.tasks = rolled.tasks
        for id in rolled.rolledSeriesIDs {
            if let task = workspace.tasks.first(where: { $0.id == id }) { enqueueProjectionForTask(task, now: reference) }
        }
        return true
    }

    func schedule() {
        if !preview {
            reminders.schedule(workspace.tasks, sessionTaskID: session?.task.id)
        }
    }

    func handleNotificationAction(identifier: String, userInfo: [AnyHashable: Any]) {
        let taskID = (userInfo["taskID"] as? String).flatMap(UUID.init)
        switch identifier {
        case ReminderService.actionStart:
            if let taskID, let task = workspace.tasks.first(where: { $0.id == taskID && !$0.completed }) {
                start(task)
            } else if let nextTask = next {
                start(nextTask)
            }
        case ReminderService.actionSnooze:
            if let taskID, let task = workspace.tasks.first(where: { $0.id == taskID && !$0.completed }) {
                snoozeTask(task, minutes: 10)
            }
        case ReminderService.actionFinish:
            finish()
        case ReminderService.actionExtend:
            addTime()
        case ReminderService.actionPause:
            pause()
        case ReminderService.actionResume:
            if session?.endedAt == nil { resume() } else { showCompletion = true; showWindow?() }
        default:
            if let taskID, let task = workspace.tasks.first(where: { $0.id == taskID }) {
                page = "Hoy"
                if task.isScheduled { selectedDate = task.scheduledAt }
            }
            showWindow?()
        }
    }

    /// Single timer, always. Starting a task while another one is running never happens silently: it either resumes the
    /// one already going, asks for an explicit hand-off, or says why it cannot start.
    func start(_ task: FocusTask) {
        if let current = session {
            guard current.task.id != task.id else {
                if current.endedAt != nil {
                    showCompletion = true
                    showWindow?()
                } else if current.paused {
                    resume()
                } else {
                    notice = "«\(task.title)» ya está en marcha."
                }
                return
            }
            guard !busy else {
                notice = "Un momento: FocusDesk está guardando la sesión actual."
                return
            }
            if current.endedAt != nil {
                // The session already stopped; only its result is missing. Queue the new task behind that confirmation.
                queuedStartTaskID = task.id
                showCompletion = true
                showWindow?()
                notice = "Confirma el resultado de «\(current.task.title)» y «\(task.title)» empezará a continuación."
            } else {
                handoffRequest = task
                showWindow?()
            }
            return
        }
        guard !busy else { notice = "Un momento: FocusDesk está terminando la operación anterior."; return }
        guard !readOnly else { notice = "No se puede empezar sin poder guardar. Resuelve el aviso de guardado primero."; return }
        guard !task.completed else { notice = "«\(task.title)» ya está completada."; return }
        guard task.valid else { notice = "«\(task.title)» está incompleta: revisa título, duración y apps del modo estricto."; return }
        busy = true
        changedFiles = []
        writingFiles = []
        selectedDeliverables = []
        manualAttachments = []
        evidenceMessage = nil
        Task {
            let snapshot = await scanner.scan(task.folder)
            guard session == nil, writable, workspace.tasks.contains(where: { $0.id == task.id }) else {
                busy = false
                notice = session != nil
                    ? "«\(session?.task.title ?? "Otra tarea")» se puso en marcha antes. Solo hay un temporizador a la vez."
                    : "La tarea cambió antes de empezar. Revisa su configuración."
                return
            }
            let currentNow = Date()
            let currentUptime = uptime
            var s = WorkSession(task: task, now: currentNow, uptime: currentUptime)
            s.baseline = snapshot.files
            s.baselineValid = snapshot.valid
            hasInitialBaseline = snapshot.valid
            workspace.session = s
            enqueueProjectionForTask(task, session: s, now: currentNow)
            reminders.removeDelivered(forTaskID: task.id)
            domainEpisodeHost = nil
            lastDistractionNotifyAt = .distantPast
            evidenceMessage = snapshot.message
            now = currentNow
            overtimeNotified = false
            lastAllowed = nil
            strictTracker = StrictRedirectTracker()
            busy = false
            let saved = persist()
            schedule()
            syncCalendar()
            guard saved else { return }
            if let allowed = task.apps.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: allowed.id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    notice = "No se pudo abrir \(allowed.name). Puedes abrirla manualmente o pausar."
                }
            }
        }
    }

    /// Accepts the hand-off: stops the running session and queues `task` behind its result confirmation,
    /// so the newest task wins without ever throwing away what was already worked.
    func acceptHandoff() {
        guard let task = handoffRequest else { return }
        handoffRequest = nil
        guard let current = session else { start(task); return }
        guard current.task.id != task.id else { return }
        queuedStartTaskID = task.id
        notice = "«\(current.task.title)» se ha detenido. Confirma su resultado y «\(task.title)» empezará."
        finish()
    }

    func cancelHandoff() {
        if let current = session, let requested = handoffRequest {
            notice = "Sigues con «\(current.task.title)». «\(requested.title)» te espera."
        }
        handoffRequest = nil
    }

    /// Task waiting behind the current confirmation, if any.
    var queuedStartTask: FocusTask? {
        guard let id = queuedStartTaskID else { return nil }
        return workspace.tasks.first { $0.id == id && !$0.completed }
    }

    func pause() {
        guard writable, workspace.session != nil, workspace.session?.endedAt == nil else { return }
        pausedBySystem = false
        resumePrompt = nil
        promptApps = []
        let currentNow = Date()
        workspace.session?.pause(at: currentNow, uptime: uptime)
        if let s = workspace.session {
            enqueueProjectionForTask(s.task, session: s, now: currentNow)
        }
        _ = persist()
        syncCalendar()
    }

    func resume() {
        guard writable, workspace.session != nil else { return }
        guard workspace.session?.endedAt == nil else { showCompletion = true; return }
        pausedBySystem = false
        resumePrompt = nil
        promptApps = []
        if let s = workspace.session { reminders.removeDelivered(identifiers: ["paused-" + s.id.uuidString]) }
        now = Date()
        workspace.session?.resume(at: now, uptime: uptime)
        strictTracker = StrictRedirectTracker()
        if let s = workspace.session {
            enqueueProjectionForTask(s.task, session: s, now: now)
        }
        let saved = persist()
        syncCalendar()
        if saved {
            observe()
        }
    }

    func addTime(minutes: Int = 10) {
        guard writable, workspace.session?.endedAt == nil else { return }
        workspace.session?.add(minutes: minutes)
        overtimeNotified = false
        if let s = workspace.session {
            enqueueProjectionForTask(s.task, session: s, now: Date())
        }
        _ = persist()
        syncCalendar()
    }

    @objc private func screenLocked() {
        screenIsLocked = true
        pauseForSystem()
    }

    @objc private func screenUnlocked() {
        screenIsLocked = false
        now = Date()
        offerResumeAfterSystemPause(reason: "mientras el Mac estaba bloqueado")
    }

    private func pauseForSystem() {
        guard let s = session, !s.paused, s.endedAt == nil else { return }
        pause()
        pausedBySystem = true
        if error == nil {
            notice = "Sesión en pausa por reposo o bloqueo del Mac."
        }
    }

    /// The design promises the session is offered back after sleep or a locked screen. `notice` disappears on its own
    /// after a few seconds — and it does so while nobody is looking — so this uses a prompt that waits for an answer,
    /// plus a notification for when the planner is closed.
    private func offerResumeAfterSystemPause(reason: String) {
        guard pausedBySystem, let s = session, s.paused, s.endedAt == nil else {
            if session == nil || session?.paused == false { pausedBySystem = false }
            return
        }
        let remaining = FocusRules.clock(max(0, s.remaining(at: now, uptime: uptime)))
        resumePrompt = "«\(s.task.title)» se pausó \(reason). Te quedan \(remaining). ¿Reanudamos?"
        if !preview {
            reminders.notify(
                "Sesión en pausa · \(s.task.title)",
                body: "Se pausó \(reason). Te quedan \(remaining). Reanuda cuando estés listo.",
                category: ReminderService.pausedCategory,
                userInfo: ["taskID": s.task.id.uuidString]
            )
        }
    }

    func dismissResumePrompt() {
        resumePrompt = nil
        promptApps = []
        pausedBySystem = false
    }

    /// Opens an allowed app from the strict-pause prompt and resumes the session once it is up.
    func openAllowedAppAndResume(_ app: AllowedApp) {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
            ?? (FileManager.default.fileExists(atPath: app.path) ? URL(fileURLWithPath: app.path) : nil)
        guard let url = installed else {
            notice = "No encuentro \(app.name) en este Mac. Ábrela a mano o quítala del perfil."
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                resume()
            } catch {
                notice = "No se pudo abrir \(app.name): \(error.localizedDescription)"
            }
        }
    }

    /// Undoes an accidental «He terminado»: back to the running countdown with the time already worked.
    func reopenSession() {
        guard writable, !busy, var s = session, s.endedAt != nil else { return }
        s.reopen(at: Date(), uptime: uptime)
        workspace.session = s
        showCompletion = false
        changedFiles = []
        writingFiles = []
        selectedDeliverables = []
        manualAttachments = []
        evidenceMessage = nil
        overtimeNotified = s.remaining(at: Date(), uptime: uptime) <= 0
        strictTracker = StrictRedirectTracker()
        if let queued = queuedStartTask {
            notice = "«\(queued.title)» ya no empezará a continuación: sigues con «\(s.task.title)»."
        } else {
            notice = "De vuelta a «\(s.task.title)». Te quedan \(FocusRules.clock(max(0, s.remaining(at: Date(), uptime: uptime))))."
        }
        queuedStartTaskID = nil
        enqueueProjectionForTask(s.task, session: s, now: Date())
        if persist() {
            syncCalendar()
            observe()
        }
    }

    func finish() {
        guard writable, var s = session, !busy else { return }
        if s.endedAt != nil { showCompletion = true; showWindow?(); return }
        let finishInstant = Date()
        s.finish(at: finishInstant, uptime: uptime)
        workspace.session = s
        enqueueProjectionForTask(s.task, session: s, now: finishInstant)
        _ = persist()
        syncCalendar()
        busy = true
        Task {
            let snapshot = await scanner.scan(s.task.folder)
            guard workspace.session?.id == s.id else { busy = false; return }
            changedFiles = hasInitialBaseline && snapshot.valid ? FocusRules.changed(before: s.baseline, after: snapshot.files) : []
            writingFiles = snapshot.writingFiles.filter { changedFiles.contains($0) }
            if changedFiles.count == 1 {
                selectedDeliverables = [changedFiles[0]]
            }
            evidenceMessage = hasInitialBaseline ? snapshot.message : "Sin lectura inicial válida; resultado pendiente de tu confirmación."
            workspace.session?.finalChangedFiles = changedFiles
            workspace.session?.finalEvidenceMessage = evidenceMessage
            workspace.session?.selectedFiles = Array(selectedDeliverables)
            _ = persist()
            busy = false
            showCompletion = true
            showWindow?()
        }
    }

    func toggleDeliverable(_ path: String) {
        if selectedDeliverables.contains(path) {
            selectedDeliverables.remove(path)
        } else {
            selectedDeliverables.insert(path)
        }
        workspace.session?.selectedFiles = Array(selectedDeliverables).sorted()
        _ = persist()
    }

    func attachManualFile(_ path: String) {
        guard !manualAttachments.contains(path) else { return }
        manualAttachments.append(path)
        selectedDeliverables.insert(path)
        workspace.session?.manualFiles = manualAttachments
        workspace.session?.selectedFiles = Array(selectedDeliverables).sorted()
        _ = persist()
    }

    func confirm(completed: Bool, note: String, transition: NextTransitionAction = .keepSchedule) {
        guard writable, !busy, let s = session, s.endedAt != nil else { return }
        let confirmInstant = Date()
        var recordSession = s
        recordSession.baseline = [:]
        recordSession.selectedFiles = Array(selectedDeliverables).sorted()
        recordSession.manualFiles = manualAttachments
        let record = SessionRecord(
            session: recordSession,
            completed: completed,
            cancelled: false,
            note: note,
            changedFiles: changedFiles,
            confirmedFiles: Array(selectedDeliverables).sorted(),
            manualFiles: manualAttachments
        )
        workspace.history.insert(record, at: 0)
        if let index = workspace.tasks.firstIndex(where: { $0.id == s.task.id }) {
            workspace.tasks[index].completed = completed
            enqueueProjectionForTask(workspace.tasks[index], session: s, now: confirmInstant, force: false)
            if completed, let nextOcc = workspace.tasks[index].nextOccurrence(after: confirmInstant, workdays: workspace.settings.workdays) {
                workspace.tasks.append(nextOcc)
                enqueueProjectionForTask(nextOcc, session: nil, now: confirmInstant, force: false)
            }
        }
        workspace.session = nil
        clearSessionNotifications(s)
        // "Sigue pendiente" on an occurrence from an earlier day must not freeze its series there.
        rollMissedSeries(now: confirmInstant)
        showCompletion = false
        changedFiles = []
        writingFiles = []
        selectedDeliverables = []
        manualAttachments = []

        let saved = persist()
        schedule()
        syncCalendar()
        guard saved else { return }

        // A task queued by an accepted hand-off takes priority over the suggested next one: it is what the user asked for.
        let queued = queuedStartTask
        queuedStartTaskID = nil
        let candidateNext = queued ?? next
        switch transition {
        case .keepSchedule:
            if let queued {
                notice = "Sesión guardada. «\(queued.title)» sigue sin empezar; púlsala cuando quieras."
            } else {
                notice = completed ? "Tarea terminada. La siguiente conserva su horario." : "Sesión guardada. La tarea sigue pendiente."
            }
        case .startNextNow:
            if let candidateNext {
                notice = "Iniciando «\(candidateNext.title)»."
                start(candidateNext)
            } else {
                notice = completed ? "Tarea terminada. No hay más tareas pendientes." : "Sesión guardada."
            }
        case .rest10Min:
            if let candidateNext, !candidateNext.isFixedAppointment, candidateNext.isScheduled,
               candidateNext.scheduledAt <= confirmInstant.addingTimeInterval(600) {
                snoozeTask(candidateNext, minutes: 10)
                if error == nil {
                    notice = "Descanso de 10 minutos. «\(candidateNext.title)» se ha desplazado 10 min (las citas fijas no se mueven)."
                }
            } else {
                notice = "Descanso de 10 minutos antes de continuar. Los horarios fijos se conservan."
            }
        }
    }

    func cancelSession(note: String = "Sesión cancelada") {
        guard writable, !busy, var s = session else { return }
        let cancelInstant = Date()
        s.finish(at: cancelInstant, uptime: uptime)
        var recordSession = s
        recordSession.baseline = [:]
        let record = SessionRecord(
            session: recordSession,
            completed: false,
            cancelled: true,
            note: note,
            changedFiles: []
        )
        workspace.history.insert(record, at: 0)
        workspace.session = nil
        clearSessionNotifications(s)
        // A cancelled occurrence from an earlier day must not freeze its series there either.
        rollMissedSeries(now: cancelInstant)
        if let index = workspace.tasks.firstIndex(where: { $0.id == s.task.id }) {
            let task = workspace.tasks[index]
            if task.isScheduled && task.scheduledAt > cancelInstant {
                enqueueProjectionForTask(task, session: nil, now: cancelInstant)
            } else if task.calendarEventID != nil {
                workspace.enqueueCalendarOp(
                    PendingCalendarOp(
                        taskID: task.id,
                        action: .remove,
                        eventID: task.calendarEventID,
                        baselineSnapshot: task.calendarSnapshot,
                        force: false
                    )
                )
            } else {
                workspace.clearCalendarOp(for: task.id)
            }
            calendar.pendingCount = workspace.pendingCalendarOps.count
        }
        showCompletion = false
        changedFiles = []
        writingFiles = []
        selectedDeliverables = []
        manualAttachments = []
        let queued = queuedStartTask
        queuedStartTaskID = nil
        let saved = persist()
        schedule()
        syncCalendar()
        if saved {
            notice = "Sesión cancelada. La tarea sigue pendiente sin completarse."
            if let queued {
                notice = "Sesión cancelada sin completar. Iniciando «\(queued.title)»."
                start(queued)
            }
        }
    }

    func setCheck(_ key: String, value: Bool) {
        // Also while the result is being confirmed: work done in another app gets ticked off here, at the end.
        guard writable, session != nil else { return }
        if value { workspace.session?.checked.insert(key) } else { workspace.session?.checked.remove(key) }
        _ = persist()
    }

    private func enqueueProjectionForTask(_ inputTask: FocusTask, session: WorkSession? = nil, now: Date = Date(), force: Bool = false) {
        guard !preview, workspace.settings.calendarID != nil else { return }
        let task = workspace.tasks.first(where: { $0.id == inputTask.id }) ?? inputTask
        let activeSession = session ?? self.session
        let isActiveSessionTask = activeSession?.task.id == task.id
        let existingOp = workspace.pendingCalendarOps.first(where: { $0.taskID == task.id })
        let effectiveForce = force || (existingOp?.force ?? false)
        let projection: CalendarProjection = force && !isActiveSessionTask && !task.completed && task.isScheduled
            ? .event(CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end))
            : CalendarProjection.make(task: task, session: activeSession, now: now, uptime: uptime)
        switch projection {
        case .event(let snapshot):
            workspace.enqueueCalendarOp(
                PendingCalendarOp(
                    taskID: task.id,
                    action: .upsert,
                    snapshot: snapshot,
                    eventID: task.calendarEventID ?? existingOp?.eventID,
                    baselineSnapshot: task.calendarSnapshot ?? existingOp?.baselineSnapshot,
                    force: effectiveForce,
                    updatedAt: now
                )
            )
        case .remove:
            if let knownEventID = task.calendarEventID ?? existingOp?.eventID {
                workspace.enqueueCalendarOp(
                    PendingCalendarOp(
                        taskID: task.id,
                        action: .remove,
                        eventID: knownEventID,
                        baselineSnapshot: task.calendarSnapshot ?? existingOp?.baselineSnapshot,
                        force: effectiveForce,
                        updatedAt: now
                    )
                )
            } else {
                workspace.clearCalendarOp(for: task.id)
            }
        case .unchanged:
            break
        }
        calendar.pendingCount = workspace.pendingCalendarOps.count
    }

    func chooseCalendarSource(_ source: EKSource) {
        guard writable, !preview, workspace.settings.calendarID == nil else { return }
        do { connectCalendar(try calendar.create(in: source)) }
        catch { self.error = error.localizedDescription }
    }

    func connectCalendar(_ id: String) {
        guard writable, !preview, workspace.settings.calendarID == nil,
              let chosen = calendar.connected(id), chosen.title == "FocusDesk", chosen.allowsContentModifications else { return }
        workspace.settings.calendarID = id
        guard persist() else { return }
        syncCalendar()
    }

    func disconnectCalendar() {
        guard writable else { return }
        // Leave external events intact. This is an explicit disconnect, never silent cleanup.
        workspace.settings.calendarID = nil
        workspace.pendingCalendarOps = []
        for index in workspace.tasks.indices {
            workspace.tasks[index].calendarEventID = nil
            workspace.tasks[index].calendarSnapshot = nil
        }
        calendar.issues = [:]
        calendar.pendingCount = 0
        calendar.lastSync = nil
        calendar.message = "Desconectado. Los eventos existentes se conservan en Calendar."
        _ = persist()
    }

    func checkCalendar() {
        guard !preview else { return }
        calendar.refresh()
        calendar.pendingCount = workspace.pendingCalendarOps.count
        guard let id = workspace.settings.calendarID else { return }
        guard let connected = calendar.connected(id), connected.allowsContentModifications else {
            let pendingNote = workspace.pendingCalendarOps.isEmpty ? "" : " (\(workspace.pendingCalendarOps.count) operación(es) en cola pendiente)"
            calendar.message = "Conexión pendiente: falta permiso o el calendario no está disponible\(pendingNote)."
            return
        }
        var issues: [UUID: String] = [:]
        for task in workspace.tasks where task.calendarEventID != nil && !task.completed {
            do { try calendar.validate(task, calendarID: id) } catch { issues[task.id] = error.localizedDescription }
        }
        calendar.issues = issues
        if !workspace.pendingCalendarOps.isEmpty {
            calendar.message = "Conectado a \(connected.title) · \(workspace.pendingCalendarOps.count) cambio(s) pendientes de sincronizar"
        } else {
            calendar.message = issues.isEmpty
                ? "Conectado a \(connected.title) · \(connected.source.title)"
                : "\(issues.count) evento(s) requieren revisión. No se han sobrescrito."
        }
    }

    func syncCalendar(forceTaskID: UUID? = nil, resetRetries: Bool = false) {
        guard writable, !preview, let calendarID = workspace.settings.calendarID else { return }
        let instant = Date()
        if resetRetries {
            for idx in workspace.pendingCalendarOps.indices {
                workspace.pendingCalendarOps[idx].attempts = 0
            }
        }
        if let forceTaskID, let task = workspace.tasks.first(where: { $0.id == forceTaskID }) {
            enqueueProjectionForTask(task, now: instant, force: true)
        }

        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            Task {
                await calendar.request()
                if self.calendar.authorized {
                    self.syncCalendar(forceTaskID: forceTaskID, resetRetries: true)
                }
            }
            return
        }

        guard calendar.authorized, let connected = calendar.connected(calendarID), connected.allowsContentModifications else {
            for idx in workspace.pendingCalendarOps.indices where workspace.pendingCalendarOps[idx].attempts < 5 {
                workspace.pendingCalendarOps[idx].attempts += 1
                workspace.pendingCalendarOps[idx].lastError = CalendarBridge.BridgeError.calendarUnavailable.errorDescription
            }
            calendar.pendingCount = workspace.pendingCalendarOps.count
            let suffix = workspace.pendingCalendarOps.isEmpty ? "" : " (\(workspace.pendingCalendarOps.count) en cola para recuperar automáticamente)"
            calendar.message = "Sin permiso o calendario disponible\(suffix). Tus sesiones siguen activas."
            if !calendar.authorized {
                notice = "Concede permiso a Calendario para mostrar el contador en Vorssaint (Ajustes → Conectar Calendario)."
            }
            _ = persist()
            return
        }

        var issues: [UUID: String] = [:]

        // 1. Process persistent pending operations first (including removals for deleted or paused tasks)
        let pendingSnapshot = workspace.pendingCalendarOps
        for op in pendingSnapshot where op.attempts < 5 || resetRetries || forceTaskID == op.taskID {
            let taskIndex = workspace.tasks.firstIndex(where: { $0.id == op.taskID })
            if op.action == .upsert && taskIndex == nil {
                workspace.clearCalendarOp(for: op.taskID)
                _ = persist()
                continue
            }
            var proxyTask = taskIndex.map { workspace.tasks[$0] } ?? FocusTask(
                id: op.taskID,
                title: op.snapshot?.title ?? "Tarea eliminada",
                scheduledAt: op.snapshot?.start ?? op.baselineSnapshot?.start ?? instant,
                calendarEventID: op.eventID,
                calendarSnapshot: op.baselineSnapshot
            )
            let force = op.force || (forceTaskID == op.taskID)
            if force, let eventID = proxyTask.calendarEventID, calendar.store.event(withIdentifier: eventID) == nil {
                proxyTask.calendarEventID = nil
                proxyTask.calendarSnapshot = nil
            }
            do {
                switch op.action {
                case .upsert:
                    if let targetSnapshot = op.snapshot {
                        let saved = try calendar.project(proxyTask, calendarID: calendarID, value: targetSnapshot, force: force)
                        if let taskIndex {
                            workspace.tasks[taskIndex].calendarEventID = saved.0
                            workspace.tasks[taskIndex].calendarSnapshot = saved.1
                        }
                        if workspace.session?.task.id == op.taskID {
                            workspace.session?.task.calendarEventID = saved.0
                            workspace.session?.task.calendarSnapshot = saved.1
                        }
                    }
                case .remove:
                    try calendar.remove(proxyTask, calendarID: calendarID, force: force)
                    if let taskIndex {
                        workspace.tasks[taskIndex].calendarEventID = nil
                        workspace.tasks[taskIndex].calendarSnapshot = nil
                    }
                    if workspace.session?.task.id == op.taskID {
                        workspace.session?.task.calendarEventID = nil
                        workspace.session?.task.calendarSnapshot = nil
                    }
                }
                workspace.clearCalendarOp(for: op.taskID)
                guard persist() else { return }
            } catch let bridgeErr as CalendarBridge.BridgeError {
                if bridgeErr.isTransient {
                    var updatedOp = op
                    updatedOp.attempts += 1
                    updatedOp.lastError = bridgeErr.errorDescription
                    workspace.enqueueCalendarOp(updatedOp)
                } else {
                    workspace.clearCalendarOp(for: op.taskID)
                }
                issues[op.taskID] = bridgeErr.errorDescription
                _ = persist()
            } catch {
                var updatedOp = op
                updatedOp.attempts += 1
                updatedOp.lastError = error.localizedDescription
                workspace.enqueueCalendarOp(updatedOp)
                issues[op.taskID] = error.localizedDescription
                _ = persist()
            }
        }

        // 2. Reconcile all remaining tasks
        for index in workspace.tasks.indices {
            var task = workspace.tasks[index]
            let isSessionTask = session?.task.id == task.id
            let force = (forceTaskID == task.id)
            if force, let eventID = task.calendarEventID, calendar.store.event(withIdentifier: eventID) == nil {
                task.calendarEventID = nil
                task.calendarSnapshot = nil
            }
            do {
                let projection: CalendarProjection = (forceTaskID == task.id) && !isSessionTask && !task.completed && task.isScheduled
                    ? .event(CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end))
                    : CalendarProjection.make(task: task, session: session, now: instant, uptime: uptime)
                switch projection {
                case .event(let value):
                    let saved = try calendar.project(task, calendarID: calendarID, value: value, force: force)
                    task.calendarEventID = saved.0
                    task.calendarSnapshot = saved.1
                    if workspace.session?.task.id == task.id {
                        workspace.session?.task.calendarEventID = saved.0
                        workspace.session?.task.calendarSnapshot = saved.1
                    }
                    workspace.clearCalendarOp(for: task.id)
                case .remove:
                    try calendar.remove(task, calendarID: calendarID, force: force)
                    task.calendarEventID = nil
                    task.calendarSnapshot = nil
                    if workspace.session?.task.id == task.id {
                        workspace.session?.task.calendarEventID = nil
                        workspace.session?.task.calendarSnapshot = nil
                    }
                    workspace.clearCalendarOp(for: task.id)
                case .unchanged:
                    if !task.completed { try calendar.validate(task, calendarID: calendarID) }
                }
                if workspace.tasks[index] != task {
                    workspace.tasks[index] = task
                    // Persist each returned ID before advancing to another external write.
                    guard persist() else { return }
                }
            } catch let bridgeErr as CalendarBridge.BridgeError {
                if bridgeErr.isTransient {
                    enqueueProjectionForTask(task, now: instant, force: force)
                }
                issues[task.id] = bridgeErr.errorDescription
            } catch {
                issues[task.id] = error.localizedDescription
            }
        }

        calendar.issues = issues
        calendar.pendingCount = workspace.pendingCalendarOps.count
        if issues.isEmpty && workspace.pendingCalendarOps.isEmpty {
            calendar.lastSync = instant
            calendar.message = "Eventos actualizados · selecciona FocusDesk en Vorssaint"
        } else if !workspace.pendingCalendarOps.isEmpty {
            calendar.message = "\(workspace.pendingCalendarOps.count) operación(es) pendientes en cola; se reintentarán automáticamente."
        } else {
            calendar.message = "\(issues.count) evento(s) sin sincronizar; revisa los avisos."
        }
    }

    func createIntegrationTest() {
        guard !preview, writable, !busy else { return }
        let task = FocusTask(title: "Prueba de conexión · FocusDesk", scheduledAt: Date().addingTimeInterval(120), minutes: 5, leadMinutes: 1)
        saveTask(task)
        notice = "Prueba creada: empieza en 2 minutos y dura 5. Puedes iniciarla, terminarla y eliminarla desde Hoy."
    }

    private func tick() {
        now = Date()
        ticks += 1
        let today = Calendar.current.startOfDay(for: now)
        if today != lastPrunedDay {
            // With the app open overnight, Hoy kept showing yesterday and new tasks were born yesterday, overdue.
            // Follow the day only if the user was on the day that just ended, not on a date chosen on purpose.
            if Calendar.current.isDate(selectedDate, inSameDayAs: lastPrunedDay) { selectedDate = now }
            lastPrunedDay = today
            // A dated copy per day, so a bad save or a mistake is recoverable from Ajustes → Restaurar copia.
            if !preview { try? store.createDailySnapshotIfNeeded(at: now) }
            workspace.prune(at: now)
            let rolled = rollMissedSeries(now: now)
            _ = persist()
            schedule()
            if rolled { syncCalendar() }
        }
        startDueAutoStartTasks()
        if ticks.isMultiple(of: 5) {
            accessible = MacActivity.accessibility
            observe()
        }
        // Replenish reminder queue when earlier reminders are consumed in a busy day (>60 reminders)
        if ticks.isMultiple(of: 10), !preview,
           ReminderPlan.needsReplenishment(scheduledIDs: reminders.scheduledIDs, tasks: workspace.tasks, sessionTaskID: session?.task.id, now: now) {
            schedule()
        }
        if let s = session, !s.paused, s.endedAt == nil, currentRemaining(for: s) <= 0, !overtimeNotified {
            overtimeNotified = true
            if !preview {
                reminders.notify(
                    "Tiempo previsto agotado",
                    body: "\(s.task.title) sigue activa. Termina, amplía +10 min o pausa desde el aviso o FocusDesk.",
                    category: ReminderService.overtimeCategory,
                    userInfo: ["taskID": s.task.id.uuidString],
                    identifier: "overtime-" + s.id.uuidString
                )
            }
        }
        // Crash-recovery checkpoint. Each one rewrites the whole workspace twice (file + rolling copy), so once a
        // minute is enough: a crash can cost at most the last minute of the session, and the Mac writes 4x less.
        if ticks.isMultiple(of: 60) {
            if var s = session, !s.paused {
                s.checkpoint(at: now, uptime: uptime)
                workspace.session = s
                _ = persist()
            }
        }
        if ticks.isMultiple(of: 15) {
            if !preview, !workspace.pendingCalendarOps.isEmpty,
               workspace.pendingCalendarOps.contains(where: { $0.attempts < 5 }) {
                syncCalendar()
            }
        }
    }

    /// Per-task auto-start from the design: only on an unlocked Mac, never retroactively (a start time that passed
    /// while the Mac slept stays a reminder), and never on top of another session.
    private func startDueAutoStartTasks() {
        guard writable, !busy else { return }
        let reference = Date()
        // Keyed by task and time, so a task snoozed to a new time starts on its own again at that time.
        func key(_ task: FocusTask) -> String { "\(task.id.uuidString)@\(Int(task.scheduledAt.timeIntervalSinceReferenceDate))" }
        guard let due = workspace.tasks.first(where: {
            $0.autoStart && !$0.completed && $0.isScheduled && !autoStartHandled.contains(key($0)) &&
            $0.scheduledAt <= reference && reference.timeIntervalSince($0.scheduledAt) < 90
        }) else { return }
        autoStartHandled.insert(key(due))
        if let current = session {
            if !preview {
                reminders.notify(
                    "«\(due.title)» no ha empezado sola",
                    body: "«\(current.task.title)» sigue en marcha. Empiézala cuando termines.",
                    category: ReminderService.taskCategory,
                    userInfo: ["taskID": due.id.uuidString]
                )
            }
            return
        }
        guard !screenIsLocked else { return }
        start(due)
        if !preview {
            reminders.notify("Empezada a su hora · \(due.title)", body: "Tienes \(due.minutes) minutos. Puedes pausarla con ⌃⌥⌘P.")
        }
    }

    func observe() {
        guard writable, let s = session, !s.paused, s.endedAt == nil else { return }
        let excludedIDs = Set(workspace.settings.excludedTitleApps.map(\.id))
        guard let fg = MacActivity.foreground(readTitle: workspace.settings.observeTitles, excludedAppIDs: excludedIDs),
              let id = fg.app.bundleIdentifier else { return }
        var exemptions = FocusRules.systemExemptBundleIDs
        if let ownID = Bundle.main.bundleIdentifier { exemptions.insert(ownID) }
        guard !exemptions.contains(id) else { return }
        // Never redirect while FocusDesk is presenting a modal open/save panel
        guard NSApp.modalWindow == nil else { return }

        let allowed = s.task.apps.isEmpty || s.task.apps.contains { $0.id == id }
        let at = Date()
        let currentUptime = uptime

        if allowed {
            lastAllowed = fg.app
            strictTracker.registerAllowedAppObserved()
        }

        let isNewInterruption = workspace.session?.observeForeground(
            appID: id,
            name: fg.app.localizedName ?? id,
            title: fg.title,
            titleStatus: fg.titleStatus,
            allowed: allowed,
            at: at,
            uptime: currentUptime
        ) ?? false

        if allowed, id != "com.brave.Browser" { domainEpisodeHost = nil }

        if isNewInterruption {
            notice = "\(fg.app.localizedName ?? id) está fuera del perfil de esta tarea."
            if !s.task.strict && !preview { notifyDistraction(notice ?? "", session: s) }
        }

        if !allowed && s.task.strict {
            let runningTarget = lastAllowed.flatMap { candidate in
                (candidate.isTerminated || !s.task.apps.contains(where: { a in a.id == candidate.bundleIdentifier })) ? nil : candidate
            } ?? NSWorkspace.shared.runningApplications.first { app in
                !app.isTerminated && s.task.apps.contains { $0.id == app.bundleIdentifier }
            }
            let decision = strictTracker.evaluateUnallowed(hasRunningAllowedApp: runningTarget != nil, at: at)
            switch decision {
            case .none, .cooldown:
                break
            case .redirect:
                if let target = runningTarget {
                    let ok = target.activate(options: [])
                    strictTracker.recordRedirectAttempt(succeeded: ok)
                    if !ok {
                        notice = "No se pudo volver a \(target.localizedName ?? "la app permitida"). Puedes pausar en cualquier momento."
                    }
                }
            case .pauseSession(let reason):
                pause()
                // pause() clears any prompt; this one has to wait for an answer and offer the allowed apps,
                // otherwise «Reanudar» just pauses again a few seconds later.
                resumePrompt = reason
                promptApps = s.task.apps
                pausedBySystem = true
                if !preview {
                    reminders.notify(
                        "Sesión en pausa · \(s.task.title)",
                        body: reason,
                        category: ReminderService.pausedCategory,
                        userInfo: ["taskID": s.task.id.uuidString],
                        identifier: "paused-" + s.id.uuidString
                    )
                }
                showWindow?()
                return
            }
        }

        if id == "com.brave.Browser", workspace.settings.observeBrave {
            let sessionID = s.id
            brave.read { [weak self] result in
                guard let self,
                      let current = self.session,
                      current.id == sessionID,
                      !current.paused,
                      current.endedAt == nil,
                      self.workspace.settings.observeBrave,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
                switch result {
                case .host(let host):
                    self.braveStatus = "Dominio activo: \(host)"
                    if self.workspace.session?.activities.last?.domain != host {
                        let outside = !FocusRules.domainAllowed(host, list: current.task.domains)
                        // One interruption per visit outside the task's domains, like apps; the notice also reaches
                        // the user, who is looking at Brave and not at FocusDesk's window.
                        let newVisit = outside && self.domainEpisodeHost == nil
                        self.domainEpisodeHost = outside ? (self.domainEpisodeHost ?? host) : nil
                        self.workspace.session?.record(
                            Activity(appID: id, name: "Brave", domain: host, interruption: newVisit),
                            at: Date(),
                            uptime: self.uptime
                        )
                        if outside {
                            self.notice = "\(host) no está en los dominios de la tarea. El control de webs es informativo."
                            if newVisit, !self.preview { self.notifyDistraction(self.notice ?? "", session: current) }
                        }
                    }
                case .permissionDenied:
                    self.braveStatus = "Permiso de Automatización denegado (dominio desconocido)"
                    if self.workspace.session?.activities.last?.domainStatus != "sin permiso" {
                        self.workspace.session?.record(
                            Activity(appID: id, name: "Brave", domainStatus: "sin permiso"),
                            at: Date(),
                            uptime: self.uptime
                        )
                    }
                case .noWindowOrTab:
                    self.braveStatus = "Sin ventana o pestaña activa en Brave"
                case .notRunning:
                    self.braveStatus = "Brave cerrado"
                case .timeout:
                    self.braveStatus = "Respuesta tardía de Brave (dominio desconocido)"
                case .unknown:
                    self.braveStatus = "Pestaña interna o dominio desconocido"
                }
            }
        }
    }

    /// "Vuelve a tu tarea" replaces the previous one instead of piling up, and sounds at most every 3 minutes.
    private func notifyDistraction(_ body: String, session s: WorkSession) {
        guard Date().timeIntervalSince(lastDistractionNotifyAt) >= 180 else { return }
        lastDistractionNotifyAt = Date()
        reminders.notify("Vuelve a tu tarea", body: body, identifier: "distraction-" + s.id.uuidString)
    }

    private func clearSessionNotifications(_ s: WorkSession) {
        reminders.removeDelivered(identifiers: ["distraction-", "overtime-", "paused-"].map { $0 + s.id.uuidString })
    }

    func deleteHistoryRecord(_ id: UUID) {
        guard writable else { return }
        workspace.history.removeAll { $0.id == id }
        _ = persist()
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusDesk-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WorkspaceStore(url: url).save(workspace)
            notice = "Copia exportada correctamente en \(url.lastPathComponent)."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func recoverFromAutoBackup() {
        do {
            let recovered = try store.recoverFromRollingBackup(at: Date())
            workspace = recovered
            writable = true
            hasUnsavedChanges = false
            corruptFileDetected = false
            error = nil
            notice = "Datos recuperados desde la última copia automática. El archivo anterior se ha conservado en la carpeta backups."
            schedule()
            syncCalendar()
        } catch {
            self.error = "No se pudo recuperar la copia automática: \(error.localizedDescription)"
        }
    }

    func resetCorruptWorkspacePreservingFile() {
        do {
            let savedCorrupt = try store.createTimestampedBackup(prefix: "corrupt-saved", at: Date())
            workspace = Workspace()
            try store.save(workspace)
            writable = true
            hasUnsavedChanges = false
            corruptFileDetected = false
            error = nil
            notice = "Agenda reiniciada. El archivo dañado original se ha conservado en \(savedCorrupt?.lastPathComponent ?? "backups")."
        } catch {
            self.error = "No se pudo reiniciar el archivo: \(error.localizedDescription)"
        }
    }

    func restoreBackup(from fileURL: URL) throws {
        let imported = try store.validateBackup(at: fileURL)
        let (restored, prevURL) = try store.restore(imported, at: Date())
        workspace = restored
        writable = true
        hasUnsavedChanges = false
        corruptFileDetected = false
        error = nil
        calendar.pendingCount = workspace.pendingCalendarOps.count
        schedule()
        syncCalendar()
        let prevName = prevURL?.lastPathComponent ?? "backups"
        notice = "Copia restaurada (\(restored.tasks.count) tareas, \(restored.history.count) sesiones). Respaldo previo guardado en \(prevName)."
    }

    func removeDetailedHistory() {
        guard writable else { return }
        for index in workspace.history.indices {
            workspace.history[index].preserveSummary()
            workspace.history[index].session.activities = []
            workspace.history[index].session.baseline = [:]
        }
        _ = persist()
    }

    func shutdown() {
        if session?.endedAt == nil {
            workspace.session?.pause(at: Date(), uptime: uptime)
            if let s = workspace.session {
                enqueueProjectionForTask(s.task, session: s, now: Date())
            }
        }
        _ = persist()
        syncCalendar()
    }
}
