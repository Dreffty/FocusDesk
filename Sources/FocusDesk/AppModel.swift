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
    @Published var error: String? { didSet { announce(error, oldValue: oldValue, priority: .high) } }
    @Published var notice: String? { didSet { announce(notice, oldValue: oldValue, priority: .medium) } }
    @Published var evidenceMessage: String?
    @Published var changedFiles: [String] = []
    @Published var writingFiles: [String] = []
    @Published var selectedDeliverables: Set<String> = []
    @Published var manualAttachments: [String] = []
    @Published var busy = false
    /// Ajustes lives in its own window now; asking for the old page opens that window instead.
    @Published var page = "Hoy" {
        didSet {
            if page == AppPage.settings.rawValue {
                page = oldValue == AppPage.settings.rawValue ? AppPage.today.rawValue : oldValue
                showSettings?(nil)
            }
        }
    }
    var showSettings: ((SettingsSectionTab?) -> Void)?
    /// The keyboard shortcuts sheet, owned by the app delegate.
    var showShortcutsHelp: (() -> Void)?
    /// «Buscar función» (⌘K): one place to find any feature or setting by name.
    @Published var showFeatureFinder = false
    /// What is new since the last version the user saw; also reachable from Ayuda.
    @Published var showWhatsNew = false
    /// Historial shows the blocking audit log instead of the sessions.
    @Published var historyShowsAudit = false
    @Published var selectedDate = Date()
    @Published var editingTask: FocusTask?
    @Published var editingGeneralRule: GeneralBlockRule?
    @Published var showCompletion = false
    @Published var accessible = MacActivity.accessibility
    /// macOS says the permission is granted but every call fails: the block cannot act and has to say so.
    @Published var accessibilityBroken = false
    @Published var braveStatus = "En espera"
    /// The challenge or wait standing between the user and stopping a protected session.
    @Published var pendingStop: PendingStopChallenge?
    /// Somebody moved the Mac's clock forward during a protected session.
    @Published var clockWarning: String?
    @Published var hasUnsavedChanges = false
    @Published var corruptFileDetected = false
    /// Task the user asked to start while another session was running. Drives the explicit hand-off question.
    @Published var handoffRequest: FocusTask?
    /// Stays on screen until acted upon, unlike `notice`, so a session paused by the Mac is never missed.
    @Published var resumePrompt: String? { didSet { announce(resumePrompt, oldValue: oldValue, priority: .high) } }
    /// True while ⌃⌥⌘P and ⌃⌥⌘T are registered system-wide for the running session (set by the app delegate).
    var sessionHotKeysActive = false
    /// The Hoy banner about disabled reminders can be hidden for this launch.
    @Published var notificationBannerDismissed = false
    private var askedForNotifications = false
    /// Allowed apps offered as "Abrir …" buttons next to `resumePrompt` (strict pause with no allowed app open).
    @Published var promptApps: [AllowedApp] = []
    var lastDistractionNotifyAt = Date.distantPast
    /// Host of the current visit outside the task's domains; one interruption and one notice per visit.
    var domainEpisodeHost: String?
    var screenIsLocked = false
    /// Tasks already started on their own (or skipped because another session was running), so it happens once.
    private var autoStartHandled: Set<String> = []
    /// Whether any FocusDesk window or the menu-bar panel is on screen (set by the app delegate).
    var isInterfaceVisible: (() -> Bool)?
    private var lastObservedAppID: String?
    private var lastBraveReadAt = Date.distantPast
    var lastTitleAppID: String?
    private var lastTitleReadAt = Date.distantPast
    var lastTitle: (title: String?, status: String?) = (nil, nil)

    /// Undo and redo for direct agenda edits (drag, snooze, inbox, delete), in the Edit menu with ⌘Z and ⇧⌘Z
    /// (`undo-and-redo.md › Desktop`). The main window hands this manager to AppKit. Each step only applies while
    /// nothing else changed the agenda since, so it never reverts an unrelated edit made afterwards.
    let undoManager: UndoManager = {
        // Explicit groups, one per agenda change: AppKit's per-event grouping left a group open when the change
        // did not come from a user event, and an open group cannot be undone.
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    let calendar = CalendarBridge()
    let reminders = ReminderService()
    let focusMode = FocusModeController()
    private var warnedMissingFocusShortcuts = false
    let scanner = EvidenceScanner()
    let brave = BraveReader()
    /// Reads and steers tabs in every browser FocusDesk knows, not only Brave.
    let webInspector = WebInspector()
    /// The login item that brings FocusDesk back if it is killed mid-session.
    let relaunchGuard = RelaunchGuard()
    let store: WorkspaceStore
    let preview: Bool

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var lastPrunedDay = Calendar.current.startOfDay(for: Date())
    var writable = true
    var lastAllowed: NSRunningApplication?
    var strictTracker = StrictRedirectTracker()
    /// Times an allowed app was opened because none was running; reset when one is seen in front.
    var strictLaunchAttempts = 0
    var strictRecheck: DispatchWorkItem?
    /// Last read of each browser's address bar, so one `osascript` per browser does not pile up.
    var lastWebReadAt: [String: Date] = [:]
    /// The last tab FocusDesk acted on, so one visit is not acted on twice while the browser is still changing it.
    /// Only for a few seconds: going Back to the blocked site has to be blocked again.
    var lastWebBlockHost: String?
    var lastWebBlockAt = Date.distantPast
    /// Page inside an Electron app already reported, so the same one is not announced on every scan.
    var embeddedReportedHost: String?
    /// Browsers whose address cannot be read, already warned about during this session.
    var warnedUnreadableBrowsers: Set<String> = []
    /// Keeps macOS from napping FocusDesk while a session blocks something (`keepAwakeForSession`).
    private var napActivity: NSObjectProtocol?
    /// macOS asked FocusDesk to quit for a restart, a shutdown or a log-out: it goes, and the session comes back.
    var quittingForSystem = false
    /// The pause came from the screen locking, the Mac sleeping or another account taking over — the only pauses
    /// a protected session takes back by itself.
    private var pausedByLockOrSleep = false
    /// Last sweep of windows visible without the keyboard focus.
    var lastBackgroundSweepAt = Date.distantPast
    /// Last look at which System Settings pane is open.
    var lastSettingsGuardAt = Date.distantPast
    /// Last scan of pages embedded in Electron apps (the costliest check, so the rarest).
    var lastEmbeddedScanAt = Date.distantPast
    /// A stop whose code was just typed correctly: lets it through the gate once, without asking again.
    var authorizedStop: StopReason?
    /// Whether the end of a pending wait has already been announced.
    var stopReadyNotified = false
    /// A change to a task about to start whose way out was just paid: lets that one change through once.
    var authorizedRunUp: UUID?
    /// Waits asked for to change a protected task before it starts («Esperar unos minutos»), by task.
    /// Kept in memory only: quitting FocusDesk just means waiting again, which is never a way out.
    var runUpWaits: [UUID: StopRequest] = [:]
    var runUpWaitsNotified: Set<UUID> = []
    /// A change to an active protected general rule whose code was just typed: lets it through once.
    var authorizedGeneralRule: UUID?
    var generalRuleWaitsNotified: Set<UUID> = []
    /// Last timestamp when `.dailyLimit` usage seconds were credited.
    var lastGeneralQuotaAt: Date?
    /// Last Pomodoro phase announced for the running task (session, block, focus or break).
    var lastTaskPomodoroKey: String?
    /// Last observed `(host, path)` per browser bundle ID for general rules and daily limit timers.
    var lastObservedBrowserPage: [String: (host: String, path: String, at: Date)] = [:]
    /// Daily-limit rules that already notified exhaustion today (`dayKey-ruleID`).
    var quotaExhaustedNotifiedToday: Set<String> = []
    /// Pre-block reminder keys sent today (`dayKey-ruleID-5m`, `dayKey-ruleID-1m`).
    var quotaWarningsSentToday: Set<String> = []
    /// Timestamp when the current active League of Legends match (`GameClient`) started.
    var activeLoLMatchStartedAt: Date?
    /// Monotonic uptime when the current active League of Legends match (`GameClient`) started.
    var activeLoLMatchStartedContinuous: Double?
    /// Rules currently inside their post-match grace countdown (so we terminate LoL the instant the 60s countdown ends).
    var postMatchGraceArmedRules: Set<UUID> = []
    /// Rules whose 60-min verified study goal unlock was already announced today (`dayKey-ruleID`).
    var studyGoalUnlockedNotifiedToday: Set<String> = []
    /// Last timestamp when 1-second passive study tracking ticked.
    var lastPassiveStudyTickAt: Date?
    /// Continuous active screen-work seconds accumulated before triggering a rest break (`tickAsScreenBreak`).
    @Published var continuousActiveWorkSeconds: TimeInterval = 0
    /// Active continuous screen-work rest break deadline, when triggered.
    @Published var activeContinuousBreakDeadline: TrustedDeadline?
    /// Rotating motivational message chosen for the active continuous break.
    @Published var activeContinuousBreakMessage: String = ""
    /// Discreet non-activating floating countdown pill in the top-right corner of the screen (`showTimer`).
    let floatingPill = FloatingTimerPillController()
    /// Dismissed break key (`dayKey-breakID-startHour:startMinute`) so the user can snooze/dismiss a break banner once.
    @Published var dismissedBreakKey: String?
    /// Last observed `NSPasteboard.general.changeCount` for `ClipboardGuardRules`.
    var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    /// One Finder question at a time: a slow Finder must not pile up `osascript` processes.
    var finderCheckBusy = false
    /// The Finder permission is asked for by macOS; if it was refused, this is said once per session.
    var warnedFinderPermission = false
    private var ticks = 0
    var overtimeNotified = false
    private var hasInitialBaseline = false
    /// Task to start once the current session's result is confirmed (set by an accepted hand-off).
    var queuedStartTaskID: UUID?
    /// True when the pause came from the Mac (sleep, lock, user switch) and not from the user pressing Pausar.
    var pausedBySystem = false
    private var dayCache: [String: (real: [FocusTask], projected: [FocusTask])] = [:]
    var showWindow: (() -> Void)?
    var toggleCompactPanel: (() -> Void)?
    var onHotKeySettingsChanged: (() -> Void)?

    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Notices appear far from VoiceOver's cursor: read them out when they change, errors and prompts first.
    private func announce(_ text: String?, oldValue: String?, priority: NSAccessibilityPriorityLevel) {
        guard let text, text != oldValue, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: priority.rawValue]
        )
    }

    init(directory: URL? = nil, preview: Bool = false) {
        self.preview = preview
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FocusDesk")
        store = WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
        var resumeProtected = false
        do {
            workspace = try store.load()
            // Some elements could not be read: keep the original file untouched in backups/ before anything is
            // written over it, and say so instead of locking the whole agenda (one bad field used to do that).
            if workspace.decodingSkipped > 0 {
                let kept = try? store.createTimestampedBackup(prefix: "lectura-parcial", at: Date())
                let count = workspace.decodingSkipped
                error = "\(count == 1 ? "Un elemento" : "\(count) elementos") de tus datos no se \(count == 1 ? "podía" : "podían") leer y se \(count == 1 ? "ha" : "han") dejado fuera. El resto funciona con normalidad; el archivo original está guardado en \(kept?.lastPathComponent ?? "backups")."
            }
            workspace.prune(at: Date())
            workspace.closedBySystemAt = nil
            if workspace.session != nil {
                // Decided on the session as it was saved, before it is paused just below.
                resumeProtected = workspace.session?.shouldResumeAfterRelaunch(now: Date()) == true
                // Only intervals persisted before termination can count after recovery.
                workspace.session?.runningSince = nil
                workspace.session?.runningUptime = nil
                if !resumeProtected {
                    offerLoadedSession(reason: "quedó a medias al cerrarse FocusDesk")
                }
            }
        } catch {
            writable = false
            corruptFileDetected = true
            self.error = "No se han podido leer tus datos. Se han conservado intactos en \(store.url.path). Puedes recuperar la última copia automática o importar un respaldo desde el aviso o Ajustes. (\(error.localizedDescription))"
        }
        hasInitialBaseline = workspace.session?.baselineValid ?? false
        TextScale.factor = CGFloat(workspace.settings.textScale)
        // "Tienda" used the exact mint of the accent and the running session: same colour, two meanings.
        let retired = CategoryItem.retiredTiendaColor
        if let index = workspace.settings.categories.firstIndex(where: {
            $0.name == "Tienda" && abs($0.red - retired.red) < 0.001 && abs($0.green - retired.green) < 0.001 && abs($0.blue - retired.blue) < 0.001
        }), let tienda = CategoryItem.defaults.first(where: { $0.name == "Tienda" }) {
            workspace.settings.categories[index] = tienda
        }
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
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.offerResumeAfterSystemPause(reason: "mientras se usaba otra cuenta del Mac") }
        })
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
        // No molestar follows the sessions that block apps: on while one runs, off when it pauses or ends. Also on
        // launch, so one left on by a crash is turned off.
        if !preview {
            Task { await focusMode.refresh() }
            $workspace
                .map { workspace in
                    workspace.settings.focusDuringStrict &&
                    workspace.session.map { $0.task.strict && !$0.paused && $0.endedAt == nil } == true
                }
                .removeDuplicates()
                .sink { [weak self] wanted in self?.applyDoNotDisturb(wanted) }
                .store(in: &subscriptions)
        }
        // A session or general rule that blocks things has to stay awake: napped by macOS, its checks ran late or not at all.
        $workspace
            .map { workspace in
                workspace.session.map { !$0.paused && $0.endedAt == nil && $0.task.enforces } == true
                    || workspace.generalRules.contains(where: \.enabled)
            }
            .removeDuplicates()
            .sink { [weak self] active in self?.keepAwakeForSession(active) }
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
                // Back from Atajos after adding the No molestar shortcuts.
                if self?.preview == false, self?.focusMode.ready != true { Task { await self?.focusMode.refresh() } }
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
        // A protected session lost to a force-quit, a crash or a restart comes back by itself. Coming back paused
        // was a free way out: force-quit, reopen, and the block was gone.
        if resumeProtected, writable, let s = workspace.session {
            resume()
            notice = "«\(s.task.title)» está protegida y FocusDesk se cerró sin que la pararas: sigue donde estaba. \(s.task.protection.wayOut)"
        }
        // A protected session the data file no longer knows about: the file was edited while FocusDesk was closed.
        checkWitnessAtLaunch()
        refreshWitness()
        if workspace.generalRules.contains(where: { $0.enabled && $0.alwaysProtected && $0.protection != .none }) {
            workspace.settings.relaunchGuard = true
        }
        relaunchGuard.refresh(repair: !preview)
        // The setting said «on» with nothing installed: a mandatory rule that nobody would bring back after a force-quit.
        if RelaunchGuardPlan.shouldInstall(
            settingOn: workspace.settings.relaunchGuard,
            fileExists: relaunchGuard.installed,
            runningInstalledApp: relaunchGuard.runningInstalledApp,
            demo: preview
        ) {
            relaunchGuard.install()
            let outcome = relaunchGuard.installed
                ? "El vigilante estaba activado en Ajustes pero no instalado: ya lo está. Si FocusDesk se cierra a la fuerza con algo protegido, vuelve a abrirse."
                : relaunchGuard.message
            notice = [notice, outcome].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// A session read from disk (at launch, or in a restored or recovered copy) never runs on its own. The design
    /// promises to offer it back: a notice vanished after 7 s — often before the window was even looked at when
    /// FocusDesk opens at login — leaving only "Pausa" in the menu bar. One waiting for its result gets the
    /// confirmation back.
    private func offerLoadedSession(reason: String) {
        guard let recovered = workspace.session else { return }
        if recovered.endedAt == nil {
            let remaining = FocusRules.clock(max(0, recovered.remaining(at: Date())))
            resumePrompt = "«\(recovered.task.title)» \(reason). Te quedan \(remaining). ¿Reanudamos?"
            pausedBySystem = true
        } else {
            changedFiles = recovered.finalChangedFiles ?? []
            selectedDeliverables = Set(recovered.selectedFiles)
            manualAttachments = recovered.manualFiles
            evidenceMessage = recovered.finalEvidenceMessage ?? (recovered.finalChangedFiles == nil ? "La revisión de archivos no llegó a guardarse. Confirma el resultado manualmente." : nil)
            showCompletion = true
        }
    }

    /// After the whole workspace is replaced by a restored or recovered copy: its text size, its session and its
    /// Calendar queue apply, and nothing from the replaced agenda (undo steps, selection, a queued start) lingers.
    private func adoptReplacedWorkspace(reason: String) {
        TextScale.factor = CGFloat(workspace.settings.textScale)
        calendar.pendingCount = workspace.pendingCalendarOps.count
        hasInitialBaseline = workspace.session?.baselineValid ?? false
        undoManager.removeAllActions()
        selectedTaskID = nil
        queuedStartTaskID = nil
        handoffRequest = nil
        resumePrompt = nil
        promptApps = []
        pausedBySystem = false
        showCompletion = false
        changedFiles = []
        writingFiles = []
        selectedDeliverables = []
        manualAttachments = []
        evidenceMessage = nil
        offerLoadedSession(reason: reason)
    }

    var session: WorkSession? { workspace.session }

    /// A protected session is defending itself right now: the settings and data that could end it stay as they are.
    var protectedSessionRunning: Bool {
        if let s = session, s.task.protection != .none, s.enforcing(at: Date(), uptime: uptime) {
            return true
        }
        return activeProtectedGeneralRule != nil
    }

    var activeProtectedGeneralRule: GeneralBlockRule? {
        let instant = Date()
        return workspace.generalRules.first { rule in
            isRuleProtected(rule, at: instant)
        }
    }

    /// Says no, with the reason, when `action` would weaken a protected session or active general block rule. Returns true when it refused.
    func refuseWhileProtected(_ action: String) -> Bool {
        if let s = session, s.task.protection != .none, s.enforcing(at: Date(), uptime: uptime) {
            notice = "No se puede \(action) mientras «\(s.task.title)» está protegida. \(s.task.protection.wayOut)"
            return true
        }
        if let rule = activeProtectedGeneralRule {
            notice = "No se puede \(action) mientras la regla «\(rule.name)» está activa y protegida (\(rule.protection.label))."
            return true
        }
        return false
    }

    /// The run-up margin can always grow. Shrinking it while a task is already inside it would be the cheapest way
    /// out of that very task (set it to «No», then delete it), so that waits until the task has started or ended.
    func setRunUpMinutes(_ minutes: Int) {
        let value = RunUp.clampedMinutes(minutes)
        if value < workspace.settings.runUpMinutes,
           let armed = workspace.tasks.first(where: { protectedBeforeStart($0) }) {
            notice = "«\(armed.title)» ya está protegida porque está a punto de empezar: el margen se puede acortar cuando empiece o acabe su hora."
            return
        }
        updateSettings { $0.runUpMinutes = value }
    }

    /// Settings that make the block see more: turning one on is always fine, turning it off waits for the session.
    func updateBlockingSetting(turningOn: Bool, _ mutate: (inout Settings) -> Void) {
        if !turningOn, refuseWhileProtected("apagar esta vigilancia") { return }
        updateSettings(mutate)
    }

    private func keepAwakeForSession(_ active: Bool) {
        if active, napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Una sesión de FocusDesk está bloqueando distracciones"
            )
        } else if !active, let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }
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

    /// The Pomodoro phase of the running session, when its task is done in Pomodoro.
    func pomodoroPhase(for s: WorkSession, at instant: Date? = nil) -> TaskPomodoroPhase? {
        guard s.endedAt == nil else { return nil }
        return s.task.pomodoroPhase(elapsed: s.elapsed(at: instant ?? now, uptime: uptime))
    }

    /// Whether the running session still has time on the clock (the views ask before offering a way out).
    var currentRemainingIsPositive: Bool {
        guard let s = session else { return false }
        return currentRemaining(for: s) > 0
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
            // The Keychain copy follows every save, so deleting the file does not quietly end a protected session.
            refreshWitness()
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
        TextScale.factor = CGFloat(workspace.settings.textScale)
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

    /// `checkRunUp` is false when the caller (move, snooze, inbox) already asked the run-up gate for this change.
    func saveTask(_ input: FocusTask, detachFromSeriesID: UUID? = nil, occurrenceDate: Date? = nil, checkRunUp: Bool = true) {
        guard writable, !busy, input.valid else { return }
        // The task that is running can be edited, but only in the direction that makes it harder: the ratchet.
        if let running = session, running.task.id == input.id {
            applyRatchetedEdit(input, to: running)
            return
        }
        if checkRunUp, !passesRunUpGate(.save(input, detachFromSeriesID: detachFromSeriesID, occurrenceDate: occurrenceDate)) {
            return
        }
        var task = input
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.domains = FocusRules.normalizeDomains(task.domains)

        if let seriesID = detachFromSeriesID, let occDate = occurrenceDate,
           let sIdx = workspace.tasks.firstIndex(where: { $0.id == seriesID })
               ?? seriesHead(seriesID).flatMap({ head in workspace.tasks.firstIndex(where: { $0.id == head.id }) }) {
            let (updatedSeries, _) = workspace.tasks[sIdx].detachOccurrence(at: occDate, workdays: workspace.settings.workdays)
            workspace.tasks[sIdx] = updatedSeries
            enqueueProjectionForTask(updatedSeries)
            task.id = UUID()
            task.repeatRule = .never
            task.repeatDays = []
            task.skippedDates = []
            task.seriesID = updatedSeries.seriesID ?? updatedSeries.id
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
        guard writable, !busy, task.id != session?.task.id, passesRunUpGate(.delete(task)) else { return }
        let before = workspace.tasks
        defer {
            if error == nil, before.count != workspace.tasks.count {
                rememberUndo("Borrar «\(task.title)»", before: before)
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

    /// Returns the id of the task that moved: a detached copy when `task` was a series occurrence.
    @discardableResult
    func shift(_ task: FocusTask, to date: Date, durationMinutes: Int? = nil) -> UUID? {
        guard writable, !busy, task.id != session?.task.id,
              passesRunUpGate(.shift(task, to: date, minutes: durationMinutes)) else { return nil }
        let before = workspace.tasks
        let detached = isSeriesHead(task)
        var updated = occurrenceForDirectEdit(task)
        updated.scheduledAt = date
        updated.isScheduled = true
        if let durationMinutes {
            updated.minutes = FocusRules.clampedMinutes(durationMinutes)
        }
        saveTask(updated, checkRunUp: false)
        guard error == nil else { return nil }
        let when = updated.scheduledAt.formatted(date: Calendar.current.isDateInToday(updated.scheduledAt) ? .omitted : .abbreviated, time: .shortened)
        let what = durationMinutes != nil && Calendar.current.isDate(updated.scheduledAt, equalTo: task.scheduledAt, toGranularity: .minute)
            ? "«\(updated.title)» ahora dura \(updated.minutes) min."
            : "«\(updated.title)» movida a \(when)."
        notice = detached ? what + " Solo esta ocurrencia; la serie sigue a su hora." : what
        rememberUndo("Mover «\(updated.title)»", before: before)
        if selectedTaskID == task.id { selectedTaskID = updated.id }
        return updated.id
    }

    // MARK: Keyboard selection

    /// Task picked with the keyboard (or a click) on Hoy; the Tarea menu and the agenda keys act on it.
    @Published var selectedTaskID: UUID?
    /// Task waiting for the delete confirmation, from a row, the keyboard or the Tarea menu.
    @Published var taskPendingDeletion: FocusTask?

    /// Tasks reachable with ↑↓ on Hoy, in on-screen order: slipped from earlier days, the day's agenda, the inbox.
    var keyboardTasks: [FocusTask] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let overdue = scheduledTasks.filter { $0.scheduledAt < startOfToday && !calendar.isDate($0.scheduledAt, inSameDayAs: selectedDate) }
        let day = tasksForDay(selectedDate).real.filter { !$0.completed }
        return overdue + day + unscheduledTasks
    }

    var selectedTask: FocusTask? {
        guard let id = selectedTaskID else { return nil }
        return workspace.tasks.first { $0.id == id }
    }

    /// Whether the selected task can be edited, started, moved or deleted right now.
    var selectedTaskIsActionable: Bool {
        guard let task = selectedTask else { return false }
        return !task.completed && task.id != session?.task.id && writable && !busy
    }

    func moveSelection(by step: Int) {
        let list = keyboardTasks
        guard !list.isEmpty else { selectedTaskID = nil; return }
        if let id = selectedTaskID, let index = list.firstIndex(where: { $0.id == id }) {
            selectedTaskID = list[max(0, min(list.count - 1, index + step))].id
        } else {
            selectedTaskID = (step >= 0 ? list.first : list.last)?.id
        }
    }

    func nudgeSelected(minutes delta: Int) {
        guard selectedTaskIsActionable, let task = selectedTask, task.isScheduled else { return }
        shift(task, to: task.scheduledAt.addingTimeInterval(Double(delta) * 60))
    }

    func resizeSelected(by delta: Int) {
        guard selectedTaskIsActionable, let task = selectedTask, task.isScheduled else { return }
        shift(task, to: task.scheduledAt, durationMinutes: task.minutes + delta)
    }

    private func rememberUndo(_ label: String, before: [FocusTask]) {
        let after = workspace.tasks
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            model.applyAgendaState(before, expecting: after, label: label)
        }
        undoManager.setActionName(label)
        undoManager.endUndoGrouping()
        objectWillChange.send()
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

    var canUndoAgenda: Bool { undoManager.canUndo }

    func undoAgendaChange() {
        guard undoManager.groupingLevel == 0, undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redoAgendaChange() {
        guard undoManager.groupingLevel == 0, undoManager.canRedo else { return }
        undoManager.redo()
    }

    /// Puts the agenda back to `target` if nothing else changed it since `expected`, and registers the opposite step
    /// so Rehacer works too.
    private func applyAgendaState(_ target: [FocusTask], expecting expected: [FocusTask], label: String) {
        guard writable, !busy else { return }
        guard Self.agendaSignature(expected) == Self.agendaSignature(workspace.tasks) else {
            // Something else changed the agenda in between: refusing is safer than reverting that too.
            DispatchQueue.main.async { [weak self] in self?.undoManager.removeAllActions(withTarget: self as Any) }
            notice = "Ya no se puede deshacer: la agenda cambió después."
            return
        }
        let undoing = undoManager.isUndoing
        let current = workspace.tasks
        let reference = Date()
        // Keep what Calendar knows now: a restored task must not point at an event that was already removed.
        var restored = target.map { task -> FocusTask in
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
        let applied = workspace.tasks
        undoManager.registerUndo(withTarget: self) { model in
            model.applyAgendaState(current, expecting: applied, label: label)
        }
        undoManager.setActionName(label)
        _ = persist()
        schedule()
        syncCalendar()
        notice = undoing ? "Deshecho: \(label)." : "Rehecho: \(label)."
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
        scheduleInFirstFreeSlot(task, on: Date())
    }

    func moveToTomorrowSameTime(_ task: FocusTask) {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: task.isScheduled ? task.scheduledAt : Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())),
              let target = calendar.date(bySettingHour: time.hour ?? workspace.settings.workStartHour, minute: time.minute ?? 0, second: 0, of: tomorrow) else { return }
        shift(task, to: target)
    }

    /// Worked session time on `day`: confirmed and cancelled sessions plus the one running now (and passive verified study time when enabled).
    func workedSeconds(on day: Date, calendar: Calendar = .current) -> TimeInterval {
        var total = workspace.history
            .filter { calendar.isDate($0.session.startedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.session.accumulated }
        // The current session is not in the history yet (running, paused or waiting for its result).
        if let s = session, calendar.isDate(s.startedAt, inSameDayAs: day) {
            total += s.endedAt == nil ? currentElapsed(for: s) : s.accumulated
        }
        if workspace.generalRules.contains(where: { $0.enabled && $0.verifyActiveStudy }) {
            let verified = workspace.verifiedStudySecondsToday(at: day, calendar: calendar)
            return max(total, verified)
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
        guard let seriesID = draft.seriesID, let head = seriesHead(seriesID) else {
            return .notInSeries
        }
        return stored == nil ? .projected(seriesID: head.id) : .detached(seriesID: head.id)
    }

    /// The live head of the series `key` belongs to. Completing an occurrence creates a new head task with a new id,
    /// so occurrences find their series by its key (`seriesID ?? id`), not by the id of the head they came from.
    func seriesHead(_ key: UUID) -> FocusTask? {
        workspace.tasks.first { $0.repeatRule != .never && !$0.completed && ($0.id == key || $0.seriesID == key) }
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
        head.autoStart = draft.autoStart
        head.protection = draft.protection
        head.unlockChars = draft.unlockChars
        head.stopDelayMinutes = draft.stopDelayMinutes
        head.blockAction = draft.blockAction
        head.webBlockAction = draft.webBlockAction
        head.guardSystemPanes = draft.guardSystemPanes
        head.punisherEnabled = draft.punisherEnabled
        head.blockedFolders = draft.blockedFolders
        head.appListMode = draft.appListMode
        head.webListMode = draft.webListMode
        head.blockedTitleKeywords = draft.blockedTitleKeywords
        head.wholeWordKeywords = draft.wholeWordKeywords
        head.customRedirectURL = draft.customRedirectURL
        head.motivationalMessage = draft.motivationalMessage
        head.blockSearchMedia = draft.blockSearchMedia
        head.blockGameLibraries = draft.blockGameLibraries
        head.similarityProtection = draft.similarityProtection
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

    /// Schedules an inbox task on `date` in its first free slot: after that day's tasks and breaks, never in the past.
    func scheduleInFirstFreeSlot(_ task: FocusTask, on date: Date) {
        let slot = FocusRules.firstFreeSlot(
            on: date,
            tasks: workspace.tasks.filter { $0.id != task.id },
            breaks: workspace.settings.breaks,
            workStartHour: workspace.settings.workStartHour,
            now: Date()
        )
        shift(task, to: slot)
    }

    func snoozeTask(_ task: FocusTask, minutes: Int = 10) {
        guard writable, !busy, task.id != session?.task.id, passesRunUpGate(.snooze(task, minutes: minutes)) else { return }
        let before = workspace.tasks
        defer { if error == nil { rememberUndo("Posponer «\(task.title)»", before: before) } }
        let detached = isSeriesHead(task)
        let updated = occurrenceForDirectEdit(task).snoozed(minutes: minutes, now: Date())
        reminders.removeDelivered(forTaskID: task.id)
        saveTask(updated, checkRunUp: false)
        if error == nil {
            let time = updated.scheduledAt.formatted(date: .omitted, time: .shortened)
            notice = detached
                ? "«\(updated.title)» pospuesta a las \(time), solo esta vez. La serie sigue a su hora."
                : "«\(updated.title)» pospuesta a las \(time)."
        }
    }

    /// Sends one task to the inbox. For a series that means this occurrence only; the series keeps its schedule.
    func moveToInbox(_ task: FocusTask) {
        guard writable, !busy, task.id != session?.task.id, passesRunUpGate(.inbox(task)) else { return }
        let before = workspace.tasks
        let detached = isSeriesHead(task)
        var unscheduled = occurrenceForDirectEdit(task)
        unscheduled.isScheduled = false
        saveTask(unscheduled, checkRunUp: false)
        guard error == nil else { return }
        notice = detached
            ? "Esta ocurrencia de «\(unscheduled.title)» pasa a la bandeja. La serie sigue programada."
            : "«\(unscheduled.title)» pasa a la bandeja sin hora."
        rememberUndo("Pasar a la bandeja «\(unscheduled.title)»", before: before)
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
            let seriesKey = task.seriesID ?? task.id
            for occ in occurrences where !real.contains(where: { $0.id != task.id && $0.seriesID == seriesKey && calendar.isDate($0.scheduledAt, inSameDayAs: occ.scheduledAt) }) {
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
            strictTracker = StrictRedirectTracker(); strictLaunchAttempts = 0
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
        finish()
        if session?.endedAt != nil {
            notice = "«\(current.task.title)» se ha detenido. Confirma su resultado y «\(task.title)» empezará."
        } else if pendingStop == nil, session?.stopRequest == nil {
            // Refused outright («hasta el final»): nothing stopped, so nothing is waiting to start either.
            queuedStartTaskID = nil
        }
        // With a code on screen or a wait running, the new task stays queued until the stop goes through.
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

    /// Pausing is one of the three ways out of a session; a protected one asks for the code or the wait first.
    func pause() {
        guard writable, let s = workspace.session, s.endedAt == nil else { return }
        guard passesStopGate(.pause, session: s) else { return }
        performPause()
    }

    /// Pauses without asking anything. Used by the Mac (sleep, lock, user switch) and by the strict-mode safety
    /// valve: those are not the user trying to escape, and blocking them would trap the session.
    func performPause() {
        guard writable, workspace.session != nil, workspace.session?.endedAt == nil else { return }
        pausedBySystem = false
        pausedByLockOrSleep = false
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
        pausedByLockOrSleep = false
        resumePrompt = nil
        promptApps = []
        if let s = workspace.session { reminders.removeDelivered(identifiers: ["paused-" + s.id.uuidString]) }
        now = Date()
        workspace.session?.resume(at: now, uptime: uptime)
        strictTracker = StrictRedirectTracker(); strictLaunchAttempts = 0
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
        // Requires a running session: with none it used to rewrite the file and sync Calendar for nothing.
        guard writable, let s = workspace.session, s.endedAt == nil else { return }
        workspace.session?.add(minutes: minutes)
        overtimeNotified = false
        if let s = workspace.session {
            enqueueProjectionForTask(s.task, session: s, now: Date())
        }
        _ = persist()
        syncCalendar()
    }

    @objc func screenLocked() {
        screenIsLocked = true
        pauseForSystem()
    }

    @objc func screenUnlocked() {
        screenIsLocked = false
        now = Date()
        offerResumeAfterSystemPause(reason: "mientras el Mac estaba bloqueado")
    }

    func pauseForSystem() {
        guard let s = session, !s.paused, s.endedAt == nil else { return }
        // The Mac went to sleep or locked: not an escape attempt, so no code and no wait.
        performPause()
        pausedBySystem = true
        pausedByLockOrSleep = true
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
        // A protected session does not ask: the question was a free way out (lock the screen, unlock, say no).
        // The locked time still does not count; the session simply carries on once the Mac is back.
        if pausedByLockOrSleep, s.task.protection != .none, s.remaining(at: Date(), uptime: uptime) > 0 {
            // Woken up behind the lock screen: unlocking is what brings it back.
            guard !screenIsLocked else { return }
            resume()
            notice = "«\(s.task.title)» sigue donde estaba: se pausó \(reason) y ese rato no cuenta."
            return
        }
        let remaining = FocusRules.clock(max(0, s.remaining(at: now, uptime: uptime)))
        resumePrompt = "«\(s.task.title)» se pausó \(reason). Te quedan \(remaining). ¿Reanudamos?"
        if !preview {
            reminders.notify(
                "Sesión en pausa · \(s.task.title)",
                body: "Se pausó \(reason). Te quedan \(remaining). Reanuda cuando estés listo.",
                category: ReminderService.pausedCategory,
                userInfo: ["taskID": s.task.id.uuidString],
                // One per session: waking and then unlocking replace it instead of stacking two, and resuming or
                // finishing retires it (`clearSessionNotifications`).
                identifier: "paused-" + s.id.uuidString
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
        guard let url = Self.installedURL(of: app) else {
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
        strictTracker = StrictRedirectTracker(); strictLaunchAttempts = 0
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
        // Finishing once the time is up is never protected; finishing early is the third way out.
        guard passesStopGate(.finishEarly, session: s) else { return }
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
        // Never the task just worked on: after «Sigue pendiente» it is still pending and usually still the most
        // imminent, so «Empezar la siguiente» used to start it all over again.
        let candidateNext = queued ?? FocusRules.nextSuggestedTask(tasks: workspace.tasks, sessionTaskID: s.task.id, now: confirmInstant)
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
        guard s.endedAt != nil || passesStopGate(.cancel, session: s) else { return }
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

    func enqueueProjectionForTask(_ inputTask: FocusTask, session: WorkSession? = nil, now: Date = Date(), force: Bool = false) {
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

    /// The visible clock only needs to tick every second when something shows it changing: a session, an imminent
    /// task's countdown, an active general timer/quota, an active break, or a FocusDesk window on screen.
    private func needsLiveClock(at instant: Date) -> Bool {
        if session != nil { return true }
        if isInterfaceVisible?() ?? true { return true }
        if workspace.generalRules.contains(where: {
            $0.enabled && ($0.kind == .countdown || $0.kind == .dailyLimit || $0.kind == .workGoal || $0.kind == .launchLimit || $0.kind == .pomodoro || $0.isMicroPaused(at: instant))
        }) {
            return true
        }
        if !workspace.temporaryAllows.isEmpty { return true }
        if activeBreak(at: instant) != nil || activeContinuousBreak(at: instant) != nil { return true }
        return workspace.tasks.contains { task in
            !task.completed && task.isScheduled && task.scheduledAt > instant &&
            task.scheduledAt.timeIntervalSince(instant) <= Double(max(task.leadMinutes, 1)) * 60
        }
    }

    private func tick() {
        let instant = Date()
        ticks += 1
        if needsLiveClock(at: instant) || ticks.isMultiple(of: 30) { now = instant }
        let today = Calendar.current.startOfDay(for: instant)
        if today != lastPrunedDay {
            now = instant
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
        checkStopRequestReady()
        checkRunUpWaitsReady()
        checkGeneralRuleWaitsReady()
        tickContinuousBreak(at: instant)
        tickPomodoroRules(at: instant)
        tickPassiveStudyTracking(at: instant)
        tickLeagueMatchAndPostMatchGrace(at: instant)
        tickTaskPomodoro(at: instant)
        updateFloatingPill(at: instant)
        if ticks.isMultiple(of: 5) {
            accessible = MacActivity.accessibility
            observe()
            checkClipboardGuard()
            // Windows on screen without the focus, and pages inside Electron apps: both have their own interval.
            sweepBackgroundWindows()
            scanEmbeddedPages()
        }
        if ticks.isMultiple(of: 10) {
            checkClockDrift()
            refreshWitness()
            // The permission can look granted and not work; a block that cannot act must not pretend otherwise.
            if (session?.task.strict == true || !enforcingGeneralRules.isEmpty), accessible {
                accessibilityBroken = !AccessibilityProbe.actuallyGranted()
            } else {
                accessibilityBroken = false
            }
        }
        // Replenish reminder queue when earlier reminders are consumed in a busy day (>60 reminders)
        // Only with permission: without it nothing gets scheduled, so the check always failed and rescheduled
        // everything every 10 s for nothing.
        if ticks.isMultiple(of: 10), !preview, [.authorized, .provisional].contains(reminders.status),
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
            } else if workspace.generalRules.contains(where: { $0.enabled && ($0.kind == .dailyLimit || $0.kind == .workGoal || $0.kind == .launchLimit) }) {
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

    /// Per-task auto-start from the design: only on an unlocked Mac, while the task's scheduled window `[scheduledAt, end)`
    /// is active, and never on top of another session.
    private func startDueAutoStartTasks() {
        guard writable, !busy, !screenIsLocked else { return }
        let reference = Date()
        // Keyed by task and time, so a task snoozed to a new time starts on its own again at that time.
        func key(_ task: FocusTask) -> String { "\(task.id.uuidString)@\(Int(task.scheduledAt.timeIntervalSinceReferenceDate))" }
        // Not the task already running: started by hand a few minutes early, it got «no ha empezado sola» at its time.
        guard let due = workspace.tasks.first(where: {
            $0.autoStart && !$0.completed && $0.isScheduled && $0.id != session?.task.id && !autoStartHandled.contains(key($0)) &&
            $0.scheduledAt <= reference && reference < $0.end
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
        start(due)
        if !preview {
            reminders.notify("Empezada a su hora · \(due.title)", body: "Tienes \(due.minutes) minutos. Puedes pausarla con ⌃⌥⌘P.")
        }
    }

    func observe() {
        guard writable, !screenIsLocked else {
            lastGeneralQuotaAt = nil
            return
        }
        let activeSession: WorkSession? = {
            guard let s = session, !s.paused, s.endedAt == nil else { return nil }
            // A Pomodoro break is a real break: nothing of the task is blocked until the next focus block.
            if pomodoroPhase(for: s, at: Date())?.isBreak == true { return nil }
            return s
        }()
        let hasEnabledRules = workspace.generalRules.contains(where: \.enabled)
        guard activeSession != nil || hasEnabledRules else {
            lastGeneralQuotaAt = nil
            return
        }
        let excludedIDs = Set(workspace.settings.excludedTitleApps.map(\.id))
        let needsTitles = workspace.settings.observeTitles
            || (activeSession.map { !FocusRules.parseTitleKeywords($0.task.blockedTitleKeywords).isEmpty } ?? false)
            || workspace.generalRules.contains { $0.enabled && ($0.verifyActiveStudy || !FocusRules.parseTitleKeywords($0.blockedTitleKeywords).isEmpty) }
        // Window titles are read through Accessibility on the main thread (up to 0.15 s each): on a change of app,
        // or every 15 s for the same app, instead of every 5 s.
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let refreshTitle = needsTitles && (frontID != lastTitleAppID || Date().timeIntervalSince(lastTitleReadAt) >= 15)
        guard var fg = MacActivity.foreground(readTitle: refreshTitle, excludedAppIDs: excludedIDs),
               let id = fg.app.bundleIdentifier else { return }
        if needsTitles {
            if refreshTitle {
                lastTitleAppID = id
                lastTitleReadAt = Date()
                lastTitle = (fg.title, fg.titleStatus)
            } else {
                fg = Foreground(app: fg.app, title: lastTitle.title, titleStatus: lastTitle.status)
            }
        }
        let appChanged = id != lastObservedAppID
        lastObservedAppID = id
        var sessionReadBrowser = false

        if let s = activeSession {
            // System Settings is exempt as a distraction — you may need the Wi-Fi mid-session — but two of its panes
            // are the way out of the block, so they are checked before the exemption applies.
            if SystemSettingsGuard.bundleIDs.contains(id) {
                guardSystemSettingsIfNeeded(bundleID: id, pid: fg.app.processIdentifier, session: s)
            }
            // The Finder is exempt too — you may need your files — but not the folders this task closes.
            if !s.task.blockedFolders.isEmpty {
                guardBlockedFolders(frontBundleID: id, frontApp: fg.app, session: s)
            }
            var exemptions = FocusRules.systemExemptBundleIDs
            if let ownID = Bundle.main.bundleIdentifier { exemptions.insert(ownID) }
            if !exemptions.contains(id) {
                // A Chromium "web app" is a real app with its own icon wrapping a single site: judge it by that site,
                // so installing a blocked page as an app is not a way around the rules.
                let webAppHost = workspace.settings.inspectEmbeddedPages && WebRules.looksLikeChromiumWebApp(bundleID: id)
                    ? AppInspector.chromiumWebAppHost(for: fg.app)
                    : nil
                let at = Date()
                let isTempAllowedApp = workspace.isTemporarilyAllowed(bundleID: id, at: at)
                    || (webAppHost.map { workspace.isTemporarilyAllowed(host: $0, at: at) } ?? false)
                let matchedGameLibrary = (!isTempAllowedApp && s.task.blockGameLibraries)
                    ? GameLibraryRules.matchesGameApp(bundleID: id, appPath: fg.app.bundleURL?.path)
                    : nil
                var allowed = isTempAllowedApp || (matchedGameLibrary == nil && (s.task.apps.isEmpty || FocusRules.appAllowed(bundleID: id, apps: s.task.apps, mode: s.task.appListMode)))
                if !isTempAllowedApp, allowed, let webAppHost, s.task.webBlockAction != .warn,
                   !FocusRules.webAllowed(host: webAppHost, path: "", list: s.task.domains, mode: s.task.webListMode) {
                    allowed = false
                }
                let matchedTitleKeyword = isTempAllowedApp ? nil : FocusRules.matchesTitleKeyword(
                    fg.title,
                    keywords: s.task.blockedTitleKeywords,
                    wholeWord: s.task.wholeWordKeywords
                )
                if matchedTitleKeyword != nil {
                    allowed = false
                }
                let currentUptime = uptime

                if allowed {
                    lastAllowed = fg.app
                    strictTracker.registerAllowedAppObserved()
                    strictLaunchAttempts = 0
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

                if allowed, !WebRules.isBrowser(id) { domainEpisodeHost = nil }
                // A browser, or a site saved as an app from Safari, whose address cannot be read: websites are not blocked
                // there, and a task that blocks them says so once instead of pretending.
                if allowed, (s.task.webBlockAction != .warn || s.task.blockSearchMedia),
                   WebRules.unreadableBrowsers.contains(id) || WebRules.looksLikeSafariWebApp(bundleID: id),
                   !warnedUnreadableBrowsers.contains(id) {
                    warnedUnreadableBrowsers.insert(id)
                    notice = "\(fg.app.localizedName ?? id) no deja leer qué web tiene abierta: en ella FocusDesk no puede bloquear webs. Para esta tarea usa Safari, Chrome, Brave, Edge o Arc."
                }

                if isNewInterruption {
                    if let kw = matchedTitleKeyword {
                        notice = "La ventana de \(fg.app.localizedName ?? id) contiene «\(kw)», que está bloqueada en esta tarea."
                    } else if let gameLib = matchedGameLibrary {
                        notice = "\(fg.app.localizedName ?? id) pertenece a la biblioteca de juegos (\(gameLib)), bloqueada en esta tarea."
                    } else {
                        notice = webAppHost.map { "\(fg.app.localizedName ?? id) abre \($0), que no entra en esta tarea." }
                            ?? "\(fg.app.localizedName ?? id) está fuera del perfil de esta tarea."
                    }
                    if !s.task.strict && matchedTitleKeyword == nil && matchedGameLibrary == nil && !preview { notifyDistraction(notice ?? "", session: s) }
                }

                if let kw = matchedTitleKeyword {
                    fg.app.hide()
                    workspace.session?.registerBlock()
                    notice = "«\(kw)» está bloqueada por título de ventana en «\(s.task.title)»: he ocultado \(fg.app.localizedName ?? id)."
                    return
                }
                if let gameLib = matchedGameLibrary, !s.task.strict {
                    fg.app.hide()
                    workspace.session?.registerBlock()
                    notice = "\(fg.app.localizedName ?? id) (\(gameLib)) está bloqueada por la protección de juegos en «\(s.task.title)»: la he ocultado."
                    return
                }

                if !allowed && s.task.strict {
                    guard enforceApp(fg.app, bundleID: id, session: s, isNewInterruption: isNewInterruption, at: at) else { return }
                }
                // A site saved as a Chromium app is that site. With websites blocked it is hidden even when the task does
                // not block apps, or installing YouTube as an app walked past a block that only looked at browser tabs.
                if !s.task.strict, s.task.webBlockAction != .warn, let webAppHost,
                   !FocusRules.webAllowed(host: webAppHost, path: "", list: s.task.domains, mode: s.task.webListMode) {
                    fg.app.hide()
                    workspace.session?.registerBlock()
                    notice = "\(fg.app.localizedName ?? id) abre \(webAppHost), que no entra en esta tarea: la he ocultado."
                    return
                }

                // The address bar of any browser FocusDesk knows, not just Brave: one `osascript` per browser, on switching
                // to it and then every 15 s — every 5 s when the task blocks websites, so a blocked page opened without
                // leaving the browser (or reached again with Back) does not stay up for long.
                let webReadInterval: TimeInterval = (s.task.webBlockAction != .warn || s.task.blockSearchMedia) ? 5 : 15
                if WebRules.isBrowser(id), workspace.settings.observeBrave || s.task.webBlockAction != .warn || s.task.blockSearchMedia,
                   appChanged || Date().timeIntervalSince(lastWebReadAt[id] ?? .distantPast) >= webReadInterval - 0.5 {
                    lastWebReadAt[id] = Date()
                    sessionReadBrowser = true
                    inspectBrowser(bundleID: id, session: s)
                }
            }
        }

        if hasEnabledRules {
            observeGeneralRules(
                fg: fg,
                bundleID: id,
                appChanged: appChanged,
                sessionAlreadyReadBrowser: sessionReadBrowser,
                at: Date()
            )
        }
    }

    private func applyDoNotDisturb(_ wanted: Bool) {
        guard wanted else { focusMode.turnOffIfOurs(); return }
        if focusMode.ready == false, !warnedMissingFocusShortcuts {
            warnedMissingFocusShortcuts = true
            notice = "Para que esta tarea ponga No molestar sola, crea sus dos atajos en Ajustes › General."
            return
        }
        focusMode.turnOn()
    }

    /// Where an allowed app lives on this Mac, by bundle id first (it may have moved) and then by its saved path.
    static func installedURL(of app: AllowedApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)
            ?? (FileManager.default.fileExists(atPath: app.path) ? URL(fileURLWithPath: app.path) : nil)
    }

    /// Looks at the front app again shortly: an app that grabs the focus back right after being hidden is caught
    /// then, not up to five seconds later on the next tick.
    func scheduleStrictRecheck(after delay: TimeInterval) {
        strictRecheck?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.observe() }
        }
        strictRecheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: item)
    }

    /// "Vuelve a tu tarea" replaces the previous one instead of piling up, and sounds at most every 3 minutes.
    func notifyDistraction(_ body: String, session s: WorkSession) {
        guard Date().timeIntervalSince(lastDistractionNotifyAt) >= 180 else { return }
        lastDistractionNotifyAt = Date()
        reminders.notify("Vuelve a tu tarea", body: body, identifier: "distraction-" + s.id.uuidString)
    }

    func clearSessionNotifications(_ s: WorkSession) {
        reminders.removeDelivered(identifiers: ["distraction-", "overtime-", "paused-"].map { $0 + s.id.uuidString })
    }

    func deleteHistoryRecord(_ id: UUID) {
        guard writable else { return }
        if workspace.settings.protectActivityHistory && refuseWhileProtected("borrar el historial de actividad") { return }
        workspace.history.removeAll { $0.id == id }
        _ = persist()
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusDesk-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WorkspaceStore(url: url).save(workspace, rollingBackup: false)
            notice = "Copia exportada correctamente en \(url.lastPathComponent)."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func recoverFromAutoBackup() {
        // A copy brings its session back paused: during a protected session that was a one-click way out.
        guard !refuseWhileProtected("recuperar una copia") else { return }
        do {
            let recovered = try store.recoverFromRollingBackup(at: Date())
            workspace = recovered
            writable = true
            hasUnsavedChanges = false
            corruptFileDetected = false
            error = nil
            adoptReplacedWorkspace(reason: "estaba en marcha en la copia recuperada")
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
            adoptReplacedWorkspace(reason: "")
            notice = "Agenda reiniciada. El archivo dañado original se ha conservado en \(savedCorrupt?.lastPathComponent ?? "backups")."
        } catch {
            self.error = "No se pudo reiniciar el archivo: \(error.localizedDescription)"
        }
    }

    func restoreBackup(from fileURL: URL) throws {
        guard !refuseWhileProtected("restaurar una copia") else { return }
        let imported = try store.validateBackup(at: fileURL)
        let (restored, prevURL) = try store.restore(imported, at: Date())
        workspace = restored
        writable = true
        hasUnsavedChanges = false
        corruptFileDetected = false
        error = nil
        adoptReplacedWorkspace(reason: "estaba en marcha en la copia restaurada")
        schedule()
        syncCalendar()
        let prevName = prevURL?.lastPathComponent ?? "backups"
        notice = "Copia restaurada (\(restored.tasks.count) tareas, \(restored.history.count) sesiones). Respaldo previo guardado en \(prevName)."
    }

    func removeDetailedHistory() {
        guard writable else { return }
        if workspace.settings.protectActivityHistory && refuseWhileProtected("borrar los detalles del historial de actividad") { return }
        for index in workspace.history.indices {
            workspace.history[index].preserveSummary()
            workspace.history[index].session.activities = []
            workspace.history[index].session.baseline = [:]
        }
        _ = persist()
    }

    /// Recently visited domains observed during sessions or in the live browser inspector (`HistoryTarget` equivalent).
    var recentObservedDomains: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func push(_ raw: String) {
            guard let clean = FocusRules.normalizeDomainEntry(raw),
                  !clean.isEmpty,
                  seen.insert(clean).inserted else { return }
            result.append(clean)
        }
        for page in lastObservedBrowserPage.values {
            push(page.host)
        }
        if let s = session {
            for act in s.activities.reversed() {
                if let dom = act.domain { push(dom) }
            }
        }
        for rec in workspace.history.suffix(15).reversed() {
            for act in rec.session.activities.reversed() {
                if let dom = act.domain { push(dom) }
                if result.count >= 20 { return result }
            }
        }
        return result
    }

    /// Recently seen window titles observed during sessions or in the live foreground/browser inspector (`HistoryTarget` equivalent).
    var recentObservedTitles: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func push(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, seen.insert(trimmed.lowercased()).inserted else { return }
            result.append(trimmed)
        }
        if let t = lastTitle.title, !t.isEmpty {
            push(t)
        }
        if let s = session {
            for act in s.activities.reversed() {
                if let t = act.title, !t.isEmpty { push(t) }
            }
        }
        for rec in workspace.history.suffix(15).reversed() {
            for act in rec.session.activities.reversed() {
                if let t = act.title, !t.isEmpty { push(t) }
                if result.count >= 20 { return result }
            }
        }
        return result
    }

    func shutdown() {
        if session?.endedAt == nil {
            // Closed by a restart, a shutdown or a log-out in the middle of a protected session: macOS is let
            // through, and the session comes back at the next launch while it still has time left.
            let comeBackUntil: Date? = quittingForSystem && protectedSessionRunning
                ? session.map { Date().addingTimeInterval(max(0, $0.remaining(at: Date(), uptime: uptime))) }
                : nil
            workspace.session?.pause(at: Date(), uptime: uptime)
            workspace.session?.resumeOnLaunchUntil = comeBackUntil
            if let s = workspace.session {
                enqueueProjectionForTask(s.task, session: s, now: Date())
            }
        }
        floatingPill.hide()
        // Read by the watcher, which must not reopen FocusDesk in the middle of a restart.
        workspace.closedBySystemAt = quittingForSystem ? Date() : nil
        _ = persist()
        syncCalendar()
        if !preview { focusMode.turnOffNowIfOurs() }
    }
}
