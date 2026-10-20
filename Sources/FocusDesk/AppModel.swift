import AppKit
import Combine
import EventKit
import FocusCore

@MainActor
final class AppModel: ObservableObject {
    @Published var workspace = Workspace()
    @Published var now = Date()
    @Published var error: String?
    @Published var notice: String?
    @Published var evidenceMessage: String?
    @Published var changedFiles: [String] = []
    @Published var busy = false
    @Published var page = "Hoy"
    @Published var selectedDate = Date()
    @Published var editingTask: FocusTask?
    @Published var showCompletion = false
    @Published var accessible = MacActivity.accessibility
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
    private var lastSignature = ""
    private var lastInterruption = Date.distantPast
    private var lastRedirect = Date.distantPast
    private var ticks = 0
    private var overtimeNotified = false
    private var hasInitialBaseline = false
    var showWindow: (() -> Void)?

    init(directory: URL? = nil, preview: Bool = false) {
        self.preview = preview
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusDesk")
        store = WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
        do {
            workspace = try store.load(); workspace.prune(at: Date())
            if workspace.session != nil {
                // Only intervals persisted before termination can count after recovery.
                workspace.session?.runningSince = nil
                notice = "Sesión recuperada en pausa. Reanuda cuando estés preparado."
                if let recovered = workspace.session, recovered.endedAt != nil {
                    changedFiles = recovered.finalChangedFiles ?? []
                    evidenceMessage = recovered.finalEvidenceMessage ?? (recovered.finalChangedFiles == nil ? "La revisión de archivos no llegó a guardarse. Confirma el resultado manualmente." : nil)
                    showCompletion = true
                }
            }
        } catch { writable = false; self.error = "No se han podido leer tus datos. Se han conservado intactos en \(store.url.path). \(error.localizedDescription)" }
        hasInitialBaseline = workspace.session?.baselineValid ?? false
        if preview { notice = "DEMOSTRACIÓN · Datos separados de tu agenda. Notificaciones desactivadas." }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseForSystem() }
            })
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = heartbeat; RunLoop.main.add(heartbeat, forMode: .common)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(700), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.checkCalendar() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.checkCalendar()
                Task { await self?.reminders.refresh() }
            }.store(in: &subscriptions)
        if writable { persist(); syncCalendar() }
        schedule()
    }
    var session: WorkSession? { workspace.session }
    var tasks: [FocusTask] { workspace.tasks.filter { !$0.completed }.sorted { $0.scheduledAt < $1.scheduledAt } }
    var next: FocusTask? { tasks.first { $0.id != session?.task.id } }
    var readOnly: Bool { !writable }
    var menuTitle: String {
        if let s = session { return (s.endedAt != nil ? "Confirmar" : s.paused ? "Pausa" : FocusRules.clock(s.remaining(at: now))) }
        if let upcoming = tasks.first(where: { $0.scheduledAt > now }), upcoming.scheduledAt.timeIntervalSince(now) <= Double(upcoming.leadMinutes) * 60 { return "En " + FocusRules.clock(upcoming.scheduledAt.timeIntervalSince(now)) }
        return "FocusDesk"
    }
    @discardableResult func persist() -> Bool {
        guard writable else { return false }
        do { try store.save(workspace); return true }
        catch {
            workspace.session?.pause(at: Date())
            writable = false
            self.error = "No se pudo guardar. La sesión se ha pausado; conserva esta ventana abierta y exporta una copia. \(error.localizedDescription)"
            return false
        }
    }
    func updateSettings(_ mutate: (inout Settings) -> Void) { guard writable else { return }; mutate(&workspace.settings); persist() }
    func saveTask(_ input: FocusTask) {
        guard writable, !busy, input.valid, input.id != session?.task.id else { return }
        var task = input; task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = workspace.tasks.firstIndex(where: { $0.id == task.id }) { workspace.tasks[index] = task }
        else { workspace.tasks.append(task) }
        guard persist() else { return }; editingTask = nil; schedule(); syncCalendar()
    }
    func deleteTask(_ task: FocusTask) {
        guard writable, !busy, task.id != session?.task.id else { return }
        if let id = workspace.settings.calendarID {
            do { try calendar.remove(task, calendarID: id) } catch { self.error = error.localizedDescription; return }
        }
        workspace.tasks.removeAll { $0.id == task.id }; persist(); schedule()
    }
    func shift(_ task: FocusTask, to date: Date) { var task = task; task.scheduledAt = date; saveTask(task) }
    func schedule() { if !preview { reminders.schedule(workspace.tasks, sessionTaskID: session?.task.id) } }

    func start(_ task: FocusTask) {
        guard session == nil, !busy, !readOnly, task.valid, !task.completed else { return }
        busy = true; changedFiles = []; evidenceMessage = nil
        Task {
            let snapshot = await scanner.scan(task.folder)
            guard session == nil, writable, workspace.tasks.contains(where: { $0 == task }) else { busy = false; notice = "La tarea cambió antes de empezar. Revisa su configuración."; return }
            var s = WorkSession(task: task)
            s.baseline = snapshot.files; s.baselineValid = snapshot.valid
            hasInitialBaseline = snapshot.valid; workspace.session = s
            evidenceMessage = snapshot.message; now = Date(); overtimeNotified = false
            lastSignature = ""; lastAllowed = nil; lastInterruption = .distantPast
            busy = false; guard persist() else { return }; schedule(); syncCalendar()
            if let allowed = task.apps.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: allowed.id) {
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
                catch { notice = "No se pudo abrir \(allowed.name). Puedes abrirla manualmente o pausar." }
            }
        }
    }
    func pause() {
        guard writable, workspace.session != nil, workspace.session?.endedAt == nil else { return }
        workspace.session?.pause(at: Date()); persist(); syncCalendar()
    }
    func resume() {
        guard writable, workspace.session != nil else { return }
        guard workspace.session?.endedAt == nil else { showCompletion = true; return }
        now = Date(); workspace.session?.resume(at: now); lastSignature = ""; lastInterruption = .distantPast; persist(); syncCalendar(); observe()
    }
    func addTime() { guard writable, workspace.session?.endedAt == nil else { return }; workspace.session?.add(minutes: 10); overtimeNotified = false; persist(); syncCalendar() }
    @objc private func screenLocked() { pauseForSystem() }
    private func pauseForSystem() {
        guard let s = session, !s.paused, s.endedAt == nil else { return }
        pause(); notice = "Sesión en pausa por reposo o bloqueo del Mac."
    }
    func finish() {
        guard writable, var s = session, !busy else { return }
        if s.endedAt != nil { showCompletion = true; showWindow?(); return }
        s.finish(at: Date()); workspace.session = s; persist(); syncCalendar()
        busy = true
        Task {
            let snapshot = await scanner.scan(s.task.folder)
            guard workspace.session?.id == s.id else { busy = false; return }
            changedFiles = hasInitialBaseline && snapshot.valid ? FocusRules.changed(before: s.baseline, after: snapshot.files) : []
            evidenceMessage = hasInitialBaseline ? snapshot.message : "Sin lectura inicial válida; resultado pendiente de tu confirmación."
            workspace.session?.finalChangedFiles = changedFiles
            workspace.session?.finalEvidenceMessage = evidenceMessage
            persist()
            busy = false; showCompletion = true; showWindow?()
        }
    }
    func confirm(completed: Bool, note: String) {
        guard writable, !busy, let s = session, s.endedAt != nil else { return }
        var recordSession = s; recordSession.baseline = [:]
        workspace.history.insert(SessionRecord(session: recordSession, completed: completed, note: note, changedFiles: changedFiles), at: 0)
        if let index = workspace.tasks.firstIndex(where: { $0.id == s.task.id }) {
            workspace.tasks[index].completed = completed
            if completed, let next = workspace.tasks[index].nextOccurrence(after: Date()) { workspace.tasks.append(next) }
        }
        workspace.session = nil; showCompletion = false; changedFiles = []; persist(); schedule(); syncCalendar()
        notice = completed ? "Tarea terminada. La siguiente conserva su horario." : "Sesión guardada. La tarea sigue pendiente."
    }
    func setCheck(_ key: String, value: Bool) {
        guard writable, session?.endedAt == nil else { return }
        if value { workspace.session?.checked.insert(key) } else { workspace.session?.checked.remove(key) }; persist()
    }
    func chooseCalendarSource(_ source: EKSource) {
        guard writable, !preview, workspace.settings.calendarID == nil else { return }
        do { connectCalendar(try calendar.create(in: source)) }
        catch { self.error = error.localizedDescription }
    }
    func connectCalendar(_ id: String) {
        guard writable, !preview, workspace.settings.calendarID == nil, let chosen = calendar.connected(id), chosen.title == "FocusDesk", chosen.allowsContentModifications else { return }
        workspace.settings.calendarID = id
        guard persist() else { return }
        syncCalendar()
    }
    func disconnectCalendar() {
        guard writable else { return }
        // Leave external events intact. This is an explicit disconnect, never silent cleanup.
        workspace.settings.calendarID = nil
        for index in workspace.tasks.indices { workspace.tasks[index].calendarEventID = nil; workspace.tasks[index].calendarSnapshot = nil }
        calendar.issues = [:]; calendar.lastSync = nil; calendar.message = "Desconectado. Los eventos existentes se conservan en Calendar."
        persist()
    }
    func checkCalendar() {
        guard !preview else { return }
        calendar.refresh()
        guard let id = workspace.settings.calendarID else { return }
        guard let connected = calendar.connected(id), connected.allowsContentModifications else {
            calendar.message = "Conexión pendiente: falta permiso o el calendario ya no está disponible."; return
        }
        var issues: [UUID: String] = [:]
        for task in workspace.tasks where task.calendarEventID != nil && !task.completed {
            do { try calendar.validate(task, calendarID: id) } catch { issues[task.id] = error.localizedDescription }
        }
        calendar.issues = issues
        calendar.message = issues.isEmpty ? "Conectado a \(connected.title) · \(connected.source.title)" : "\(issues.count) evento(s) requieren revisión. No se han sobrescrito."
    }
    func syncCalendar(forceTaskID: UUID? = nil) {
        guard writable, !preview, let calendarID = workspace.settings.calendarID else { return }
        guard calendar.authorized, let connected = calendar.connected(calendarID), connected.allowsContentModifications else { calendar.message = "Sin permiso o calendario disponible. Revisa la conexión; tus sesiones siguen disponibles."; return }
        let instant = Date()
        var issues: [UUID: String] = [:]
        for index in workspace.tasks.indices {
            var task = workspace.tasks[index]
            let force = forceTaskID == task.id
            if force, let eventID = task.calendarEventID, calendar.store.event(withIdentifier: eventID) == nil {
                task.calendarEventID = nil; task.calendarSnapshot = nil
            }
            do {
                let projection: CalendarProjection = force && session?.task.id != task.id && !task.completed ? .event(CalendarSnapshot(title: task.title, start: task.scheduledAt, end: task.end)) : CalendarProjection.make(task: task, session: session, now: instant)
                switch projection {
                case .event(let value):
                    let saved = try calendar.project(task, calendarID: calendarID, value: value, force: force)
                    task.calendarEventID = saved.0; task.calendarSnapshot = saved.1
                case .remove:
                    try calendar.remove(task, calendarID: calendarID, force: force)
                    task.calendarEventID = nil; task.calendarSnapshot = nil
                case .unchanged:
                    if !task.completed { try calendar.validate(task, calendarID: calendarID) }
                }
                if workspace.tasks[index] != task {
                    workspace.tasks[index] = task
                    // Persist each returned ID before advancing to another external write.
                    guard persist() else { return }
                }
            } catch { issues[task.id] = error.localizedDescription }
        }
        calendar.issues = issues
        if issues.isEmpty {
            calendar.lastSync = instant
            calendar.message = "Eventos actualizados · selecciona FocusDesk en Vorssaint"
        } else { calendar.message = "\(issues.count) evento(s) sin sincronizar; revisa los avisos." }
    }
    func createIntegrationTest() {
        guard !preview, writable, !busy else { return }
        let task = FocusTask(title: "Prueba de conexión · FocusDesk", scheduledAt: Date().addingTimeInterval(120), minutes: 5, leadMinutes: 1)
        saveTask(task)
        notice = "Prueba creada: empieza en 2 minutos y dura 5. Puedes iniciarla, terminarla y eliminarla desde Hoy."
    }
    private func tick() {
        now = Date(); ticks += 1
        let today = Calendar.current.startOfDay(for: now)
        if today != lastPrunedDay { lastPrunedDay = today; workspace.prune(at: now); persist(); schedule() }
        if ticks.isMultiple(of: 5) { accessible = MacActivity.accessibility; observe() }
        if let s = session, !s.paused, s.endedAt == nil, s.remaining(at: now) <= 0, !overtimeNotified {
            overtimeNotified = true
            if !preview { reminders.notify("Tiempo previsto agotado", body: "\(s.task.title) sigue activa. Termina, amplía o pausa desde FocusDesk.") }
        }
        if ticks.isMultiple(of: 15), var s = session, !s.paused {
            s.accumulated = s.elapsed(at: now); s.runningSince = now; workspace.session = s; persist()
        }
    }
    func observe() {
        guard writable, let s = session, !s.paused, s.endedAt == nil, let fg = MacActivity.foreground(readTitle: workspace.settings.observeTitles), let id = fg.app.bundleIdentifier else { return }
        let exemptions: Set<String> = [Bundle.main.bundleIdentifier ?? "local.focusdesk.app", "com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.notificationcenterui", "com.apple.dock", "com.vorssaint.utils"]
        guard !exemptions.contains(id) else { return }
        let allowed = s.task.apps.isEmpty || s.task.apps.contains { $0.id == id }
        let at = Date()
        if allowed { lastAllowed = fg.app }
        let interrupt = !allowed && at.timeIntervalSince(lastInterruption) > 8
        let signature = id + (fg.title ?? "")
        if lastSignature != signature || interrupt {
            workspace.session?.record(Activity(appID: id, name: fg.app.localizedName ?? id, title: fg.title, interruption: interrupt))
            lastSignature = signature
        }
        if interrupt {
            lastInterruption = at; notice = "\(fg.app.localizedName ?? id) está fuera del perfil de esta tarea."
            if !s.task.strict && !preview { reminders.notify("Vuelve a tu tarea", body: notice ?? "") }
        }
        if !allowed && s.task.strict && at.timeIntervalSince(lastRedirect) > 1.5 {
            lastRedirect = at
            let target = lastAllowed.flatMap { $0.isTerminated ? nil : $0 } ?? NSWorkspace.shared.runningApplications.first { app in s.task.apps.contains { $0.id == app.bundleIdentifier } }
            if let target { if !target.activate(options: []) { notice = "No se pudo volver a \(target.localizedName ?? "la app permitida"). Puedes pausar." } }
            else { pause(); showWindow?(); notice = "Sesión pausada: no hay ninguna app permitida abierta. Abre una y reanuda." }
        }
        if id == "com.brave.Browser", workspace.settings.observeBrave {
            let sessionID = s.id
            brave.read { [weak self] host in
                guard let self, let current = self.session, current.id == sessionID, !current.paused, current.endedAt == nil, self.workspace.settings.observeBrave, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
                guard let host else { return }
                if self.workspace.session?.activities.last?.domain != host {
                    let outside = !FocusRules.domainAllowed(host, list: current.task.domains)
                    self.workspace.session?.record(Activity(appID: id, name: "Brave", domain: host))
                    if outside { self.notice = "\(host) no está en los dominios de la tarea. El control de webs es informativo." }
                }
            }
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "FocusDesk-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try WorkspaceStore(url: url).save(workspace) } catch { self.error = error.localizedDescription }
    }
    func removeDetailedHistory() {
        guard writable else { return }
        for index in workspace.history.indices { workspace.history[index].session.activities = []; workspace.history[index].session.baseline = [:] }
        persist()
    }
    func shutdown() { if session?.endedAt == nil { workspace.session?.pause(at: Date()) }; persist(); syncCalendar() }
}
