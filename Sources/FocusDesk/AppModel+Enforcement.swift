import AppKit
import FocusCore

// What happens when you try to leave a session that you asked to be protected, and what happens to the apps and
// pages that are not part of it. The decisions live in FocusCore; this file is the hands.

/// The code standing between the user and stopping a protected session, with what has been typed so far.
struct PendingStopChallenge: Identifiable, Equatable {
    let id = UUID()
    var reason: StopReason
    var expected: String
    var typed: String = ""
    /// The long code for `.forced`: the way out exists, but it leaves a mark in the history.
    var emergency = false
    var attempts = 0
    /// Set when the code was asked for because FocusDesk was being quit: typing it right quits too.
    var quitAfter = false
    /// Set when the code guards a change to a task that is about to start, not a running session.
    var runUp: RunUpChange?
    /// That change named as an action («Retrasarla»), for the sheet's button.
    var runUpAction = ""

    var title: String {
        if emergency { return "Salida de emergencia" }
        if runUp != nil { return "Cambiar una tarea protegida" }
        switch reason {
        case .pause: return "Pausar la sesión"
        case .cancel: return "Cancelar la sesión"
        case .finishEarly: return "Terminar antes de tiempo"
        }
    }

    var correctSoFar: Int { UnlockChallenge.correctPrefix(typed: typed, expected: expected) }
    var complete: Bool { UnlockChallenge.matches(typed: typed, expected: expected) }
}

/// A change to a task that may be about to start, kept whole so it can be applied once its way out is paid.
enum RunUpChange: Equatable {
    case save(FocusTask, detachFromSeriesID: UUID?, occurrenceDate: Date?)
    case delete(FocusTask)
    case shift(FocusTask, to: Date, minutes: Int?)
    case snooze(FocusTask, minutes: Int)
    case inbox(FocusTask)

    var task: FocusTask {
        switch self {
        case .save(let t, _, _), .delete(let t), .shift(let t, _, _), .snooze(let t, _), .inbox(let t): return t
        }
    }

    /// The occurrence the change acts on. A series is one task whose `scheduledAt` is today's occurrence; editing a
    /// later occurrence from the agenda is not touching today's.
    var occurrence: Date {
        switch self {
        case .save(let t, _, let date): return date ?? t.scheduledAt
        default: return task.scheduledAt
        }
    }

    enum Outcome { case deleted, changed(FocusTask) }

    /// What `current` would become.
    func outcome(from current: FocusTask, now: Date) -> Outcome {
        switch self {
        case .save(let t, _, _): return .changed(t)
        case .delete: return .deleted
        case .shift(_, let date, let minutes):
            var moved = current
            moved.scheduledAt = date
            moved.isScheduled = true
            if let minutes { moved.minutes = FocusRules.clampedMinutes(minutes) }
            return .changed(moved)
        case .snooze(_, let minutes): return .changed(current.snoozed(minutes: minutes, now: now))
        case .inbox:
            var unscheduled = current
            unscheduled.isScheduled = false
            return .changed(unscheduled)
        }
    }
}

extension AppModel {

    // MARK: - Protected before it starts

    /// Starts of sessions of `taskID` in the history: one inside the run-up window means it was already worked on.
    func sessionStarts(of taskID: UUID) -> [Date] {
        workspace.history.filter { $0.session.task.id == taskID }.map(\.session.startedAt)
    }

    /// Whether `task` already defends itself because it is about to start (for the agenda's lock and the editor).
    func protectedBeforeStart(_ task: FocusTask, at instant: Date = Date()) -> Bool {
        guard task.id != session?.task.id else { return false }
        return RunUp.isArmed(task, minutes: workspace.settings.runUpMinutes, now: instant, sessionStarts: sessionStarts(of: task.id))
    }

    /// True when `change` may go ahead now. A protected task that is about to start costs what stopping it would
    /// cost — the code, the wait or the emergency exit — to put off or soften; doing it sooner, longer or more
    /// strictly stays free. When it may not go ahead, this leaves the way out on screen and answers false.
    func passesRunUpGate(_ change: RunUpChange) -> Bool {
        let current = workspace.tasks.first { $0.id == change.task.id } ?? change.task
        if authorizedRunUp == current.id {
            authorizedRunUp = nil
            return true
        }
        let instant = Date()
        guard abs(change.occurrence.timeIntervalSince(current.scheduledAt)) < 60,
              protectedBeforeStart(current, at: instant) else { return true }
        let what: String?
        switch change.outcome(from: current, now: instant) {
        case .deleted: what = RunUp.loosening(current: current, proposed: nil)
        case .changed(let proposed): what = RunUp.loosening(current: current, proposed: proposed)
        }
        guard let what else { return true }

        let time = current.scheduledAt.formatted(date: .omitted, time: .shortened)
        let lead = current.scheduledAt > instant
            ? "«\(current.title)» empieza a las \(time) y ya está protegida."
            : "«\(current.title)» era a las \(time) y sigue protegida hasta su hora de fin."
        switch current.protection {
        case .none:
            return true
        case .challenge:
            presentStopChallenge(PendingStopChallenge(
                reason: .cancel, expected: UnlockChallenge.make(length: current.unlockChars),
                runUp: change, runUpAction: what))
            notice = "\(lead) \(what) cuesta lo mismo que pararla: teclea el código."
            return false
        case .delay:
            if let wait = runUpWaits[current.id] {
                guard wait.ready() else {
                    notice = "\(lead) Faltan \(FocusRules.clock(wait.remaining())) de la espera que pediste; al cumplirse, vuelve a hacerlo."
                    return false
                }
                runUpWaits[current.id] = nil
                runUpWaitsNotified.remove(current.id)
                return true
            }
            runUpWaits[current.id] = StopRequest(reason: .cancel, minutes: current.stopDelayMinutes)
            notice = "\(lead) \(what) cuesta lo mismo que pararla: una espera de \(current.stopDelayMinutes) min. Cuando pase, vuelve a hacerlo."
            return false
        case .forced:
            presentStopChallenge(PendingStopChallenge(
                reason: .cancel, expected: UnlockChallenge.make(length: 60), emergency: true,
                runUp: change, runUpAction: what))
            notice = "\(lead) Está en «Hasta el final»: \(what.lowercased()) solo con la salida de emergencia, que queda anotada."
            return false
        }
    }

    /// Applies a change whose way out was just paid, letting it through the gate exactly once.
    func applyPaidRunUpChange(_ change: RunUpChange) {
        authorizedRunUp = change.task.id
        defer { authorizedRunUp = nil }
        switch change {
        case .save(let t, let seriesID, let date): saveTask(t, detachFromSeriesID: seriesID, occurrenceDate: date)
        case .delete(let t): deleteTask(t)
        case .shift(let t, let date, let minutes): shift(t, to: date, durationMinutes: minutes)
        case .snooze(let t, let minutes): snoozeTask(t, minutes: minutes)
        case .inbox(let t): moveToInbox(t)
        }
    }

    /// Says when a wait asked for before a task starts is over, since by then the user is usually elsewhere.
    func checkRunUpWaitsReady() {
        for (taskID, wait) in runUpWaits where wait.ready() && !runUpWaitsNotified.contains(taskID) {
            runUpWaitsNotified.insert(taskID)
            guard let task = workspace.tasks.first(where: { $0.id == taskID }) else { continue }
            notice = "La espera ha terminado: ya puedes cambiar «\(task.title)». Si has cambiado de idea, déjala como está."
            if !preview {
                reminders.notify(
                    "Ya puedes cambiar «\(task.title)»",
                    body: "La espera ha terminado. Repite el cambio en FocusDesk si sigues queriendo.",
                    identifier: "runupready-" + taskID.uuidString
                )
            }
        }
    }

    // MARK: - Leaving a protected session

    /// True when the session may stop right now. When it may not, this leaves the code, the wait or the refusal
    /// on screen and answers false, so the caller does nothing.
    func passesStopGate(_ reason: StopReason, session s: WorkSession) -> Bool {
        // The code was typed correctly a moment ago and this is the same stop going through.
        if authorizedStop == reason {
            authorizedStop = nil
            return true
        }
        guard s.task.protection != .none else { return true }
        switch StopGate.decide(
            protection: s.task.protection,
            reason: reason,
            timeLeft: currentRemaining(for: s),
            unlockChars: s.task.unlockChars,
            stopDelayMinutes: s.task.stopDelayMinutes,
            pending: s.stopRequest
        ) {
        case .allowed:
            return true
        case .waitFinished:
            workspace.session?.stopRequest = nil
            stopReadyNotified = false
            _ = persist()
            return true
        case .challenge(let code):
            presentStopChallenge(PendingStopChallenge(reason: reason, expected: code))
            return false
        case .waitStarted(let seconds):
            workspace.session?.stopRequest = StopRequest(reason: reason, minutes: s.task.stopDelayMinutes)
            stopReadyNotified = false
            _ = persist()
            notice = "Has pedido \(reason.verb). FocusDesk espera \(FocusRules.clock(seconds)) y entonces te deja; mientras, la sesión sigue. Puedes arrepentirte."
            return false
        case .waiting(let left):
            notice = "Ya pediste \(reason.verb). Faltan \(FocusRules.clock(left)); al cumplirse, vuelve a pulsarlo."
            return false
        case .refused(let why):
            notice = why
            return false
        }
    }

    /// Puts the code on screen. The task editor is closed first: two sheets cannot share the window, and a code
    /// that never appears would leave the user without a visible way out.
    func presentStopChallenge(_ challenge: PendingStopChallenge) {
        guard editingTask != nil else {
            pendingStop = challenge
            showWindow?()
            return
        }
        editingTask = nil
        // Once the editor has finished closing, or the new sheet would be dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingStop = challenge
                self?.showWindow?()
            }
        }
    }

    /// Lets go of a wait the user no longer wants: the session simply carries on.
    func cancelStopRequest() {
        guard workspace.session?.stopRequest != nil else { return }
        workspace.session?.stopRequest = nil
        stopReadyNotified = false
        _ = persist()
        notice = "Espera cancelada. Sigues con la tarea."
    }

    /// Checks the typed code. A wrong one hands out a fresh code: a half-typed string is not a free retry.
    func submitStopChallenge() {
        guard let challenge = pendingStop else { return }
        guard challenge.complete else {
            let length = challenge.emergency ? 60 : (challenge.runUp?.task.unlockChars ?? session?.task.unlockChars ?? 24)
            pendingStop?.attempts += 1
            pendingStop?.typed = ""
            pendingStop?.expected = UnlockChallenge.make(length: length)
            notice = "El código no coincide. Aquí tienes otro."
            return
        }
        let reason = challenge.reason
        let wasEmergency = challenge.emergency
        let shouldQuit = challenge.quitAfter
        pendingStop = nil
        if let change = challenge.runUp {
            if wasEmergency { workspace.settings.emergencyUses.append(FocusRules.dayKey(for: Date())) }
            applyPaidRunUpChange(change)
            if wasEmergency { notice = "Salida de emergencia usada para «\(change.task.title)». Queda anotada." }
            return
        }
        if wasEmergency {
            workspace.settings.emergencyUses.append(FocusRules.dayKey(for: Date()))
            notice = "Salida de emergencia usada. Queda anotada en el historial de la sesión."
        }
        authorizedStop = reason
        switch reason {
        case .pause: pause()
        case .cancel: cancelSession(note: wasEmergency ? "Cancelada con la salida de emergencia" : "Cancelada tras teclear el código")
        case .finishEarly: finish()
        }
        authorizedStop = nil
        if shouldQuit { NSApp.terminate(nil) }
    }

    /// Answers whether FocusDesk may quit now. Quitting with a protected session running is the same escape as
    /// pausing it, so it costs the same: the code, or the wait.
    /// A restart, a shutdown or a log-out always goes through: refusing one is how somebody ends up holding the
    /// power button and losing what is open in every other app. The session comes back at the next launch.
    /// The demo mode (`--preview`) always lets go: trying out a locked session must not trap anyone in a demo.
    func canQuitNow(systemQuit: Bool = false) -> Bool {
        // Set on every request: a restart that another app called off must not mark a later ordinary quit.
        quittingForSystem = systemQuit
        if systemQuit { return true }
        guard !preview, let s = session, s.enforcing(at: now, uptime: uptime), s.task.protection != .none else { return true }
        if authorizedStop == .pause { return true }
        switch StopGate.decide(
            protection: s.task.protection,
            reason: .pause,
            timeLeft: currentRemaining(for: s),
            unlockChars: s.task.unlockChars,
            stopDelayMinutes: s.task.stopDelayMinutes,
            pending: s.stopRequest
        ) {
        case .allowed, .waitFinished:
            return true
        case .challenge(let code):
            presentStopChallenge(PendingStopChallenge(reason: .pause, expected: code, quitAfter: true))
            notice = "Salir con una sesión protegida en marcha es como pausarla: teclea el código."
            return false
        case .waitStarted(let seconds):
            workspace.session?.stopRequest = StopRequest(reason: .pause, minutes: s.task.stopDelayMinutes)
            stopReadyNotified = false
            _ = persist()
            notice = "Has pedido salir. FocusDesk espera \(FocusRules.clock(seconds)) y entonces te deja; mientras, la sesión sigue."
            showWindow?()
            return false
        case .waiting(let left):
            notice = "Faltan \(FocusRules.clock(left)) para poder salir. La sesión sigue en marcha."
            showWindow?()
            return false
        case .refused(let why):
            notice = why
            showWindow?()
            return false
        }
    }

    func dismissStopChallenge() {
        let runUp = pendingStop?.runUp
        pendingStop = nil
        if let runUp {
            notice = "«\(runUp.task.title)» se queda como estaba."
            return
        }
        // A task queued by a hand-off waited for this stop; without it, the running session simply carries on.
        if session?.endedAt == nil { queuedStartTaskID = nil }
        notice = "Sigues con la tarea."
    }

    /// The way out of a session set to «Hasta el final»: sixty characters, no paste, and a line in the history.
    func requestEmergencyExit() {
        guard let s = session, s.endedAt == nil else { return }
        presentStopChallenge(PendingStopChallenge(reason: .cancel, expected: UnlockChallenge.make(length: 60), emergency: true))
        notice = "«\(s.task.title)» está en «Hasta el final». La salida de emergencia existe, pero cuesta 60 caracteres y queda registrada."
    }

    /// Tells the user the moment a wait is up, since they are usually looking at something else by then.
    func checkStopRequestReady() {
        guard let s = session, let request = s.stopRequest, !stopReadyNotified, request.ready() else { return }
        stopReadyNotified = true
        notice = "Ya puedes \(request.reason.verb) «\(s.task.title)». Si has cambiado de idea, sigue trabajando."
        if !preview {
            reminders.notify(
                "Puedes \(request.reason.verb) · \(s.task.title)",
                body: "La espera ha terminado. Vuelve a pulsarlo en FocusDesk si sigues queriendo.",
                identifier: "stopready-" + s.id.uuidString
            )
        }
    }

    // MARK: - Folders the task closes

    /// A folder the task closes, opened anyway: a Finder window showing it goes back to the folder above, and an
    /// app showing a file from inside it (a film in QuickTime) has that window closed.
    func guardBlockedFolders(frontBundleID id: String, frontApp: NSRunningApplication, session s: WorkSession) {
        let folders = s.task.blockedFolders
        let finderID = "com.apple.finder"
        if id != finderID, id != Bundle.main.bundleIdentifier,
           let path = FolderInspector.frontDocumentPath(pid: frontApp.processIdentifier),
           let folder = FolderRules.blockingFolder(for: path, in: folders) {
            let closed = WindowCloser.closeFrontWindow(pid: frontApp.processIdentifier)
            let name = FolderRules.name(of: folder)
            let app = frontApp.localizedName ?? id
            reportFolderBlock(closed
                ? "«\(name)» está bloqueada mientras dura «\(s.task.title)»: he cerrado esa ventana de \(app)."
                : "«\(name)» está bloqueada mientras dura «\(s.task.title)», pero \(app) no deja cerrar esa ventana.",
                session: s)
        }
        // Finder windows count in front or visible behind; a Finder with nothing on screen is not asked.
        guard !finderCheckBusy,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first,
              id == finderID || ScreenWindows.visibleOwnerPIDs().contains(finder.processIdentifier) else { return }
        finderCheckBusy = true
        FolderInspector.moveFinderWindowsOut(of: folders) { [weak self] result in
            guard let self else { return }
            self.finderCheckBusy = false
            switch result {
            case .movedOut(let hits) where !hits.isEmpty:
                let names = hits.map { "«\(FolderRules.name(of: $0))»" }.joined(separator: ", ")
                let verb = hits.count == 1 ? "está bloqueada" : "están bloqueadas"
                self.reportFolderBlock(
                    "\(names) \(verb) mientras dura «\(s.task.title)»: el Finder vuelve a la carpeta de arriba.",
                    session: s)
            case .permissionDenied where !self.warnedFinderPermission:
                self.warnedFinderPermission = true
                self.notice = "FocusDesk no tiene permiso para ver qué carpeta enseña el Finder, así que no puede cerrar las carpetas de esta tarea. Dalo en Ajustes del Sistema › Privacidad y seguridad › Automatización."
            default:
                break
            }
        }
    }

    private func reportFolderBlock(_ message: String, session s: WorkSession) {
        workspace.session?.registerBlock()
        notice = message
        if !preview { notifyDistraction(message, session: s) }
    }

    // MARK: - Editing the task that is running

    /// A running session can be made stricter — more time, a harder lock, fewer apps — and never looser. A refusal
    /// says which field was the problem, so the change is not just silently dropped.
    func applyRatchetedEdit(_ input: FocusTask, to running: WorkSession) {
        var task = input
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.domains = FocusRules.normalizeDomains(task.domains)
        // Only while it is actually enforcing: an unprotected session is an ordinary edit.
        if running.enforcing(at: now, uptime: uptime) || running.task.protection != .none {
            if case .refused(let why) = Ratchet.judge(current: running.task, proposed: task) {
                notice = why
                return
            }
        }
        let extraMinutes = task.minutes - running.task.minutes
        workspace.session?.task = task
        if extraMinutes > 0 {
            workspace.session?.add(minutes: extraMinutes)
            overtimeNotified = false
        }
        if let index = workspace.tasks.firstIndex(where: { $0.id == task.id }) {
            workspace.tasks[index] = task
        }
        editingTask = nil
        if persist() {
            notice = extraMinutes > 0
                ? "«\(task.title)» actualizada: \(extraMinutes) min más y las reglas que has endurecido."
                : "«\(task.title)» actualizada con las reglas nuevas."
            if let s = workspace.session { enqueueProjectionForTask(task, session: s, now: Date()) }
            syncCalendar()
        }
    }

    // MARK: - Apps outside the task

    /// Acts on an app that is in front and is not part of the task. Returns false when the session was paused or
    /// the caller should stop looking at this round.
    @discardableResult
    func enforceApp(_ distracting: NSRunningApplication, bundleID id: String, session s: WorkSession, isNewInterruption: Bool, at: Date) -> Bool {
        // Never act on FocusDesk itself, whatever a rule says.
        guard distracting.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return true }
        let distractingName = distracting.localizedName ?? id
        let runningTarget = lastAllowed.flatMap { candidate in
            (candidate.isTerminated || !s.task.apps.contains(where: { a in a.id == candidate.bundleIdentifier })) ? nil : candidate
        } ?? NSWorkspace.shared.runningApplications.first { app in
            !app.isTerminated && s.task.apps.contains { $0.id == app.bundleIdentifier }
        }

        // No allowed app open: open one instead of pausing straight away (twice at most, then the pause below).
        if runningTarget == nil, strictLaunchAttempts < 2,
           let (allowedApp, url) = s.task.apps.lazy.compactMap({ app in AppModel.installedURL(of: app).map { (app, $0) } }).first {
            strictLaunchAttempts += 1
            distracting.hide()
            notice = "\(distractingName) no está entre las apps de esta tarea: la he ocultado y abro \(allowedApp.name)."
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
            scheduleStrictRecheck(after: 1.5)
            return false
        }

        switch strictTracker.evaluateUnallowed(hasRunningAllowedApp: runningTarget != nil, at: at) {
        case .none:
            return true
        case .cooldown:
            scheduleStrictRecheck(after: strictTracker.cooldown)
            return true
        case .redirect:
            guard let target = runningTarget else { return true }
            // Several tries in a row at the same wall means the impulse is winning: the block gets harder.
            let punisherJustFired = workspace.session?.registerBlock() ?? false
            let verb = applyBlockAction(to: distracting, bundleID: id)
            let ok = target.activate(options: [])
            strictTracker.recordRedirectAttempt(succeeded: ok)
            if punisherJustFired, let message = punisherMessage(for: s) {
                notice = message
            } else {
                notice = ok
                    ? "\(distractingName) no está entre las apps de esta tarea: \(verb) y vuelves a \(target.localizedName ?? "la app permitida")."
                    : "No se pudo volver a \(target.localizedName ?? "la app permitida"). Puedes pausar en cualquier momento."
            }
            if isNewInterruption, !preview { notifyDistraction(notice ?? "", session: s) }
            scheduleStrictRecheck(after: 0.8)
            return false
        case .pauseSession(let reason):
            if s.task.protection != .none {
                // A protected session never pauses itself: that was a free way out (quit the allowed apps, or flick
                // back to the blocked one three times in a row). FocusDesk's own window is where it sends you
                // instead, and the code, the wait or «Emergencia» stay the way out.
                _ = applyBlockAction(to: distracting, bundleID: id)
                notice = runningTarget == nil
                    ? "\(distractingName) no entra en esta tarea y no hay ninguna app permitida abierta. Abre una desde el Dock o el Finder: la sesión sigue."
                    : "\(distractingName) no entra en esta tarea. Vuelve a \(runningTarget?.localizedName ?? "la app permitida"): la sesión sigue."
                showWindow?()
                if isNewInterruption, !preview { notifyDistraction(notice ?? "", session: s) }
                scheduleStrictRecheck(after: 1.5)
                return false
            }
            // The safety valve of an unprotected session: nowhere to send the user back to. Pausing here needs no
            // code, or the session would be stuck with no allowed app and no way out.
            performPause()
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
            return false
        }
    }

    /// Applies the task's action to an app outside it — one step harder while the punisher is on — and says what
    /// was done. Nothing on the never-close list is ever more than hidden.
    private func applyBlockAction(to app: NSRunningApplication, bundleID id: String) -> String {
        switch FocusRules.safeAction(workspace.session?.activeBlockAction() ?? .hide, for: id) {
        case .hide:
            app.hide()
            return "la he ocultado"
        case .close:
            // Like ⌘Q: the app can still offer to save.
            app.terminate()
            return "la he cerrado"
        case .forceQuit:
            app.forceTerminate()
            return "la he cerrado a la fuerza"
        }
    }

    /// What gets harder when the punisher goes off, said plainly. Nil when nothing changes for this task (it
    /// already closes apps and tabs), so it never claims a change that does not happen.
    func punisherMessage(for s: WorkSession) -> String? {
        guard let until = workspace.session?.punisher.remaining(), until > 0 else { return nil }
        var harder: [String] = []
        if s.task.strict, s.task.blockAction == .hide { harder.append("cerrará las apps que distraen en vez de ocultarlas") }
        if s.task.webBlockAction == .redirect { harder.append("cerrará las pestañas bloqueadas en vez de redirigirlas") }
        guard !harder.isEmpty else { return nil }
        return "Van \(s.punisher.maxAttempts) intentos seguidos. Durante \(FocusRules.clock(until)) FocusDesk \(harder.joined(separator: " y "))."
    }

    /// Windows drawn on any monitor without the keyboard focus — a video playing in the corner while you type in
    /// the editor. Hidden, never closed: closing something you are not even looking at could throw work away.
    func sweepBackgroundWindows() {
        guard let s = session, s.enforcing(at: now, uptime: uptime), s.task.strict,
              workspace.settings.watchBackgroundWindows, !s.task.apps.isEmpty,
              Date().timeIntervalSince(lastBackgroundSweepAt) >= 6 else { return }
        lastBackgroundSweepAt = Date()
        var exempt = FocusRules.systemExemptBundleIDs
        if let ownID = Bundle.main.bundleIdentifier { exempt.insert(ownID) }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontID { exempt.insert(frontID) }   // the app in front is handled by `observe`
        let allowedIDs = Set(s.task.apps.map(\.id))
        let offenders = ScreenWindows.visibleUnallowedApps(allowedBundleIDs: allowedIDs, exempt: exempt)
        guard !offenders.isEmpty else { return }
        var names: [String] = []
        for app in offenders.prefix(4) where !app.isHidden {
            app.hide()
            names.append(app.localizedName ?? app.bundleIdentifier ?? "una app")
        }
        guard !names.isEmpty else { return }
        // Counted, but not fed to the punisher: a window FocusDesk found on its own is not an attempt of yours.
        workspace.session?.blocksApplied += 1
        notice = names.count == 1
            ? "\(names[0]) seguía a la vista en otra ventana: la he ocultado."
            : "Seguían a la vista sin tener el foco: \(names.joined(separator: ", ")). Las he ocultado."
    }

    // MARK: - Websites

    /// Reads the active tab of a browser and, if the task blocks websites, acts on that tab alone.
    func inspectBrowser(bundleID: String, session s: WorkSession) {
        let sessionID = s.id
        webInspector.read(bundleID: bundleID) { [weak self] result in
            guard let self,
                  let current = self.session,
                  current.id == sessionID,
                  !current.paused,
                  current.endedAt == nil,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            let browserName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "el navegador"
            switch result {
            case .page(let host):
                self.braveStatus = "\(browserName): \(host)"
                self.handleVisit(host: host, bundleID: bundleID, browserName: browserName, session: current)
            case .permissionDenied:
                self.braveStatus = "\(browserName): permiso de Automatización denegado"
                if self.workspace.session?.activities.last?.domainStatus != "sin permiso" {
                    self.workspace.session?.record(
                        Activity(appID: bundleID, name: browserName, domainStatus: "sin permiso"),
                        at: Date(),
                        uptime: self.uptime
                    )
                }
                // A browser whose address FocusDesk cannot read is a hole in a session that blocks websites: say so.
                if current.task.webBlockAction != .warn {
                    self.notice = "\(browserName) bloquea webs en esta tarea, pero macOS no deja leer su dirección. Dale permiso en Ajustes del Sistema › Privacidad y seguridad › Automatización."
                }
            case .noWindowOrTab:
                self.braveStatus = "\(browserName): sin ventana o pestaña activa"
            case .notRunning:
                self.braveStatus = "\(browserName) cerrado"
            case .timeout:
                self.braveStatus = "\(browserName): respuesta tardía"
            case .unknown:
                self.braveStatus = "\(browserName): pestaña interna o dirección desconocida"
            }
        }
    }

    /// One visit to one host: recorded once, and blocked once if the task says so.
    func handleVisit(host: String, bundleID: String, browserName: String, session s: WorkSession) {
        let outside = !FocusRules.domainAllowed(host, list: s.task.domains)
        let changed = workspace.session?.activities.last?.domain != host
        let newVisit = outside && domainEpisodeHost != host
        if changed {
            workspace.session?.record(
                Activity(appID: bundleID, name: browserName, domain: host, interruption: newVisit),
                at: Date(),
                uptime: uptime
            )
        }
        domainEpisodeHost = outside ? host : nil
        guard outside else { return }

        switch s.task.webBlockAction {
        case .warn:
            if newVisit {
                notice = "\(host) no está en los dominios de la tarea. El control de webs es informativo."
                if !preview { notifyDistraction(notice ?? "", session: s) }
            }
        case .redirect, .closeTab:
            // One action per visit while the browser is still changing the tab. Seen again a few seconds later —
            // Back from the blocked page, a reopened tab — it is blocked again: remembering the host for the whole
            // visit let Back walk straight past the block. (FocusDesk's own page is a file, never read as a host.)
            if lastWebBlockHost == host, Date().timeIntervalSince(lastWebBlockAt) < 4 { return }
            lastWebBlockHost = host
            lastWebBlockAt = Date()
            let punisherJustFired = workspace.session?.registerBlock() ?? false
            let hardened = punisherJustFired || (workspace.session?.punisher.isActive() ?? false)
            let action: WebBlockAction = hardened && s.task.webBlockAction == .redirect ? .closeTab : s.task.webBlockAction
            if action == .closeTab {
                webInspector.closeActiveTab(bundleID: bundleID) { [weak self] ok in
                    guard let self else { return }
                    if ok, punisherJustFired, let message = self.punisherMessage(for: s) {
                        self.notice = message
                    } else {
                        self.notice = ok
                            ? "\(host) no entra en esta tarea: he cerrado esa pestaña. El resto del navegador sigue como estaba."
                            : "\(host) no entra en esta tarea, pero no pude cerrar la pestaña. Revisa el permiso de Automatización."
                    }
                    if !self.preview { self.notifyDistraction(self.notice ?? "", session: s) }
                }
            } else {
                let remaining = currentRemaining(for: s)
                guard let page = BlockPage.write(
                    taskTitle: s.task.title,
                    host: host,
                    remaining: remaining,
                    endsAt: Date().addingTimeInterval(max(0, remaining)),
                    allowedDomains: FocusRules.parseDomains(s.task.domains).valid,
                    in: store.url.deletingLastPathComponent()
                ) else {
                    notice = "\(host) no entra en esta tarea, pero no se pudo preparar la página de bloqueo."
                    return
                }
                webInspector.redirectActiveTab(bundleID: bundleID, to: page) { [weak self] ok in
                    guard let self else { return }
                    self.notice = ok
                        ? "\(host) no entra en esta tarea: esa pestaña va a la página de bloqueo. Las demás siguen abiertas."
                        : "\(host) no entra en esta tarea, pero no pude cambiar la pestaña. Revisa el permiso de Automatización."
                    if !self.preview { self.notifyDistraction(self.notice ?? "", session: s) }
                }
            }
        }
    }

    /// Pages opened inside Electron apps (Discord, Slack, Notion…). Only reported, never closed: these windows
    /// hold conversations and documents, and quitting one to kill a video would be a bad trade.
    func scanEmbeddedPages() {
        guard let s = session, s.enforcing(at: now, uptime: uptime),
              s.task.webBlockAction != .warn, workspace.settings.inspectEmbeddedPages,
              Date().timeIntervalSince(lastEmbeddedScanAt) >= 20,
              let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier, !WebRules.isBrowser(id) else { return }
        lastEmbeddedScanAt = Date()
        let hosts = AppInspector.embeddedHosts(for: front)
        guard !hosts.isEmpty else { return }
        let blocked = hosts.filter { !FocusRules.domainAllowed($0, list: s.task.domains) }
        guard let host = blocked.first, embeddedReportedHost != host else { return }
        embeddedReportedHost = host
        workspace.session?.record(
            Activity(appID: id, name: front.localizedName ?? id, domain: host, interruption: true),
            at: Date(),
            uptime: uptime
        )
        notice = "Dentro de \(front.localizedName ?? id) hay una página de \(host), que no entra en esta tarea."
        if !preview { notifyDistraction(notice ?? "", session: s) }
    }

    // MARK: - System Settings

    /// Closes the System Settings window when it lands on a pane that would end the block, and leaves every other
    /// pane alone: changing the Wi-Fi or the volume mid-session has to keep working.
    /// Returns true when the window was closed.
    @discardableResult
    func guardSystemSettingsIfNeeded(bundleID: String, pid: pid_t, session s: WorkSession) -> Bool {
        guard s.task.guardSystemPanes, s.enforcing(at: now, uptime: uptime),
              SystemSettingsGuard.bundleIDs.contains(bundleID),
              Date().timeIntervalSince(lastSettingsGuardAt) >= 1 else { return false }
        lastSettingsGuardAt = Date()
        guard let pane = SystemSettingsGuard.selectedPane(pid: pid) else { return false }
        guard SystemSettingsGuard.closeFrontWindow(pid: pid) else {
            notice = "Has abierto «\(pane.names.first ?? "ese panel")» con una sesión protegida. \(pane.explanation)"
            return false
        }
        workspace.session?.registerBlock()
        notice = "He cerrado ese panel de Ajustes del Sistema mientras dura la sesión. \(pane.explanation) El resto de Ajustes sigue disponible."
        if !preview { notifyDistraction(notice ?? "", session: s) }
        return true
    }

    // MARK: - The clock

    /// Watches for the oldest trick there is: moving the Mac's clock forward so the session ends early. The
    /// countdown already runs on a clock the user cannot wind, so this only has to notice and say so.
    func checkClockDrift() {
        guard let s = session, s.enforcing(at: now, uptime: uptime) else { clockWarning = nil; return }
        let drift = TrustedClock.drift(
            wall: Date(),
            continuous: TrustedClock.continuousSeconds(),
            anchorWall: s.wallAnchor,
            anchorContinuous: s.continuousAnchor
        )
        guard abs(drift) > TrustedClock.suspiciousDrift else { return }
        workspace.session?.clockJump = drift
        // Re-anchor so the same jump is not reported every second.
        workspace.session?.wallAnchor = Date()
        workspace.session?.continuousAnchor = TrustedClock.continuousSeconds()
        let minutes = Int(abs(drift) / 60)
        clockWarning = drift > 0
            ? "El reloj del Mac ha saltado \(minutes) min hacia delante. La sesión sigue con su propio reloj: no se acorta."
            : "El reloj del Mac ha retrocedido \(minutes) min. La sesión sigue con su propio reloj."
        notice = clockWarning
    }

    // MARK: - The witness

    /// Writes the fingerprint of the running protected session into the Keychain, outside `workspace.json`.
    func refreshWitness() {
        guard !preview else { return }
        guard let s = session, s.enforcing(at: now, uptime: uptime), s.task.protection != .none else {
            KeychainWitness.clear()
            return
        }
        KeychainWitness.save(
            SessionWitness(
                sessionID: s.id,
                taskTitle: s.task.title,
                protection: s.task.protection,
                deadline: s.witnessDeadline(at: now, uptime: uptime)
            )
        )
    }

    /// At launch: a witness for a protected session that the data file no longer knows about means the file was
    /// edited, replaced or deleted while FocusDesk was closed. Say it plainly instead of letting the block vanish.
    func checkWitnessAtLaunch() {
        guard !preview, let witness = KeychainWitness.load() else { return }
        guard witness.live() else { KeychainWitness.clear(); return }
        if let s = session, s.id == witness.sessionID { return }
        let left = FocusRules.clock(witness.remaining())
        error = """
        «\(witness.taskTitle)» estaba protegida hasta dentro de \(left) y ya no aparece en tus datos. Si has \
        cambiado o borrado el archivo de FocusDesk, esa sesión se perdió: vuelve a empezarla si de verdad querías \
        trabajar en ella. Este aviso es todo lo que una app sin permisos de administrador puede hacer.
        """
        KeychainWitness.clear()
    }
}
