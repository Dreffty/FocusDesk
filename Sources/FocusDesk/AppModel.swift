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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if writable { persist() }
        // A recovered paused session must not leave a running calendar countdown.
        if workspace.session?.paused == true { syncCalendar() }
        schedule()
    }
    var session: WorkSession? { workspace.session }
    var tasks: [FocusTask] { workspace.tasks.filter { !$0.completed }.sorted { $0.scheduledAt < $1.scheduledAt } }
    var next: FocusTask? { tasks.first { $0.id != session?.task.id } }
    var readOnly: Bool { !writable }
    var menuTitle: String {
        if let s = session { return (s.endedAt != nil ? "Confirmar" : s.paused ? "Pausa" : FocusRules.clock(s.remaining(at: now))) }
        if let next, next.scheduledAt > now, next.scheduledAt.timeIntervalSince(now) <= Double(next.leadMinutes) * 60 { return "En " + FocusRules.clock(next.scheduledAt.timeIntervalSince(now)) }
        return "FocusDesk"
    }
    func persist() {
        guard writable else { return }
        do { try store.save(workspace) } catch { self.error = "No se pudo guardar: \(error.localizedDescription)" }
    }
    func updateSettings(_ mutate: (inout Settings) -> Void) { mutate(&workspace.settings); persist() }
    func saveTask(_ input: FocusTask) {
        guard writable, input.valid, input.id != session?.task.id else { return }
        var task = input; task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = workspace.tasks.firstIndex(where: { $0.id == task.id }) { workspace.tasks[index] = task }
        else { workspace.tasks.append(task) }
        editingTask = nil; persist(); schedule(); syncCalendar()
    }
    func deleteTask(_ task: FocusTask) {
        guard task.id != session?.task.id else { return }
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
            guard session == nil else { busy = false; return }
            var s = WorkSession(task: task)
            s.baseline = snapshot.files; s.baselineValid = snapshot.valid
            hasInitialBaseline = snapshot.valid; workspace.session = s
            evidenceMessage = snapshot.message; now = Date(); overtimeNotified = false
            lastSignature = ""; lastAllowed = nil; lastInterruption = .distantPast
            busy = false; persist(); schedule(); syncCalendar()
            if let allowed = task.apps.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: allowed.id) {
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
                catch { notice = "No se pudo abrir \(allowed.name). Puedes abrirla manualmente o pausar." }
            }
        }
    }
    func pause() {
        guard workspace.session?.endedAt == nil else { return }
        workspace.session?.pause(at: Date()); persist(); syncCalendar()
    }
    func resume() {
        guard workspace.session?.endedAt == nil else { showCompletion = true; return }
        workspace.session?.resume(at: Date()); lastSignature = ""; persist(); syncCalendar()
    }
    func addTime() { workspace.session?.add(minutes: 10); overtimeNotified = false; persist(); syncCalendar() }
    @objc private func screenLocked() { pauseForSystem() }
    private func pauseForSystem() {
        guard let s = session, !s.paused, s.endedAt == nil else { return }
        pause(); notice = "Sesión en pausa por reposo o bloqueo del Mac."
    }
    func finish() {
        guard var s = session, !busy else { return }
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
        guard let s = session, s.endedAt != nil else { return }
        var recordSession = s; recordSession.baseline = [:]
        workspace.history.insert(SessionRecord(session: recordSession, completed: completed, note: note, changedFiles: changedFiles), at: 0)
        if let index = workspace.tasks.firstIndex(where: { $0.id == s.task.id }) {
            workspace.tasks[index].completed = completed
            if completed, let next = workspace.tasks[index].nextOccurrence() { workspace.tasks.append(next) }
        }
        workspace.session = nil; showCompletion = false; changedFiles = []; persist(); schedule(); syncCalendar()
        notice = completed ? "Tarea terminada. La siguiente conserva su horario." : "Sesión guardada. La tarea sigue pendiente."
    }
    func setCheck(_ key: String, value: Bool) {
        if value { workspace.session?.checked.insert(key) } else { workspace.session?.checked.remove(key) }; persist()
    }
    func chooseCalendarSource(_ source: EKSource) {
        do { workspace.settings.calendarID = try calendar.create(in: source); persist(); syncCalendar() }
        catch { self.error = error.localizedDescription }
    }
    func syncCalendar() {
        guard let calendarID = workspace.settings.calendarID else { return }
        guard calendar.authorized else { calendar.message = "Sin permiso de calendario. Sesiones disponibles en FocusDesk."; return }
        do {
            for index in workspace.tasks.indices {
                var task = workspace.tasks[index]
                if let s = session, s.task.id == task.id {
                    if let end = s.endedAt {
                        task.calendarEventID = try calendar.project(task, calendarID: calendarID, start: s.startedAt, end: end)
                    } else if s.paused {
                        try calendar.remove(task, calendarID: calendarID); task.calendarEventID = nil
                    } else {
                        // An overdue session cannot be represented by a future deadline without lying.
                        let end = now.addingTimeInterval(s.remaining(at: now))
                        task.calendarEventID = try calendar.project(task, calendarID: calendarID, start: s.startedAt, end: max(end, s.startedAt.addingTimeInterval(1)))
                    }
                } else if !task.completed && task.end > now {
                    task.calendarEventID = try calendar.project(task, calendarID: calendarID, start: task.scheduledAt, end: task.end)
                }
                workspace.tasks[index] = task
            }
            calendar.message = "Eventos enviados a Calendar · activa FocusDesk en Vorssaint"
            persist()
        } catch { calendar.message = "Sin sincronizar: \(error.localizedDescription)"; persist() }
    }
    private func tick() {
        now = Date(); ticks += 1
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
        guard let s = session, !s.paused, s.endedAt == nil, let fg = MacActivity.foreground(readTitle: workspace.settings.observeTitles), let id = fg.app.bundleIdentifier else { return }
        let exemptions: Set<String> = [Bundle.main.bundleIdentifier ?? "local.focusdesk.app", "com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.notificationcenterui", "com.vorssaint.utils"]
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
            else { showWindow?(); notice = "Abre una aplicación permitida o pausa la sesión." }
        }
        if id == "com.brave.Browser", workspace.settings.observeBrave {
            let sessionID = s.id
            brave.read { [weak self] host in
                guard let self, let current = self.session, current.id == sessionID, !current.paused, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == id else { return }
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
        for index in workspace.history.indices { workspace.history[index].session.activities = []; workspace.history[index].session.baseline = [:] }
        persist()
    }
    func shutdown() { if session?.endedAt == nil { workspace.session?.pause(at: Date()) }; persist(); syncCalendar() }
}
