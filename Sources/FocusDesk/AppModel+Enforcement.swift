import AppKit
import ApplicationServices
import UniformTypeIdentifiers
import FocusCore

// What happens when you try to leave a session that you asked to be protected, and what happens to the apps and
// pages that are not part of it. The decisions live in FocusCore; this file is the hands.

/// A change to an actively enforcing protected `GeneralBlockRule`, kept whole so it can be applied once its challenge is paid.
enum GeneralRuleChange: Equatable {
    case save(GeneralBlockRule)
    case delete(GeneralBlockRule)
    case resetQuota(GeneralBlockRule)

    var rule: GeneralBlockRule {
        switch self {
        case .save(let r), .delete(let r), .resetQuota(let r): return r
        }
    }
}

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
    /// Set when the code guards disabling, deleting or loosening an active `GeneralBlockRule`.
    var generalRule: GeneralRuleChange?
    var generalRuleAction = ""

    var title: String {
        if emergency { return "Salida de emergencia" }
        if generalRule != nil { return "Cambiar una regla protegida" }
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

    // MARK: - The Accessibility permission

    /// What the running session and the rules that are on cannot do, in words, while the permission is missing.
    var accessibilityWarning: String? {
        guard !preview, !accessible else { return nil }
        let running = session.flatMap { $0.endedAt == nil && !$0.paused ? $0.task : nil }
        return AccessibilityNeed.warning(for: AccessibilityNeed.features(
            session: running,
            rules: workspace.generalRules,
            inspectEmbeddedPages: workspace.settings.inspectEmbeddedPages
        ))
    }

    /// Checked as a protected session starts: finding out in the middle of it is too late.
    func warnIfAccessibilityMissing(startingWith task: FocusTask) {
        accessible = MacActivity.accessibility
        guard !preview, !accessible, task.protection != .none else { return }
        let features = AccessibilityNeed.features(of: task, inspectEmbeddedPages: workspace.settings.inspectEmbeddedPages)
        if let warning = AccessibilityNeed.warning(for: features) { notice = warning }
    }

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
        case .deleted: what = RunUp.loosening(current: current, proposed: nil, now: instant)
        case .changed(let proposed): what = RunUp.loosening(current: current, proposed: proposed, now: instant)
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
                if wait.expired(wall: instant) {
                    runUpWaits[current.id] = StopRequest(reason: .cancel, minutes: current.stopDelayMinutes, wall: instant)
                    runUpWaitsNotified.remove(current.id)
                    notice = "\(lead) La ventana de confirmación anterior caducó. Nueva espera de \(current.stopDelayMinutes) min iniciada."
                    return false
                }
                guard wait.ready(wall: instant) else {
                    notice = "\(lead) Faltan \(FocusRules.clock(wait.remaining(wall: instant))) de la espera que pediste; al cumplirse, vuelve a hacerlo."
                    return false
                }
                runUpWaits[current.id] = nil
                runUpWaitsNotified.remove(current.id)
                return true
            }
            runUpWaits[current.id] = StopRequest(reason: .cancel, minutes: current.stopDelayMinutes, wall: instant)
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
        for (taskID, wait) in Array(runUpWaits) {
            if wait.expired() {
                runUpWaits[taskID] = nil
                runUpWaitsNotified.remove(taskID)
                if let task = workspace.tasks.first(where: { $0.id == taskID }) {
                    notice = "La ventana para confirmar el cambio en «\(task.title)» ha caducado: sigue protegida."
                }
                continue
            }
            guard wait.ready(), !runUpWaitsNotified.contains(taskID) else { continue }
            runUpWaitsNotified.insert(taskID)
            guard let task = workspace.tasks.first(where: { $0.id == taskID }) else { continue }
            let windowClock = FocusRules.clock(wait.confirmWindowRemaining())
            notice = "La espera ha terminado: tienes \(windowClock) para cambiar «\(task.title)» antes de que vuelva a protegerse."
            if !preview {
                reminders.notify(
                    "Ya puedes cambiar «\(task.title)»",
                    body: "La espera ha terminado. Tienes \(windowClock) para confirmar el cambio en FocusDesk.",
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

    /// Puts the code on screen. The task or rule editor is closed first: two sheets cannot share the window, and a code
    /// that never appears would leave the user without a visible way out.
    func presentStopChallenge(_ challenge: PendingStopChallenge) {
        guard editingTask != nil || editingGeneralRule != nil else {
            pendingStop = challenge
            showWindow?()
            return
        }
        editingTask = nil
        editingGeneralRule = nil
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
            let length = challenge.emergency
                ? 60
                : (challenge.generalRule?.rule.unlockChars ?? challenge.runUp?.task.unlockChars ?? session?.task.unlockChars ?? 24)
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
        let nowInstant = Date()
        let dayKey = FocusRules.dayKey(for: nowInstant, rolloverHour: workspace.settings.dayRolloverHour)
        if let ruleChange = challenge.generalRule {
            if wasEmergency { workspace.settings.emergencyUses.append(dayKey) }
            workspace.recordAudit(
                category: wasEmergency ? "Emergencia (regla)" : "Desbloqueo (regla)",
                summary: "«\(ruleChange.rule.name)» · \(challenge.generalRuleAction)",
                at: nowInstant
            )
            applyPaidGeneralRuleChange(ruleChange)
            if wasEmergency { notice = "Salida de emergencia usada para «\(ruleChange.rule.name)». Queda anotada." }
            if shouldQuit { NSApp.terminate(nil) }
            return
        }
        if let change = challenge.runUp {
            if wasEmergency { workspace.settings.emergencyUses.append(dayKey) }
            workspace.recordAudit(
                category: wasEmergency ? "Emergencia (pre-tarea)" : "Desbloqueo (pre-tarea)",
                summary: "«\(change.task.title)» · \(challenge.runUpAction)",
                at: nowInstant
            )
            applyPaidRunUpChange(change)
            if wasEmergency { notice = "Salida de emergencia usada para «\(change.task.title)». Queda anotada." }
            return
        }
        if wasEmergency {
            workspace.settings.emergencyUses.append(dayKey)
            notice = "Salida de emergencia usada. Queda anotada en el historial de la sesión."
        }
        if let s = session {
            workspace.recordAudit(
                category: wasEmergency ? "Emergencia (sesión)" : "Desbloqueo (sesión)",
                summary: "«\(s.task.title)» · \(reason.verb)",
                at: nowInstant
            )
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

    /// Answers whether FocusDesk may quit now. Quitting with a protected session or active protected general rule
    /// running is the same escape as pausing it, so it costs the same: the code, or the wait.
    /// A restart, a shutdown or a log-out always goes through: refusing one is how somebody ends up holding the
    /// power button and losing what is open in every other app. The session comes back at the next launch.
    /// The demo mode (`--preview`) always lets go: trying out a locked session must not trap anyone in a demo.
    func canQuitNow(systemQuit: Bool = false) -> Bool {
        // Set on every request: a restart that another app called off must not mark a later ordinary quit.
        quittingForSystem = systemQuit
        if systemQuit { return true }
        guard !preview else { return true }
        if let s = session, s.enforcing(at: now, uptime: uptime), s.task.protection != .none {
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
        if let rule = activeProtectedGeneralRule {
            var disabled = rule
            disabled.enabled = false
            return passesGeneralRuleGate(.save(disabled), quitAfter: true)
        }
        return true
    }

    func dismissStopChallenge() {
        let generalRule = pendingStop?.generalRule
        let runUp = pendingStop?.runUp
        pendingStop = nil
        if let generalRule {
            notice = "«\(generalRule.rule.name)» sigue activa como estaba."
            return
        }
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
        guard let s = session, let request = s.stopRequest else { return }
        if request.expired() {
            workspace.session?.stopRequest = nil
            stopReadyNotified = false
            _ = persist()
            notice = "La ventana de confirmación para \(request.reason.verb) «\(s.task.title)» ha caducado: la sesión sigue protegida."
            return
        }
        guard !stopReadyNotified, request.ready() else { return }
        stopReadyNotified = true
        let windowClock = FocusRules.clock(request.confirmWindowRemaining())
        notice = "Ya puedes \(request.reason.verb) «\(s.task.title)» (tienes \(windowClock) para confirmarlo). Si has cambiado de idea, sigue trabajando."
        if !preview {
            reminders.notify(
                "Puedes \(request.reason.verb) · \(s.task.title)",
                body: "La espera ha terminado. Tienes \(windowClock) para volver a pulsarlo en FocusDesk si sigues queriendo.",
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

        // In blacklist mode (`appListMode == .blockListed`), only the listed apps are blocked and the rest of the
        // Mac stays open, so we never need to launch an allowed app or pause the session when none is running.
        if s.task.appListMode == .blockListed {
            let punisherJustFired = workspace.session?.registerBlock() ?? false
            let verb = applyBlockAction(to: distracting, bundleID: id)
            let fallback = lastAllowed.flatMap { candidate in
                (candidate.isTerminated || s.task.apps.contains(where: { $0.id == candidate.bundleIdentifier })) ? nil : candidate
            } ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            _ = fallback?.activate(options: [])
            if punisherJustFired, let message = punisherMessage(for: s) {
                notice = message
            } else {
                notice = "\(distractingName) está en la lista negra de «\(s.task.title)»: \(verb)."
            }
            if isNewInterruption, !preview { notifyDistraction(notice ?? "", session: s) }
            scheduleStrictRecheck(after: 0.8)
            return false
        }

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
    private func applyBlockAction(to app: NSRunningApplication, bundleID id: String, action: AppBlockAction? = nil) -> String {
        let resolved = action ?? (workspace.session?.activeBlockAction() ?? .hide)
        switch FocusRules.safeAction(resolved, for: id) {
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
        guard workspace.settings.watchBackgroundWindows,
              Date().timeIntervalSince(lastBackgroundSweepAt) >= 6 else { return }
        let sessionStrict = (session?.enforcing(at: now, uptime: uptime) == true && session?.task.strict == true && !(session?.task.apps.isEmpty ?? true))
        let activeAppRules = enforcingGeneralRules.filter { $0.blockApps && !$0.apps.isEmpty }
        guard sessionStrict || !activeAppRules.isEmpty else { return }
        lastBackgroundSweepAt = Date()
        var exempt = FocusRules.systemExemptBundleIDs
        if let ownID = Bundle.main.bundleIdentifier { exempt.insert(ownID) }
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let frontID { exempt.insert(frontID) }   // the app in front is handled by `observe`

        let visibleApps = ScreenWindows.visibleUnallowedApps(allowedBundleIDs: [], exempt: exempt)
        let offenders = visibleApps.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            if let s = session, sessionStrict {
                if !FocusRules.appAllowed(bundleID: id, apps: s.task.apps, mode: s.task.appListMode) {
                    return true
                }
            }
            for rule in activeAppRules {
                if !FocusRules.appAllowed(bundleID: id, apps: rule.apps, mode: rule.appListMode) {
                    return true
                }
            }
            return false
        }
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
            case .page(let host, let path):
                let display = path.isEmpty || path == "/" ? host : "\(host)\(path)"
                self.braveStatus = "\(browserName): \(display)"
                self.lastObservedBrowserPage[bundleID] = (host: host, path: path, at: Date())
                self.handleVisit(host: host, path: path, bundleID: bundleID, browserName: browserName, session: current)
                self.evaluateGeneralRulesOnWeb(host: host, path: path, bundleID: bundleID, browserName: browserName)
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

    /// One visit to one host/path: recorded once, and blocked once if the task says so.
    func handleVisit(host: String, path: String = "", bundleID: String, browserName: String, session s: WorkSession) {
        if workspace.isTemporarilyAllowed(host: host, path: path, at: Date()) {
            domainEpisodeHost = nil
            return
        }
        let searchMediaHit = s.task.blockSearchMedia ? SearchMediaRules.matches(host: host, pathAndQuery: path) : nil
        let outside = searchMediaHit != nil || !FocusRules.webAllowed(host: host, path: path, list: s.task.domains, mode: s.task.webListMode)
        let visitKey = path.isEmpty || path == "/" ? host : "\(host)\(path)"
        let changed = workspace.session?.activities.last?.domain != host
        let newVisit = outside && domainEpisodeHost != visitKey
        if changed {
            workspace.session?.record(
                Activity(appID: bundleID, name: browserName, domain: host, interruption: newVisit),
                at: Date(),
                uptime: uptime
            )
        }
        domainEpisodeHost = outside ? visitKey : nil
        guard outside else { return }

        let effectiveWebAction: WebBlockAction = (searchMediaHit != nil && s.task.webBlockAction == .warn) ? .redirect : s.task.webBlockAction
        switch effectiveWebAction {
        case .warn:
            if newVisit {
                notice = "\(visitKey) no está permitido en esta tarea. El control de webs es informativo."
                if !preview { notifyDistraction(notice ?? "", session: s) }
            }
        case .redirect, .closeTab:
            // One action per visit while the browser is still changing the tab. Seen again a few seconds later —
            // Back from the blocked page, a reopened tab — it is blocked again: remembering the host for the whole
            // visit let Back walk straight past the block. (FocusDesk's own page is a file, never read as a host.)
            if lastWebBlockHost == visitKey, Date().timeIntervalSince(lastWebBlockAt) < 4 { return }
            lastWebBlockHost = visitKey
            lastWebBlockAt = Date()
            let punisherJustFired = workspace.session?.registerBlock() ?? false
            let hardened = punisherJustFired || (workspace.session?.punisher.isActive() ?? false)
            let action: WebBlockAction = hardened && effectiveWebAction == .redirect ? .closeTab : effectiveWebAction
            if action == .closeTab {
                webInspector.closeActiveTab(bundleID: bundleID) { [weak self] ok in
                    guard let self else { return }
                    if ok, punisherJustFired, let message = self.punisherMessage(for: s) {
                        self.notice = message
                    } else {
                        self.notice = ok
                            ? "\(visitKey) está bloqueada en esta tarea: he cerrado esa pestaña. El resto del navegador sigue como estaba."
                            : "\(visitKey) está bloqueada en esta tarea, pero no pude cerrar la pestaña. Revisa el permiso de Automatización."
                    }
                    if !self.preview { self.notifyDistraction(self.notice ?? "", session: s) }
                }
            } else {
                let remaining = currentRemaining(for: s)
                let allowedList = s.task.webListMode == .allowListed ? FocusRules.parseDomains(s.task.domains).valid : []
                let pendingSteps = s.task.checklist
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !s.checked.contains($0) }
                let targetURL: URL
                if let custom = WebRules.normalizedRedirectURL(s.task.customRedirectURL) {
                    targetURL = custom
                } else if let page = BlockPage.write(
                    taskTitle: s.task.title,
                    host: visitKey,
                    remaining: remaining,
                    endsAt: Date().addingTimeInterval(max(0, remaining)),
                    allowedDomains: allowedList,
                    motivationalMessage: s.task.motivationalMessage,
                    checklistSteps: pendingSteps,
                    in: store.url.deletingLastPathComponent()
                ) {
                    targetURL = page
                } else {
                    notice = "\(visitKey) está bloqueada en esta tarea, pero no se pudo preparar la página de bloqueo."
                    return
                }
                webInspector.redirectActiveTab(bundleID: bundleID, to: targetURL) { [weak self] ok in
                    guard let self else { return }
                    self.notice = ok
                        ? "\(visitKey) está bloqueada en esta tarea: esa pestaña va a la página de bloqueo. Las demás siguen abiertas."
                        : "\(visitKey) está bloqueada en esta tarea, pero no pude cambiar la pestaña. Revisa el permiso de Automatización."
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
        let blocked = hosts.filter { !FocusRules.webAllowed(host: $0, path: "", list: s.task.domains, mode: s.task.webListMode) }
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

    /// Writes the fingerprint of the running protected session (or active protected general rule) into the Keychain, outside `workspace.json`.
    func refreshWitness() {
        guard !preview else { return }
        let protectedRules = workspace.generalRules.filter { $0.enabled && $0.protection != .none }
        if !protectedRules.isEmpty {
            KeychainWitness.saveRulesWitness(ProtectedRulesWitness(rules: protectedRules, savedAt: now))
        } else {
            KeychainWitness.clearRulesWitness()
        }

        if let s = session, s.enforcing(at: now, uptime: uptime), s.task.protection != .none {
            KeychainWitness.save(
                SessionWitness(
                    sessionID: s.id,
                    taskTitle: s.task.title,
                    protection: s.task.protection,
                    deadline: s.witnessDeadline(at: now, uptime: uptime)
                )
            )
            return
        }
        if let rule = activeProtectedGeneralRule {
            let left = remainingRuleLockSeconds(rule, at: now)
            KeychainWitness.save(
                SessionWitness(
                    sessionID: rule.id,
                    taskTitle: rule.name,
                    protection: rule.protection,
                    deadline: TrustedDeadline(seconds: max(60, left), wall: now)
                )
            )
            return
        }
        KeychainWitness.clear()
    }

    /// At launch: a witness for a protected session or protected general rules that the data file no longer knows
    /// about means the file was edited, replaced or deleted while FocusDesk was closed.
    func checkWitnessAtLaunch() {
        guard !preview else { return }
        if let rulesWitness = KeychainWitness.loadRulesWitness(), rulesWitness.intact {
            var restoredNames: [String] = []
            let launchNow = Date()
            for witnessedRule in rulesWitness.rules where isRuleProtected(witnessedRule, at: launchNow) {
                if let idx = workspace.generalRules.firstIndex(where: { $0.id == witnessedRule.id }) {
                    if GeneralBlockRule.loosening(current: witnessedRule, proposed: workspace.generalRules[idx], now: launchNow) != nil {
                        workspace.generalRules[idx] = witnessedRule
                        restoredNames.append("«\(witnessedRule.name)»")
                    }
                } else {
                    workspace.generalRules.append(witnessedRule)
                    restoredNames.append("«\(witnessedRule.name)»")
                }
            }
            if !restoredNames.isEmpty {
                _ = persist()
                notice = "Se \(restoredNames.count == 1 ? "ha restaurado la regla protegida" : "han restaurado las reglas protegidas") \(restoredNames.joined(separator: ", ")) desde el testigo de seguridad del Llavero."
            }
        }

        guard let witness = KeychainWitness.load() else { return }
        guard witness.live() else { KeychainWitness.clear(); return }
        if let s = session, s.id == witness.sessionID { return }
        if workspace.generalRules.contains(where: { $0.id == witness.sessionID && $0.enabled }) { return }
        let left = FocusRules.clock(witness.remaining())
        error = """
        «\(witness.taskTitle)» estaba protegida hasta dentro de \(left) y ya no aparece en tus datos. Si has \
        cambiado o borrado el archivo de FocusDesk, esa sesión se perdió: vuelve a empezarla si de verdad querías \
        trabajar en ella. Este aviso es todo lo que una app sin permisos de administrador puede hacer.
        """
        KeychainWitness.clear()
    }

    // MARK: - General block rules, daily usage timers, work goals, launch limits & active breaks

    func usedSecondsToday(for rule: GeneralBlockRule, at instant: Date? = nil) -> TimeInterval {
        workspace.usedSecondsToday(
            for: rule.id,
            periodUnit: rule.limitPeriodUnit,
            at: instant ?? now
        )
    }

    func launchesToday(for rule: GeneralBlockRule, at instant: Date? = nil) -> Int {
        workspace.launchesToday(
            for: rule.id,
            at: instant ?? now
        )
    }

    func matchesToday(for rule: GeneralBlockRule, at instant: Date? = nil) -> Int {
        workspace.matchesToday(
            for: rule.id,
            at: instant ?? now
        )
    }

    /// Returns verified active study seconds (passive + active with an open study window/tab and real user interaction)
    /// when `rule.verifyActiveStudy` is enabled, or task session seconds otherwise.
    func effectiveWorkedSeconds(for rule: GeneralBlockRule, at instant: Date? = nil) -> TimeInterval {
        let ref = instant ?? now
        if rule.verifyActiveStudy {
            return workspace.verifiedStudySecondsToday(at: ref)
        }
        return workedSeconds(on: ref)
    }

    /// True while the League of Legends in-game match binary (`com.riotgames.LeagueofLegends.GameClient` / `Game/LeagueofLegends.app`) is running.
    var isLoLMatchCurrentlyInProgress: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated else { return false }
            return LeagueMatchRules.isMatchGameProcess(
                bundleID: app.bundleIdentifier,
                appPath: app.bundleURL?.path,
                executablePath: app.executableURL?.path
            )
        }
    }

    func isMatchInProgress(for rule: GeneralBlockRule) -> Bool {
        guard rule.deferBlockUntilMatchEnds, LeagueMatchRules.ruleTargetsLeague(rule) else { return false }
        return isLoLMatchCurrentlyInProgress
    }

    func remainingRuleLockSeconds(_ rule: GeneralBlockRule, at instant: Date? = nil) -> TimeInterval {
        let ref = instant ?? now
        return rule.remainingLockSeconds(
            at: ref,
            usedTodaySeconds: usedSecondsToday(for: rule, at: ref),
            workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: ref),
            launchesToday: launchesToday(for: rule, at: ref),
            matchesToday: matchesToday(for: rule, at: ref),
            isMatchInProgress: isMatchInProgress(for: rule)
        )
    }

    func isRuleEnforcing(_ rule: GeneralBlockRule, at instant: Date? = nil) -> Bool {
        let ref = instant ?? now
        return rule.isEnforcing(
            at: ref,
            usedTodaySeconds: usedSecondsToday(for: rule, at: ref),
            workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: ref),
            launchesToday: launchesToday(for: rule, at: ref),
            matchesToday: matchesToday(for: rule, at: ref),
            isMatchInProgress: isMatchInProgress(for: rule)
        )
    }

    func isRuleProtected(_ rule: GeneralBlockRule, at instant: Date? = nil) -> Bool {
        let ref = instant ?? now
        return rule.isProtectedNow(
            at: ref,
            usedTodaySeconds: usedSecondsToday(for: rule, at: ref),
            workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: ref),
            launchesToday: launchesToday(for: rule, at: ref),
            matchesToday: matchesToday(for: rule, at: ref),
            isMatchInProgress: isMatchInProgress(for: rule)
        )
    }

    func isRuleTrackingQuota(_ rule: GeneralBlockRule, at instant: Date? = nil) -> Bool {
        let ref = instant ?? now
        return rule.isTrackingQuota(
            at: ref,
            usedTodaySeconds: usedSecondsToday(for: rule, at: ref),
            workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: ref),
            launchesToday: launchesToday(for: rule, at: ref),
            matchesToday: matchesToday(for: rule, at: ref),
            isMatchInProgress: isMatchInProgress(for: rule)
        )
    }

    /// Terminates all running League of Legends and Riot Client processes (when not inside an active match).
    @discardableResult
    func terminateAllLeagueAndRiotProcesses(for rule: GeneralBlockRule, reasonMessage: String? = nil) -> Bool {
        if rule.deferBlockUntilMatchEnds && isLoLMatchCurrentlyInProgress && effectiveWorkedSeconds(for: rule, at: Date()) >= rule.goalRequiredSeconds {
            // Never close an active match once study goal was met.
            return false
        }
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated else { return false }
            return LeagueMatchRules.isLeagueOrRiotProcess(
                bundleID: app.bundleIdentifier,
                appPath: app.bundleURL?.path,
                localizedName: app.localizedName
            )
        }
        guard !running.isEmpty else { return false }
        for app in running {
            if !app.terminate() {
                app.forceTerminate()
            } else {
                // LeagueClientUx and RiotClient often ignore gentle terminate; forceTerminate after a short grace if needed.
                app.forceTerminate()
            }
        }
        if let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           LeagueMatchRules.isLeagueOrRiotProcess(bundleID: frontID) {
            activateFallbackApp(excluding: frontID)
        }
        if let reasonMessage {
            notice = reasonMessage
        }
        return true
    }

    /// Credits passive + active verified study time every second while the user is interacting with a real study/work window or productive browser tab.
    func tickPassiveStudyTracking(at instant: Date) {
        guard writable, !screenIsLocked,
              workspace.generalRules.contains(where: { $0.enabled && $0.kind == .workGoal && $0.verifyActiveStudy }) else {
            lastPassiveStudyTickAt = nil
            return
        }
        let delta: TimeInterval
        if let prev = lastPassiveStudyTickAt {
            delta = min(3, max(0, instant.timeIntervalSince(prev)))
        } else {
            delta = 1.0
        }
        lastPassiveStudyTickAt = instant
        guard delta > 0,
              let frontApp = NSWorkspace.shared.frontmostApplication,
              let id = frontApp.bundleIdentifier else { return }

        let idleSeconds = MacActivity.idleSeconds()
        let hasVisibleWindow = ScreenWindows.hasOpenWindow(for: frontApp)
        let title = (lastTitleAppID == id) ? lastTitle.title : nil
        let observedPage = WebRules.isBrowser(id) ? lastObservedBrowserPage[id] : nil
        let recentPage = (observedPage != nil && instant.timeIntervalSince(observedPage!.at) <= 25) ? observedPage : nil

        guard StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: idleSeconds,
            frontBundleID: id,
            frontAppPath: frontApp.bundleURL?.path,
            hasVisibleWindowOnScreen: hasVisibleWindow,
            frontWindowTitle: title,
            browserHost: recentPage?.host,
            browserPath: recentPage?.path
        ) else { return }

        let rollover = workspace.settings.dayRolloverHour
        let day = FocusRules.dayKey(for: instant, rolloverHour: rollover)
        let prevStudy = workspace.verifiedStudySecondsToday(at: instant)
        let newStudy = workspace.addVerifiedStudySeconds(delta, at: instant)

        for rule in workspace.generalRules where rule.enabled && rule.kind == .workGoal && rule.verifyActiveStudy {
            let unlockKey = "\(day)-\(rule.id.uuidString)-unlocked"
            if prevStudy < rule.goalRequiredSeconds && newStudy >= rule.goalRequiredSeconds && !studyGoalUnlockedNotifiedToday.contains(unlockKey) {
                studyGoalUnlockedNotifiedToday.insert(unlockKey)
                _ = persist()
                refreshWitness()
                let matchInfo = rule.maxDailyMatches > 0 ? " (máx. \(rule.maxDailyMatches) partidas hoy, sin cortes a mitad)" : ""
                let msg = "¡Meta de \(rule.goalMinutesRequired) min de estudio activo completada! Ya tienes desbloqueado «\(rule.name)»\(matchInfo)."
                notice = msg
                if !preview {
                    reminders.notify("Estudio completado · \(rule.name)", body: msg, identifier: "study-ok-" + rule.id.uuidString)
                }
            }
        }
    }

    /// Tracks the League of Legends in-game match lifecycle (`GameClient`), triggers the 1-minute post-match grace countdown
    /// when the 2nd match (or time budget) ends, and closes all League / Riot processes once the grace period finishes.
    func tickLeagueMatchAndPostMatchGrace(at instant: Date) {
        guard writable, !screenIsLocked else { return }
        let continuousNow = TrustedClock.continuousSeconds()
        let matchRunning = isLoLMatchCurrentlyInProgress

        // 1. Check if a match just started or just ended.
        if matchRunning {
            if activeLoLMatchStartedContinuous == nil {
                // Verify whether the user is allowed to be in a match (study goal completed).
                let blockedBeforeGoal = workspace.generalRules.first { rule in
                    rule.enabled && LeagueMatchRules.ruleTargetsLeague(rule)
                        && rule.kind == .workGoal
                        && effectiveWorkedSeconds(for: rule, at: instant) < rule.goalRequiredSeconds
                }
                if let rule = blockedBeforeGoal {
                    let studiedMin = Int(effectiveWorkedSeconds(for: rule, at: instant) / 60)
                    _ = terminateAllLeagueAndRiotProcesses(
                        for: rule,
                        reasonMessage: "League of Legends está bloqueado hasta completar \(rule.goalMinutesRequired) min de estudio activo hoy (llevas \(studiedMin) min)."
                    )
                } else {
                    activeLoLMatchStartedAt = instant
                    activeLoLMatchStartedContinuous = continuousNow
                    if let rule = workspace.generalRules.first(where: { $0.enabled && LeagueMatchRules.ruleTargetsLeague($0) && $0.maxDailyMatches > 0 }) {
                        let currentMatchNum = min(rule.maxDailyMatches, matchesToday(for: rule, at: instant) + 1)
                        notice = "Partida \(currentMatchNum)/\(rule.maxDailyMatches) de League of Legends en curso · FocusDesk no te sacará a mitad de partida."
                    }
                }
            }
        } else if let startedContinuous = activeLoLMatchStartedContinuous {
            // The in-game `GameClient` process just exited back to the lobby!
            let matchDuration = max(0, continuousNow - startedContinuous)
            activeLoLMatchStartedAt = nil
            activeLoLMatchStartedContinuous = nil

            for idx in workspace.generalRules.indices {
                let rule = workspace.generalRules[idx]
                guard rule.enabled, LeagueMatchRules.ruleTargetsLeague(rule) else { continue }
                let used = usedSecondsToday(for: rule, at: instant)
                let worked = effectiveWorkedSeconds(for: rule, at: instant)
                let timeBudgetExhausted: Bool = {
                    if rule.kind == .workGoal, let budget = rule.earnedGoalBudgetSeconds(workedTodaySeconds: worked), budget > 0 {
                        return used >= budget
                    }
                    if rule.kind == .dailyLimit {
                        return used >= rule.dailyBudgetSeconds
                    }
                    return false
                }()
                let shouldCountMatch = matchDuration >= LeagueMatchRules.minCountedMatchDurationSeconds || timeBudgetExhausted
                guard shouldCountMatch else { continue }

                let newMatches = workspace.incrementMatches(for: rule.id, at: instant)
                let matchLimitReached = rule.maxDailyMatches > 0 && newMatches >= rule.maxDailyMatches

                if matchLimitReached || timeBudgetExhausted {
                    workspace.generalRules[idx].startPostMatchGrace(wall: instant, continuous: continuousNow)
                    postMatchGraceArmedRules.insert(rule.id)
                    let graceSec = workspace.generalRules[idx].postMatchGraceSeconds
                    workspace.recordAudit(
                        category: "Límite de partidas alcanzado",
                        summary: "«\(rule.name)» · Partida \(newMatches)/\(max(1, rule.maxDailyMatches)) terminada · Margen de \(graceSec)s iniciado",
                        at: instant
                    )
                    _ = persist()
                    refreshWitness()
                    let graceText = graceSec == 60 ? "1 minuto" : "\(graceSec) segundos"
                    let msg = "Partida \(newMatches)/\(max(1, rule.maxDailyMatches)) terminada. Tienes \(graceText) de margen para dar honor y ver estadísticas antes de que se cierre League of Legends por hoy."
                    notice = msg
                    if !preview {
                        reminders.notify(
                            "Último minuto en LoL · Partida \(newMatches)/\(max(1, rule.maxDailyMatches))",
                            body: msg,
                            identifier: "lol-grace-" + rule.id.uuidString
                        )
                    }
                } else {
                    _ = persist()
                    if rule.maxDailyMatches > 0 {
                        let leftMatches = max(0, rule.maxDailyMatches - newMatches)
                        let msg = "Partida \(newMatches)/\(rule.maxDailyMatches) completada hoy. Te \(leftMatches == 1 ? "queda 1 partida disponible" : "quedan \(leftMatches) partidas disponibles") hoy."
                        notice = msg
                        if !preview {
                            reminders.notify(
                                "Partida \(newMatches)/\(rule.maxDailyMatches) terminada",
                                body: msg,
                                identifier: "lol-match-" + rule.id.uuidString
                            )
                        }
                    }
                }
            }
        }

        // 2. Check if any armed 1-minute post-match grace countdown just finished, or if League is running while blocked.
        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, LeagueMatchRules.ruleTargetsLeague(rule) else { continue }
            if rule.isInPostMatchGrace(at: instant, continuous: continuousNow) {
                postMatchGraceArmedRules.insert(rule.id)
                continue
            }
            if postMatchGraceArmedRules.contains(rule.id) {
                postMatchGraceArmedRules.remove(rule.id)
                workspace.generalRules[idx].activePostMatchGraceDeadline = nil
                _ = persist()
                refreshWitness()
                let msg = "Margen de 1 minuto finalizado tras la partida \(matchesToday(for: rule, at: instant))/\(max(1, rule.maxDailyMatches)). FocusDesk ha cerrado League of Legends por hoy."
                _ = terminateAllLeagueAndRiotProcesses(for: workspace.generalRules[idx], reasonMessage: msg)
                if !preview {
                    reminders.notify(
                        "League of Legends cerrado por hoy",
                        body: msg,
                        identifier: "lol-closed-" + rule.id.uuidString
                    )
                }
                continue
            }
            if !matchRunning && isRuleEnforcing(rule, at: instant) {
                let worked = effectiveWorkedSeconds(for: rule, at: instant)
                let msg: String
                if rule.kind == .workGoal && worked < rule.goalRequiredSeconds {
                    let leftMin = max(1, Int(ceil((rule.goalRequiredSeconds - worked) / 60)))
                    msg = "League of Legends está bloqueado: te faltan \(leftMin) min de estudio activo verificado hoy (con ventana o pestaña abierta)."
                } else {
                    msg = "League of Legends está bloqueado por hoy (\(matchesToday(for: rule, at: instant))/\(max(1, rule.maxDailyMatches)) partidas completadas)."
                }
                _ = terminateAllLeagueAndRiotProcesses(for: rule, reasonMessage: msg)
            }
        }
    }

    var enforcingGeneralRules: [GeneralBlockRule] {
        let ref = now
        return workspace.generalRules.filter { isRuleEnforcing($0, at: ref) }
    }

    var trackingGeneralRules: [GeneralBlockRule] {
        let ref = now
        return workspace.generalRules.filter { isRuleTrackingQuota($0, at: ref) }
    }

    // MARK: - Micro-pauses & temporary exceptions with auto-expiry

    func remainingMicroPausesToday(for rule: GeneralBlockRule, at instant: Date? = nil) -> Int {
        let ref = instant ?? now
        guard rule.dailyMicroPausesAllowed > 0 else { return 0 }
        return max(0, rule.dailyMicroPausesAllowed - workspace.microPausesUsedToday(for: rule.id, at: ref))
    }

    func canStartMicroPause(for rule: GeneralBlockRule, at instant: Date? = nil) -> Bool {
        let ref = instant ?? now
        guard rule.enabled, rule.dailyMicroPausesAllowed > 0, !rule.isMicroPaused(at: ref) else { return false }
        return remainingMicroPausesToday(for: rule, at: ref) > 0 && isRuleEnforcing(rule, at: ref)
    }

    func startMicroPause(for rule: GeneralBlockRule) {
        guard writable else { return }
        let ref = Date()
        guard canStartMicroPause(for: rule, at: ref),
              let idx = workspace.generalRules.firstIndex(where: { $0.id == rule.id }) else {
            notice = "No quedan micro-pausas disponibles hoy para «\(rule.name)»."
            return
        }
        workspace.generalRules[idx].startMicroPause(wall: ref)
        let used = workspace.incrementMicroPauses(for: rule.id, at: ref)
        let left = max(0, rule.dailyMicroPausesAllowed - used)
        workspace.recordAudit(
            category: "Micro-pausa",
            summary: "«\(rule.name)» · \(rule.microPauseMinutes) min (\(used)/\(rule.dailyMicroPausesAllowed))",
            at: ref
        )
        _ = persist()
        updateFloatingPill(at: ref)
        notice = "Micro-pausa de \(rule.microPauseMinutes) min activada en «\(rule.name)». Te \(left == 1 ? "queda 1 pausa" : "quedan \(left) pausas") hoy."
    }

    func endLaunchVisitEarly(for rule: GeneralBlockRule) {
        guard writable, let idx = workspace.generalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        let ref = Date()
        guard workspace.generalRules[idx].isLaunchVisitActive(at: ref) else { return }
        workspace.generalRules[idx].endLaunchVisitAndStartCooldown(wall: ref)
        _ = persist()
        observe()
        let cd = workspace.generalRules[idx].launchCooldownMinutes
        notice = cd > 0
            ? "Visita cerrada en «\(rule.name)». Enfriamiento de \(cd) min activado."
            : "Visita cerrada en «\(rule.name)»."
    }

    func activeTemporaryAllows(at instant: Date? = nil) -> [TemporaryAllowEntry] {
        let ref = instant ?? now
        return workspace.temporaryAllows.filter { $0.isActive(wall: ref) }
    }

    func addTemporaryAllow(target: String, isAppBundleID: Bool, label: String = "", minutes: Int) {
        guard writable else { return }
        guard !refuseWhileProtected("añadir una excepción temporal sin desbloquear la sesión o regla protegida") else { return }
        let raw = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if !isAppBundleID, let why = FocusRules.isAllowEntryTooBroad(raw) {
            error = why
            return
        }
        let normalizedTarget: String
        if isAppBundleID {
            normalizedTarget = raw
        } else {
            let parsed = FocusRules.parseDomains(raw).valid
            guard let first = parsed.first else {
                error = "Escribe un dominio válido (por ejemplo, docs.swift.org o youtube.com/watch)."
                return
            }
            normalizedTarget = first
            if let s = session, s.task.webListMode == .blockListed, s.task.similarityProtection != .off,
               let warn = FocusRules.checkSimilarityRestriction(
                   allowCandidate: normalizedTarget,
                   blockedDomains: s.task.domains,
                   level: s.task.similarityProtection
               ) {
                error = warn
                return
            }
            for rule in workspace.generalRules where rule.enabled && rule.webListMode == .blockListed && rule.similarityProtection != .off {
                if let warn = FocusRules.checkSimilarityRestriction(
                    allowCandidate: normalizedTarget,
                    blockedDomains: rule.domains,
                    level: rule.similarityProtection
                ) {
                    error = warn
                    return
                }
            }
        }
        let nowInstant = Date()
        workspace.pruneExpiredTemporaryAllows(at: nowInstant)
        workspace.temporaryAllows.removeAll { $0.target.lowercased() == normalizedTarget.lowercased() && $0.isAppBundleID == isAppBundleID }
        let clamped = max(1, min(240, minutes))
        let entry = TemporaryAllowEntry(
            target: normalizedTarget,
            isAppBundleID: isAppBundleID,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            minutes: clamped,
            wall: nowInstant
        )
        workspace.temporaryAllows.insert(entry, at: 0)
        workspace.recordAudit(
            category: "Excepción temporal",
            summary: "«\(entry.label.isEmpty ? normalizedTarget : entry.label)» · \(clamped) min",
            at: nowInstant
        )
        error = nil
        _ = persist()
        notice = "Excepción temporal activa durante \(clamped) min para «\(entry.label.isEmpty ? normalizedTarget : entry.label)». Al agotarse volverá a bloquearse solo."
    }

    func removeTemporaryAllow(_ id: UUID) {
        guard writable else { return }
        workspace.temporaryAllows.removeAll { $0.id == id }
        _ = persist()
        observe()
        notice = "Excepción temporal cerrada: el bloqueo vuelve a aplicarse."
    }

    // MARK: - Scheduled breaks & Continuous Screen-Time Breaks (tickAsScreenBreak)

    /// Active scheduled break from `workspace.settings.breaks` when `settings.enforceBreaks` is on and not dismissed.
    func activeBreak(at instant: Date? = nil) -> (period: BreakPeriod, remaining: TimeInterval)? {
        guard workspace.settings.enforceBreaks else { return nil }
        let ref = instant ?? now
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: ref)
        guard workspace.settings.workdays.isEmpty || workspace.settings.workdays.contains(weekday) else { return nil }
        let day = FocusRules.dayKey(for: ref, calendar: cal)
        for period in workspace.settings.breaks where period.isActive(at: ref, calendar: cal) {
            let key = "\(day)-\(period.id.uuidString)-\(period.startHour):\(period.startMinute)"
            if dismissedBreakKey == key { continue }
            return (period, period.remainingSeconds(at: ref, calendar: cal))
        }
        return nil
    }

    func dismissActiveBreak(_ period: BreakPeriod) {
        let day = FocusRules.dayKey(for: now)
        dismissedBreakKey = "\(day)-\(period.id.uuidString)-\(period.startHour):\(period.startMinute)"
    }

    /// Active continuous screen-work rest break, if triggered.
    func activeContinuousBreak(at instant: Date? = nil) -> (remaining: TimeInterval, message: String, skipsRemaining: Int)? {
        guard workspace.settings.continuousBreakEnabled,
              let deadline = activeContinuousBreakDeadline else { return nil }
        let ref = instant ?? now
        let rem = deadline.remainingAfterPossibleReboot(wall: ref)
        guard rem > 0 else { return nil }
        let skipsLeft = max(0, workspace.settings.continuousBreakMaxSkipsPerDay - workspace.continuousBreakSkipsToday(at: ref))
        let msg = activeContinuousBreakMessage.isEmpty
            ? (workspace.settings.breakMessages.first ?? "Descansa la vista y estira los hombros.")
            : activeContinuousBreakMessage
        return (rem, msg, skipsLeft)
    }

    func tickContinuousBreak(at instant: Date) {
        guard workspace.settings.continuousBreakEnabled, !screenIsLocked else {
            if !workspace.settings.continuousBreakEnabled {
                continuousActiveWorkSeconds = 0
                activeContinuousBreakDeadline = nil
            }
            return
        }
        if let deadline = activeContinuousBreakDeadline {
            if deadline.remainingAfterPossibleReboot(wall: instant) <= 0 {
                activeContinuousBreakDeadline = nil
                continuousActiveWorkSeconds = 0
                notice = "Descanso por uso continuo completado. Puedes seguir con tu trabajo."
            }
            return
        }
        // Query HID idle time so natural pauses away from the keyboard/mouse reset the continuous screen counter.
        let idleSeconds = MacActivity.idleSeconds()
        if idleSeconds >= 180 {
            continuousActiveWorkSeconds = max(0, continuousActiveWorkSeconds - 3)
            return
        }
        guard idleSeconds < 45 else { return }
        continuousActiveWorkSeconds += 1
        let thresholdSeconds = Double(max(10, workspace.settings.continuousWorkMinutes)) * 60
        if continuousActiveWorkSeconds >= thresholdSeconds {
            triggerContinuousBreak(at: instant)
        }
    }

    func startContinuousBreakNow() {
        triggerContinuousBreak(at: Date())
    }

    private func triggerContinuousBreak(at instant: Date) {
        continuousActiveWorkSeconds = 0
        let durationMin = max(1, workspace.settings.continuousBreakDurationMinutes)
        activeContinuousBreakDeadline = TrustedDeadline(seconds: Double(durationMin) * 60, wall: instant)
        let pool = workspace.settings.breakMessages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let chosen = pool.randomElement() ?? "Descansa la vista 20 segundos mirando a lo lejos y estira los hombros."
        activeContinuousBreakMessage = chosen
        notice = "Descanso de \(durationMin) min tras \(workspace.settings.continuousWorkMinutes) min de uso continuo: \(chosen)"
        if !preview {
            reminders.notify(
                "Hora de descansar (\(durationMin) min)",
                body: chosen,
                identifier: "cbreak-" + UUID().uuidString
            )
        }
    }

    func skipContinuousBreak() {
        let ref = Date()
        let maxSkips = workspace.settings.continuousBreakMaxSkipsPerDay
        let used = workspace.continuousBreakSkipsToday(at: ref)
        guard used < maxSkips else {
            notice = "Ya has agotado los \(maxSkips) saltos de descanso permitidos hoy."
            return
        }
        let newUsed = workspace.incrementContinuousBreakSkips(at: ref)
        activeContinuousBreakDeadline = nil
        continuousActiveWorkSeconds = 0
        _ = persist()
        let left = max(0, maxSkips - newUsed)
        notice = "Descanso pospuesto. Te \(left == 1 ? "queda 1 salto" : "quedan \(left) saltos") hoy."
    }

    // MARK: - Floating Timer Pill HUD (showTimer)

    /// Announces each change between focus and break in a task done in Pomodoro, once per change.
    func tickTaskPomodoro(at instant: Date) {
        guard let s = session, !s.paused, let phase = pomodoroPhase(for: s, at: instant) else {
            lastTaskPomodoroKey = nil
            return
        }
        let key = "\(s.id)-\(phase.cycle)-\(phase.isBreak)"
        guard key != lastTaskPomodoroKey else { return }
        let first = lastTaskPomodoroKey == nil
        lastTaskPomodoroKey = key
        // Vorssaint reads the phase from Calendar: rewrite the event now, also after a relaunch in mid-session.
        enqueueProjectionForTask(s.task, session: s, now: instant)
        syncCalendar()
        guard !first else { return }
        now = instant
        let minutes = Int((phase.remainingInPhase / 60).rounded())
        let title = phase.isBreak ? "\(phase.label) de \(minutes) min" : "Vuelta al foco · bloque \(phase.cycle)"
        let body = phase.isBreak
            ? "Levántate y aparta la vista. El bloqueo de «\(s.task.title)» se suelta hasta el siguiente bloque."
            : "\(minutes) min de foco en «\(s.task.title)». El bloqueo vuelve a estar activo."
        notice = "\(title). \(body)"
        if !preview { reminders.notify(title, body: body, identifier: "task-pomodoro-" + key) }
    }

    func updateFloatingPill(at instant: Date) {
        guard !preview, workspace.settings.showFloatingTimerPill, !screenIsLocked else {
            floatingPill.hide()
            return
        }
        if let cBreak = activeContinuousBreak(at: instant) {
            floatingPill.update(title: "Descanso · \(cBreak.message)", remaining: cBreak.remaining, urgency: .pauseOrBreak)
            return
        }
        if let sBreak = activeBreak(at: instant) {
            floatingPill.update(title: sBreak.period.title, remaining: sBreak.remaining, urgency: .pauseOrBreak)
            return
        }
        for rule in workspace.generalRules where rule.enabled {
            if let graceDeadline = rule.activePostMatchGraceDeadline {
                let rem = graceDeadline.remainingAfterPossibleReboot(wall: instant)
                if rem > 0 {
                    let played = matchesToday(for: rule, at: instant)
                    let maxM = max(1, rule.maxDailyMatches)
                    floatingPill.update(
                        title: "Cerrando LoL (Partida \(played)/\(maxM)) · \(rule.name)",
                        remaining: rem,
                        urgency: .critical
                    )
                    return
                }
            }
            if let mpDeadline = rule.activeMicroPauseDeadline {
                let rem = mpDeadline.remainingAfterPossibleReboot(wall: instant)
                if rem > 0 {
                    floatingPill.update(title: "Pausa · \(rule.name)", remaining: rem, urgency: .pauseOrBreak)
                    return
                }
            }
            if rule.kind == .pomodoro, let pomoDeadline = rule.activePomodoroDeadline {
                let rem = pomoDeadline.remainingAfterPossibleReboot(wall: instant)
                if rem > 0 {
                    let isBreak = rule.pomodoroPhase != .work
                    let urgency: FloatingTimerPillController.Urgency = isBreak
                        ? .pauseOrBreak
                        : (rem <= 60 ? .critical : (rem <= 180 ? .warning : .normal))
                    floatingPill.update(
                        title: "\(rule.pomodoroPhase.label) (\(rule.pomodoroCurrentCycle)/\(rule.pomodoroTotalCycles)) · \(rule.name)",
                        remaining: rem,
                        urgency: urgency
                    )
                    return
                }
            }
            if rule.kind == .launchLimit, let visitDeadline = rule.activeLaunchDeadline {
                let rem = visitDeadline.remainingAfterPossibleReboot(wall: instant)
                if rem > 0 {
                    let urgency: FloatingTimerPillController.Urgency = rem <= 60 ? .critical : (rem <= 300 ? .warning : .normal)
                    floatingPill.update(title: "Visita · \(rule.name)", remaining: rem, urgency: urgency)
                    return
                }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier {
            // While an active League of Legends match (`GameClient`) is running, hide the floating pill so it never covers the top-right in-game HUD.
            if LeagueMatchRules.isMatchGameProcess(bundleID: bundleID, appPath: front.bundleURL?.path, executablePath: front.executableURL?.path) {
                floatingPill.hide()
                return
            }
            for rule in workspace.generalRules where rule.enabled && isRuleTrackingQuota(rule, at: instant) {
                if matchesRuleUsage(rule: rule, bundleID: bundleID, app: front, title: lastTitle.title, at: instant) {
                    let rem: TimeInterval
                    if rule.kind == .dailyLimit {
                        rem = rule.remainingDailyBudgetSeconds(usedTodaySeconds: usedSecondsToday(for: rule, at: instant))
                    } else if rule.kind == .workGoal && rule.goalRewardMinutes > 0 {
                        rem = rule.remainingGoalRewardSeconds(workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: instant), usedTodaySeconds: usedSecondsToday(for: rule, at: instant))
                    } else {
                        continue
                    }
                    if rem > 0 {
                        let urgency: FloatingTimerPillController.Urgency = rem <= 60 ? .critical : (rem <= 300 ? .warning : .normal)
                        let titlePrefix = rule.maxDailyMatches > 0
                            ? "Partidas \(matchesToday(for: rule, at: instant))/\(rule.maxDailyMatches) · "
                            : ""
                        floatingPill.update(title: titlePrefix + rule.name, remaining: rem, urgency: urgency)
                        return
                    }
                }
            }
        }
        floatingPill.hide()
    }

    /// Gates any change to a `GeneralBlockRule` that is currently enforcing (or in a protected Pomodoro break) and protected.
    func passesGeneralRuleGate(_ change: GeneralRuleChange, quitAfter: Bool = false) -> Bool {
        let targetID = change.rule.id
        if authorizedGeneralRule == targetID {
            authorizedGeneralRule = nil
            return true
        }
        guard let current = workspace.generalRules.first(where: { $0.id == targetID }) else { return true }
        let instant = Date()
        guard isRuleProtected(current, at: instant), current.protection != .none else { return true }

        let actionDescription: String?
        switch change {
        case .delete:
            actionDescription = GeneralBlockRule.loosening(current: current, proposed: nil, now: instant)
        case .resetQuota:
            actionDescription = "reiniciar el límite de «\(current.name)»"
        case .save(let proposed):
            actionDescription = GeneralBlockRule.loosening(current: current, proposed: proposed, now: instant)
        }
        guard let actionDescription else { return true }

        let left = remainingRuleLockSeconds(current, at: instant)
        switch StopGate.decide(
            protection: current.protection,
            reason: .cancel,
            timeLeft: left,
            unlockChars: current.unlockChars,
            stopDelayMinutes: current.stopDelayMinutes,
            pending: current.stopRequest,
            wall: instant
        ) {
        case .allowed:
            return true
        case .waitFinished:
            if let idx = workspace.generalRules.firstIndex(where: { $0.id == current.id }) {
                workspace.generalRules[idx].stopRequest = nil
            }
            generalRuleWaitsNotified.remove(current.id)
            _ = persist()
            return true
        case .challenge(let code):
            presentStopChallenge(PendingStopChallenge(
                reason: .cancel,
                expected: code,
                quitAfter: quitAfter,
                generalRule: change,
                generalRuleAction: actionDescription.prefix(1).uppercased() + actionDescription.dropFirst()
            ))
            notice = "«\(current.name)» está activa y protegida: para \(actionDescription) teclea el código."
            return false
        case .waitStarted(let seconds):
            if let idx = workspace.generalRules.firstIndex(where: { $0.id == current.id }) {
                workspace.generalRules[idx].stopRequest = StopRequest(reason: .cancel, minutes: current.stopDelayMinutes, wall: instant)
            }
            generalRuleWaitsNotified.remove(current.id)
            _ = persist()
            notice = "Has pedido \(actionDescription). FocusDesk espera \(FocusRules.clock(seconds)); cuando termine la espera, vuelve a pulsarlo."
            return false
        case .waiting(let rem):
            notice = "Faltan \(FocusRules.clock(rem)) de espera para poder \(actionDescription)."
            return false
        case .refused:
            presentStopChallenge(PendingStopChallenge(
                reason: .cancel,
                expected: UnlockChallenge.make(length: 60),
                emergency: true,
                quitAfter: quitAfter,
                generalRule: change,
                generalRuleAction: actionDescription.prefix(1).uppercased() + actionDescription.dropFirst()
            ))
            notice = "«\(current.name)» está en «Hasta el final» (quedan \(FocusRules.clock(left))). Solo puedes \(actionDescription) con la salida de emergencia de 60 caracteres."
            return false
        }
    }

    func applyPaidGeneralRuleChange(_ change: GeneralRuleChange) {
        authorizedGeneralRule = change.rule.id
        defer { authorizedGeneralRule = nil }
        switch change {
        case .save(let rule):
            saveGeneralRule(rule)
        case .delete(let rule):
            deleteGeneralRule(rule)
        case .resetQuota(let rule):
            resetDailyQuota(for: rule)
        }
    }

    func checkGeneralRuleWaitsReady() {
        for index in workspace.generalRules.indices {
            let rule = workspace.generalRules[index]
            guard let wait = rule.stopRequest else { continue }
            if wait.expired() {
                workspace.generalRules[index].stopRequest = nil
                generalRuleWaitsNotified.remove(rule.id)
                _ = persist()
                notice = "La ventana para confirmar el cambio en «\(rule.name)» ha caducado: la regla sigue protegida."
                continue
            }
            guard wait.ready(), !generalRuleWaitsNotified.contains(rule.id) else { continue }
            generalRuleWaitsNotified.insert(rule.id)
            let windowClock = FocusRules.clock(wait.confirmWindowRemaining())
            notice = "La espera para cambiar «\(rule.name)» ha terminado (tienes \(windowClock) para confirmarlo). Repite el cambio si sigues queriendo."
            if !preview {
                reminders.notify(
                    "Ya puedes cambiar «\(rule.name)»",
                    body: "La espera ha terminado. Tienes \(windowClock) para repetir la acción en Bloqueo si sigues queriendo.",
                    identifier: "rulerdy-" + rule.id.uuidString
                )
            }
        }
    }

    func saveGeneralRule(_ input: GeneralBlockRule) {
        guard writable else { return }
        var rule = input
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.domains = FocusRules.normalizeDomains(rule.domains)
        rule.blockedTitleKeywords = FocusRules.normalizeTitleKeywords(rule.blockedTitleKeywords)
        rule.blockedFolders = FolderRules.normalizeList(rule.blockedFolders)
        guard rule.valid else {
            error = "Revisa la regla: necesita un nombre y al menos una app, web, palabra de título o carpeta que bloquear."
            return
        }
        if workspace.generalRules.contains(where: { $0.id == rule.id }) {
            guard passesGeneralRuleGate(.save(rule)) else { return }
        }
        rule.stopRequest = nil
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == rule.id }) {
            workspace.generalRules[idx] = rule
        } else {
            workspace.generalRules.append(rule)
        }
        editingGeneralRule = nil
        error = nil
        _ = persist()
        refreshWitness()
        observe()
        notice = "Regla «\(rule.name)» guardada."
    }

    func deleteGeneralRule(_ rule: GeneralBlockRule) {
        guard writable else { return }
        guard passesGeneralRuleGate(.delete(rule)) else { return }
        workspace.generalRules.removeAll { $0.id == rule.id }
        _ = persist()
        refreshWitness()
        notice = "Regla «\(rule.name)» eliminada."
    }

    func toggleGeneralRule(_ rule: GeneralBlockRule, enabled: Bool) {
        guard writable else { return }
        var copy = rule
        copy.enabled = enabled
        if enabled && copy.kind == .countdown {
            let rem = copy.activeDeadline?.remainingAfterPossibleReboot() ?? 0
            if rem <= 0 {
                copy.startCountdown(minutes: copy.countdownMinutes)
            }
        } else if enabled && copy.kind == .pomodoro {
            let rem = copy.activePomodoroDeadline?.remainingAfterPossibleReboot() ?? 0
            if rem <= 0 && copy.pomodoroPhase != .waitingForUser {
                copy.startPomodoro()
            }
        }
        guard passesGeneralRuleGate(.save(copy)) else { return }
        copy.stopRequest = nil
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == copy.id }) {
            workspace.generalRules[idx] = copy
            _ = persist()
            refreshWitness()
            if enabled { observe() }
            notice = enabled
                ? "Regla «\(copy.name)» activada."
                : "Regla «\(copy.name)» desactivada."
        }
    }

    func startPomodoroRule(_ rule: GeneralBlockRule) {
        guard writable else { return }
        var copy = rule
        copy.startPomodoro()
        guard passesGeneralRuleGate(.save(copy)) else { return }
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == copy.id }) {
            workspace.generalRules[idx] = copy
        } else {
            workspace.generalRules.append(copy)
        }
        _ = persist()
        refreshWitness()
        observe()
        notice = "Pomodoro «\(copy.name)» iniciado: ciclo 1/\(copy.pomodoroTotalCycles) (\(copy.pomodoroWorkMinutes) min de enfoque)."
    }

    func skipPomodoroPhase(_ rule: GeneralBlockRule) {
        guard writable else { return }
        let nowInstant = Date()
        var copy = rule
        if copy.pomodoroPhase == .work && copy.pomodoroPhase != .waitingForUser {
            copy.skipPomodoroToBreak(wall: nowInstant)
        } else {
            copy.advancePomodoroPhase(wall: nowInstant)
        }
        guard passesGeneralRuleGate(.save(copy)) else { return }
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == copy.id }) {
            workspace.generalRules[idx] = copy
            _ = persist()
            refreshWitness()
            observe()
            notice = "Fase avanzada en «\(copy.name)»: ahora en \(copy.pomodoroPhase.label.lowercased()) (ciclo \(copy.pomodoroCurrentCycle)/\(copy.pomodoroTotalCycles))."
        }
    }

    func confirmNextPomodoroPhase(_ rule: GeneralBlockRule) {
        guard writable, let idx = workspace.generalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        let nowInstant = Date()
        workspace.generalRules[idx].advancePomodoroPhase(wall: nowInstant)
        let updated = workspace.generalRules[idx]
        _ = persist()
        refreshWitness()
        observe()
        notice = "Pomodoro «\(updated.name)»: empieza \(updated.pomodoroPhase.label.lowercased()) (ciclo \(updated.pomodoroCurrentCycle)/\(updated.pomodoroTotalCycles))."
    }

    func tickPomodoroRules(at instant: Date) {
        var changed = false
        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, rule.kind == .pomodoro, rule.pomodoroPhase != .waitingForUser,
                  let deadline = rule.activePomodoroDeadline else { continue }
            if deadline.remainingAfterPossibleReboot(wall: instant) <= 0 {
                if rule.pomodoroWaitForUser {
                    workspace.generalRules[idx].pomodoroPhase = .waitingForUser
                    workspace.generalRules[idx].activePomodoroDeadline = nil
                    changed = true
                    let msg = "Fase completada en «\(rule.name)» (\(rule.pomodoroPhase.label)). Pulsa Continuar en FocusDesk para empezar la siguiente fase."
                    notice = msg
                    if !preview {
                        reminders.notify("Pomodoro en espera · \(rule.name)", body: msg, identifier: "pomo-wait-" + rule.id.uuidString)
                    }
                } else {
                    workspace.generalRules[idx].advancePomodoroPhase(wall: instant)
                    let updated = workspace.generalRules[idx]
                    changed = true
                    let msg = "Pomodoro «\(updated.name)»: empieza \(updated.pomodoroPhase.label.lowercased()) (ciclo \(updated.pomodoroCurrentCycle)/\(updated.pomodoroTotalCycles))."
                    notice = msg
                    if !preview {
                        reminders.notify("Cambio de fase · \(updated.name)", body: msg, identifier: "pomo-phase-" + updated.id.uuidString)
                    }
                }
            }
        }
        if changed {
            _ = persist()
            refreshWitness()
            observe()
        }
    }

    func startGeneralCountdown(for rule: GeneralBlockRule, minutes: Int) {
        guard writable else { return }
        var copy = rule
        copy.startCountdown(minutes: minutes)
        guard passesGeneralRuleGate(.save(copy)) else { return }
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == copy.id }) {
            workspace.generalRules[idx] = copy
        } else {
            workspace.generalRules.append(copy)
        }
        _ = persist()
        refreshWitness()
        observe()
        notice = "Temporizador de bloqueo «\(copy.name)» en marcha durante \(FocusRules.clock(Double(minutes) * 60))."
    }

    /// One-click Quick Block Timer from the Bloqueo page or MenuBar panel.
    func startQuickBlock(minutes: Int, preset: DistractionPreset? = nil, protection: SessionProtection = .challenge) {
        guard writable else { return }
        let clamped = max(5, min(1440, minutes))
        let label = preset?.label ?? "Redes y vídeos cortos"
        let presetDomains = preset?.domains ?? (DistractionPreset.social.domains + DistractionPreset.shortVideos.domains)
        let presetKeywords = preset?.titleKeywords ?? (DistractionPreset.social.titleKeywords + DistractionPreset.shortVideos.titleKeywords)
        let existingIndex = workspace.generalRules.firstIndex { $0.name.hasPrefix("Bloqueo rápido ·") }
        var rule = existingIndex.map { workspace.generalRules[$0] } ?? GeneralBlockRule(
            name: "Bloqueo rápido · \(label)",
            enabled: true,
            kind: .countdown,
            countdownMinutes: min(720, clamped),
            webListMode: .blockListed,
            domains: presetDomains.joined(separator: ", "),
            webBlockAction: .redirect,
            blockedTitleKeywords: presetKeywords.joined(separator: ", "),
            protection: protection
        )
        rule.name = "Bloqueo rápido · \(label)"
        rule.protection = protection
        let combinedDomains = Set(FocusRules.parseDomains(rule.domains).valid).union(presetDomains)
        rule.domains = combinedDomains.sorted().joined(separator: ", ")
        let combinedKeywords = Set(FocusRules.parseTitleKeywords(rule.blockedTitleKeywords)).union(presetKeywords)
        rule.blockedTitleKeywords = combinedKeywords.sorted().joined(separator: ", ")
        rule.startCountdown(minutes: clamped)
        if let idx = existingIndex {
            guard passesGeneralRuleGate(.save(rule)) else { return }
            workspace.generalRules[idx] = rule
        } else {
            workspace.generalRules.insert(rule, at: 0)
        }
        _ = persist()
        refreshWitness()
        observe()
        notice = "Bloqueo rápido activado durante \(FocusRules.clock(Double(clamped) * 60))."
    }

    func resetDailyQuota(for rule: GeneralBlockRule) {
        guard writable else { return }
        guard passesGeneralRuleGate(.resetQuota(rule)) else { return }
        let nowInstant = Date()
        let rollover = workspace.settings.dayRolloverHour
        let day = FocusRules.dayKey(for: nowInstant, rolloverHour: rollover)
        let pKey = FocusRules.periodKey(for: nowInstant, unit: rule.limitPeriodUnit, rolloverHour: rollover)
        workspace.dailyRuleUsage[day]?[rule.id.uuidString] = 0
        workspace.dailyRuleUsage[pKey]?[rule.id.uuidString] = 0
        workspace.dailyRuleLaunches[day]?[rule.id.uuidString] = 0
        workspace.dailyRuleMatches[day]?[rule.id.uuidString] = 0
        postMatchGraceArmedRules.remove(rule.id)
        if let idx = workspace.generalRules.firstIndex(where: { $0.id == rule.id }) {
            workspace.generalRules[idx].activeLaunchDeadline = nil
            workspace.generalRules[idx].launchCooldownDeadline = nil
            workspace.generalRules[idx].activePostMatchGraceDeadline = nil
        }
        quotaExhaustedNotifiedToday.remove("\(pKey)-\(rule.id.uuidString)")
        quotaExhaustedNotifiedToday.remove("\(day)-\(rule.id.uuidString)")
        quotaWarningsSentToday.remove("\(pKey)-\(rule.id.uuidString)-5m")
        quotaWarningsSentToday.remove("\(pKey)-\(rule.id.uuidString)-1m")
        workspace.recordAudit(
            category: "Reinicio de presupuesto",
            summary: "«\(rule.name)» · \(rule.limitPeriodUnit.label)",
            at: nowInstant
        )
        _ = persist()
        refreshWitness()
        notice = "Presupuesto reiniciado para «\(rule.name)»."
    }

    private func checkPreBlockWarning(for rule: GeneralBlockRule, remainingSeconds: TimeInterval, day: String) {
        guard workspace.settings.preBlockRemindersEnabled, remainingSeconds > 0 else { return }
        if remainingSeconds <= 60 {
            let key1 = "\(day)-\(rule.id.uuidString)-1m"
            guard !quotaWarningsSentToday.contains(key1) else { return }
            quotaWarningsSentToday.insert(key1)
            let msg = "Queda menos de 1 minuto disponible en «\(rule.name)» antes de que se bloquee."
            notice = msg
            if !preview {
                reminders.notify("Último minuto · \(rule.name)", body: msg, identifier: "warn1m-" + rule.id.uuidString)
            }
        } else if remainingSeconds <= 300 {
            let key5 = "\(day)-\(rule.id.uuidString)-5m"
            guard !quotaWarningsSentToday.contains(key5) else { return }
            quotaWarningsSentToday.insert(key5)
            let msg = "Quedan 5 minutos disponibles en «\(rule.name)»."
            notice = msg
            if !preview {
                reminders.notify("Quedan 5 min · \(rule.name)", body: msg, identifier: "warn5m-" + rule.id.uuidString)
            }
        }
    }

    /// Evaluates whether the current foreground app/browser/window matches `rule` (used for `.dailyLimit` and `.workGoal` usage tracking).
    func matchesRuleUsage(rule: GeneralBlockRule, bundleID: String, app: NSRunningApplication, title: String?, at: Date) -> Bool {
        if LeagueMatchRules.ruleTargetsLeague(rule),
           LeagueMatchRules.isLeagueOrRiotProcess(bundleID: bundleID, appPath: app.bundleURL?.path, localizedName: app.localizedName) {
            return true
        }
        if rule.blockGameLibraries, GameLibraryRules.matchesGameApp(bundleID: bundleID, appPath: app.bundleURL?.path) != nil {
            return true
        }
        if rule.blockApps && !rule.apps.isEmpty {
            if !FocusRules.appAllowed(bundleID: bundleID, apps: rule.apps, mode: rule.appListMode) {
                return true
            }
        }
        if FocusRules.matchesTitleKeyword(title, keywords: rule.blockedTitleKeywords, wholeWord: rule.wholeWordKeywords) != nil {
            return true
        }
        if WebRules.isBrowser(bundleID), (rule.webBlockAction != .warn || rule.blockSearchMedia),
           let page = lastObservedBrowserPage[bundleID],
           at.timeIntervalSince(page.at) <= 25 {
            if rule.blockSearchMedia, SearchMediaRules.matches(host: page.host, pathAndQuery: page.path) != nil {
                return true
            }
            if rule.webBlockAction != .warn, !FocusRules.webAllowed(host: page.host, path: page.path, list: rule.domains, mode: rule.webListMode) {
                return true
            }
        }
        if workspace.settings.inspectEmbeddedPages, WebRules.looksLikeChromiumWebApp(bundleID: bundleID),
           let webAppHost = AppInspector.chromiumWebAppHost(for: app),
           rule.webBlockAction != .warn,
           !FocusRules.webAllowed(host: webAppHost, path: "", list: rule.domains, mode: rule.webListMode) {
            return true
        }
        return false
    }

    /// Runs on every `observe()` call to credit `.dailyLimit` / `.workGoal` / `.launchLimit` timers and enforce active `GeneralBlockRule`s.
    func observeGeneralRules(
        fg: Foreground,
        bundleID id: String,
        appChanged: Bool,
        sessionAlreadyReadBrowser: Bool,
        at: Date
    ) {
        let delta: TimeInterval
        if let prev = lastGeneralQuotaAt {
            delta = min(8, max(0, at.timeIntervalSince(prev)))
        } else {
            delta = 0
        }
        lastGeneralQuotaAt = at

        let rollover = workspace.settings.dayRolloverHour
        let day = FocusRules.dayKey(for: at, rolloverHour: rollover)

        // 1. Update usage timers for `.dailyLimit`, `.workGoal` (reward mode), and `.launchLimit` rules.
        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, !rule.isMicroPaused(at: at) else { continue }

            // Auto-transition expired launch visits into their mandatory cooldown.
            if rule.kind == .launchLimit, let visitDeadline = rule.activeLaunchDeadline,
               visitDeadline.remainingAfterPossibleReboot(wall: at) <= 0 {
                workspace.generalRules[idx].endLaunchVisitAndStartCooldown(wall: at)
                _ = persist()
                let cd = workspace.generalRules[idx].launchCooldownMinutes
                let msg = cd > 0
                    ? "Visita agotada en «\(rule.name)». Enfriamiento obligatorio de \(cd) min activado."
                    : "Visita agotada en «\(rule.name)»."
                notice = msg
                if !preview {
                    reminders.notify("Visita terminada · \(rule.name)", body: msg, identifier: "visitend-" + rule.id.uuidString)
                }
            }

            let updatedRule = workspace.generalRules[idx]
            let matchesFront = matchesRuleUsage(rule: updatedRule, bundleID: id, app: fg.app, title: fg.title, at: at)
            let matchesActiveLoLGame = LeagueMatchRules.ruleTargetsLeague(updatedRule) && isLoLMatchCurrentlyInProgress
            guard matchesFront || matchesActiveLoLGame else { continue }

            switch updatedRule.kind {
            case .dailyLimit:
                guard delta > 0 else { break }
                let wasUnder = isRuleTrackingQuota(updatedRule, at: at)
                let newUsed = workspace.addUsedSeconds(
                    delta,
                    for: updatedRule.id,
                    periodUnit: updatedRule.limitPeriodUnit,
                    at: at
                )
                let pKey = FocusRules.periodKey(for: at, unit: updatedRule.limitPeriodUnit, rolloverHour: rollover)
                let rem = updatedRule.remainingDailyBudgetSeconds(usedTodaySeconds: newUsed)
                checkPreBlockWarning(for: updatedRule, remainingSeconds: rem, day: pKey)
                let notifyKey = "\(pKey)-\(updatedRule.id.uuidString)"
                if wasUnder && newUsed >= updatedRule.dailyBudgetSeconds && !quotaExhaustedNotifiedToday.contains(notifyKey) {
                    quotaExhaustedNotifiedToday.insert(notifyKey)
                    _ = persist()
                    refreshWitness()
                    let msg = "Has agotado los \(updatedRule.dailyLimitMinutes) min (\(updatedRule.limitPeriodUnit.label.lowercased())) en «\(updatedRule.name)». Queda bloqueado."
                    notice = msg
                    if !preview {
                        reminders.notify("Presupuesto agotado · \(updatedRule.name)", body: msg, identifier: "quota-" + updatedRule.id.uuidString)
                    }
                }
            case .workGoal:
                guard updatedRule.goalRewardMinutes > 0, delta > 0 else { break }
                let workedForRule = effectiveWorkedSeconds(for: updatedRule, at: at)
                let wasUnder = isRuleTrackingQuota(updatedRule, at: at)
                guard wasUnder else { break }
                let newUsed = workspace.addUsedSeconds(delta, for: updatedRule.id, at: at)
                let rem = updatedRule.remainingGoalRewardSeconds(workedTodaySeconds: workedForRule, usedTodaySeconds: newUsed)
                if !(updatedRule.deferBlockUntilMatchEnds && isLoLMatchCurrentlyInProgress) {
                    checkPreBlockWarning(for: updatedRule, remainingSeconds: rem, day: day)
                }
                let notifyKey = "\(day)-\(updatedRule.id.uuidString)-goal"
                if rem <= 0 && !quotaExhaustedNotifiedToday.contains(notifyKey) {
                    quotaExhaustedNotifiedToday.insert(notifyKey)
                    _ = persist()
                    refreshWitness()
                    let msg = (updatedRule.deferBlockUntilMatchEnds && isLoLMatchCurrentlyInProgress)
                        ? "Se ha cumplido el tiempo de juego en «\(updatedRule.name)», pero FocusDesk esperará a que termines tu partida actual y te dará 1 minuto de margen antes de cerrar LoL."
                        : "Has consumido el tiempo de juego de hoy en «\(updatedRule.name)»."
                    notice = msg
                    if !preview {
                        reminders.notify("Tiempo de juego cumplido · \(updatedRule.name)", body: msg, identifier: "goalq-" + updatedRule.id.uuidString)
                    }
                }
            case .launchLimit:
                if let visitDeadline = updatedRule.activeLaunchDeadline {
                    let rem = visitDeadline.remainingAfterPossibleReboot(wall: at)
                    if rem > 0 {
                        checkPreBlockWarning(for: updatedRule, remainingSeconds: rem, day: day)
                    }
                } else if !updatedRule.isInLaunchCooldown(at: at),
                          workspace.launchesToday(for: updatedRule.id, at: at) < updatedRule.maxDailyLaunches {
                    workspace.generalRules[idx].beginLaunchVisit(wall: at)
                    let usedLaunches = workspace.incrementLaunches(for: updatedRule.id, at: at)
                    _ = persist()
                    notice = "Apertura \(usedLaunches)/\(updatedRule.maxDailyLaunches) hoy en «\(updatedRule.name)»: tienes \(updatedRule.maxLaunchDurationMinutes) min."
                }
            default:
                break
            }
        }

        // 2. If a browser is in front and any enabled general rule cares about websites (either enforcing, tracking quota, or verifying active study),
        // read its active tab if the session did not just read it.
        let rulesNeedWeb = workspace.generalRules.contains {
            $0.enabled && ($0.webBlockAction != .warn || $0.blockSearchMedia || $0.verifyActiveStudy)
        }
        if WebRules.isBrowser(id), rulesNeedWeb, !sessionAlreadyReadBrowser,
           appChanged || Date().timeIntervalSince(lastWebReadAt[id] ?? .distantPast) >= 4.5 {
            lastWebReadAt[id] = at
            inspectBrowserForGeneralRules(bundleID: id)
        }

        // 3. Enforce all currently active general rules.
        let activeRules = workspace.generalRules.filter { isRuleEnforcing($0, at: at) }
        guard !activeRules.isEmpty else { return }

        if SystemSettingsGuard.bundleIDs.contains(id),
           let guardingRule = activeRules.first(where: { $0.guardSystemPanes && $0.protection != .none }),
           Date().timeIntervalSince(lastSettingsGuardAt) >= 1,
           let pane = SystemSettingsGuard.selectedPane(pid: fg.app.processIdentifier) {
            lastSettingsGuardAt = at
            if SystemSettingsGuard.closeFrontWindow(pid: fg.app.processIdentifier) {
                notice = "He cerrado ese panel de Ajustes del Sistema mientras «\(guardingRule.name)» está activa. \(pane.explanation)"
            }
        }

        var exemptions = FocusRules.systemExemptBundleIDs
        if let ownID = Bundle.main.bundleIdentifier { exemptions.insert(ownID) }
        if workspace.isTemporarilyAllowed(bundleID: id, at: at) { return }

        for rule in activeRules {
            if !rule.blockedFolders.isEmpty {
                guardBlockedFoldersForGeneralRule(frontBundleID: id, frontApp: fg.app, rule: rule)
            }
            guard !exemptions.contains(id) else { continue }

            if let kw = FocusRules.matchesTitleKeyword(fg.title, keywords: rule.blockedTitleKeywords, wholeWord: rule.wholeWordKeywords) {
                _ = mutateRuleBlock(ruleID: rule.id)
                let verb = applyBlockAction(to: fg.app, bundleID: id, action: rule.activeBlockAction())
                activateFallbackApp(excluding: id)
                notice = "La ventana de \(fg.app.localizedName ?? id) contiene «\(kw)» (bloqueada por «\(rule.name)»): \(verb)."
                scheduleStrictRecheck(after: 0.8)
                return
            }

            if rule.blockGameLibraries, let gameLib = GameLibraryRules.matchesGameApp(bundleID: id, appPath: fg.app.bundleURL?.path) {
                _ = mutateRuleBlock(ruleID: rule.id)
                let verb = applyBlockAction(to: fg.app, bundleID: id, action: rule.activeBlockAction())
                activateFallbackApp(excluding: id)
                notice = "\(fg.app.localizedName ?? id) (\(gameLib)) está bloqueada por la protección de juegos de «\(rule.name)»: \(verb)."
                scheduleStrictRecheck(after: 0.8)
                return
            }

            if rule.blockApps && !rule.apps.isEmpty && !FocusRules.appAllowed(bundleID: id, apps: rule.apps, mode: rule.appListMode) {
                _ = mutateRuleBlock(ruleID: rule.id)
                let verb = applyBlockAction(to: fg.app, bundleID: id, action: rule.activeBlockAction())
                activateFallbackApp(excluding: id)
                notice = "\(fg.app.localizedName ?? id) está bloqueada por la regla «\(rule.name)»: \(verb)."
                scheduleStrictRecheck(after: 0.8)
                return
            }

            if workspace.settings.inspectEmbeddedPages, WebRules.looksLikeChromiumWebApp(bundleID: id),
               let webAppHost = AppInspector.chromiumWebAppHost(for: fg.app),
               !workspace.isTemporarilyAllowed(host: webAppHost, at: at),
               rule.webBlockAction != .warn,
               !FocusRules.webAllowed(host: webAppHost, path: "", list: rule.domains, mode: rule.webListMode) {
                _ = mutateRuleBlock(ruleID: rule.id)
                fg.app.hide()
                activateFallbackApp(excluding: id)
                notice = "\(fg.app.localizedName ?? id) abre \(webAppHost), bloqueada por «\(rule.name)»: la he ocultado."
                return
            }
        }
    }

    @discardableResult
    private func mutateRuleBlock(ruleID: UUID) -> Bool {
        guard let idx = workspace.generalRules.firstIndex(where: { $0.id == ruleID }) else { return false }
        let nowInstant = Date()
        let penaltyApplied = workspace.generalRules[idx].applyPomodoroPenaltyIfNeeded(wall: nowInstant)
        let fired = workspace.generalRules[idx].registerBlock()
        if penaltyApplied {
            let rule = workspace.generalRules[idx]
            let msg = "Penalización Pomodoro en «\(rule.name)»: el ciclo de \(rule.pomodoroWorkMinutes) min se ha reiniciado desde cero por abrir una distracción."
            notice = msg
            if !preview {
                reminders.notify("Penalización Pomodoro · \(rule.name)", body: msg, identifier: "pomo-pen-" + rule.id.uuidString)
            }
        }
        return fired
    }

    private func activateFallbackApp(excluding blockedID: String) {
        if let candidate = lastAllowed, !candidate.isTerminated, candidate.bundleIdentifier != blockedID {
            _ = candidate.activate(options: [])
            return
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            _ = finder.activate(options: [])
        }
    }

    func inspectBrowserForGeneralRules(bundleID: String) {
        webInspector.read(bundleID: bundleID) { [weak self] result in
            guard let self,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            let browserName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "el navegador"
            if case .page(let host, let path) = result {
                let display = path.isEmpty || path == "/" ? host : "\(host)\(path)"
                self.braveStatus = "\(browserName): \(display)"
                self.lastObservedBrowserPage[bundleID] = (host: host, path: path, at: Date())
                self.evaluateGeneralRulesOnWeb(host: host, path: path, bundleID: bundleID, browserName: browserName)
            }
        }
    }

    func evaluateGeneralRulesOnWeb(host: String, path: String, bundleID: String, browserName: String) {
        let nowInstant = Date()
        if workspace.isTemporarilyAllowed(host: host, path: path, at: nowInstant) { return }

        // If a `.launchLimit` rule matches this site and can start a visit right now, start it instead of blocking.
        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, rule.kind == .launchLimit, !rule.isMicroPaused(at: nowInstant), (rule.webBlockAction != .warn || rule.blockSearchMedia) else { continue }
            let searchHit = rule.blockSearchMedia ? SearchMediaRules.matches(host: host, pathAndQuery: path) : nil
            let matchesWeb = searchHit != nil || (rule.webBlockAction != .warn && !FocusRules.webAllowed(host: host, path: path, list: rule.domains, mode: rule.webListMode))
            guard matchesWeb else { continue }
            if !rule.isLaunchVisitActive(at: nowInstant),
               !rule.isInLaunchCooldown(at: nowInstant),
               workspace.launchesToday(for: rule.id, at: nowInstant) < rule.maxDailyLaunches {
                workspace.generalRules[idx].beginLaunchVisit(wall: nowInstant)
                let usedLaunches = workspace.incrementLaunches(for: rule.id, at: nowInstant)
                _ = persist()
                notice = "Apertura \(usedLaunches)/\(rule.maxDailyLaunches) hoy en «\(rule.name)»: tienes \(rule.maxLaunchDurationMinutes) min."
                return
            }
        }

        for rule in workspace.generalRules where isRuleEnforcing(rule, at: nowInstant) && (rule.webBlockAction != .warn || rule.blockSearchMedia) {
            let searchHit = rule.blockSearchMedia ? SearchMediaRules.matches(host: host, pathAndQuery: path) : nil
            let allowed = searchHit == nil && (rule.webBlockAction == .warn || FocusRules.webAllowed(host: host, path: path, list: rule.domains, mode: rule.webListMode))
            guard !allowed else { continue }
            let visitKey = path.isEmpty || path == "/" ? host : "\(host)\(path)"
            if lastWebBlockHost == visitKey, nowInstant.timeIntervalSince(lastWebBlockAt) < 4 { return }
            lastWebBlockHost = visitKey
            lastWebBlockAt = nowInstant
            let punisherFired = mutateRuleBlock(ruleID: rule.id)
            let hardened = punisherFired || rule.punisher.isActive()
            let baseAction: WebBlockAction = rule.webBlockAction == .warn ? .redirect : rule.webBlockAction
            let action: WebBlockAction = hardened && baseAction == .redirect ? .closeTab : baseAction
            if action == .closeTab {
                webInspector.closeActiveTab(bundleID: bundleID) { [weak self] ok in
                    guard let self else { return }
                    self.notice = ok
                        ? "\(visitKey) está bloqueada por «\(rule.name)»: he cerrado esa pestaña."
                        : "\(visitKey) está bloqueada por «\(rule.name)», pero no pude cerrar la pestaña."
                }
            } else {
                let rem = remainingRuleLockSeconds(rule, at: nowInstant)
                let allowedList = rule.webListMode == .allowListed ? FocusRules.parseDomains(rule.domains).valid : []
                let pendingSteps = session.map { s in
                    s.task.checklist
                        .split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !s.checked.contains($0) }
                } ?? []
                let targetURL: URL
                if let custom = WebRules.normalizedRedirectURL(rule.customRedirectURL) {
                    targetURL = custom
                } else if let page = BlockPage.write(
                    taskTitle: rule.name,
                    host: visitKey,
                    remaining: rem,
                    endsAt: nowInstant.addingTimeInterval(max(0, rem)),
                    allowedDomains: allowedList,
                    motivationalMessage: rule.motivationalMessage,
                    checklistSteps: pendingSteps,
                    in: store.url.deletingLastPathComponent()
                ) {
                    targetURL = page
                } else {
                    return
                }
                webInspector.redirectActiveTab(bundleID: bundleID, to: targetURL) { [weak self] ok in
                    guard let self else { return }
                    self.notice = ok
                        ? "\(visitKey) está bloqueada por «\(rule.name)»: pestaña redirigida a la página de bloqueo."
                        : "\(visitKey) está bloqueada por «\(rule.name)», pero no pude redirigir la pestaña."
                }
            }
            return
        }
    }

    private func guardBlockedFoldersForGeneralRule(frontBundleID id: String, frontApp: NSRunningApplication, rule: GeneralBlockRule) {
        let folders = rule.blockedFolders
        let finderID = "com.apple.finder"
        if id != finderID, id != Bundle.main.bundleIdentifier,
           let path = FolderInspector.frontDocumentPath(pid: frontApp.processIdentifier),
           let folder = FolderRules.blockingFolder(for: path, in: folders) {
            let closed = WindowCloser.closeFrontWindow(pid: frontApp.processIdentifier)
            let name = FolderRules.name(of: folder)
            let app = frontApp.localizedName ?? id
            _ = mutateRuleBlock(ruleID: rule.id)
            notice = closed
                ? "«\(name)» está bloqueada por «\(rule.name)»: he cerrado esa ventana de \(app)."
                : "«\(name)» está bloqueada por «\(rule.name)», pero \(app) no deja cerrar esa ventana."
        }
        guard !finderCheckBusy,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first,
              id == finderID || ScreenWindows.visibleOwnerPIDs().contains(finder.processIdentifier) else { return }
        finderCheckBusy = true
        FolderInspector.moveFinderWindowsOut(of: folders) { [weak self] result in
            guard let self else { return }
            self.finderCheckBusy = false
            if case .movedOut(let hits) = result, !hits.isEmpty {
                let names = hits.map { "«\(FolderRules.name(of: $0))»" }.joined(separator: ", ")
                _ = self.mutateRuleBlock(ruleID: rule.id)
                self.notice = "\(names) bloqueada(s) por «\(rule.name)»: el Finder vuelve a la carpeta superior."
            }
        }
    }

    // MARK: - Clipboard Guard & Import/Export Rules (PlanTemplate)

    func checkClipboardGuard() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = currentCount
        guard workspace.settings.protectClipboard else { return }

        let nowInstant = Date()
        let activeRules = workspace.generalRules.filter { isRuleEnforcing($0, at: nowInstant) }
        let activeSession: WorkSession? = {
            guard let s = session, s.enforcing(at: nowInstant, uptime: uptime) else { return nil }
            return s
        }()
        guard activeSession != nil || !activeRules.isEmpty else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }

        if let s = activeSession {
            let blockedDomains = s.task.webListMode == .blockListed ? s.task.domains : ""
            if let hit = ClipboardGuardRules.violation(
                in: text,
                domains: blockedDomains,
                webListMode: .blockListed,
                webBlockAction: .redirect
            ) {
                NSPasteboard.general.clearContents()
                lastClipboardChangeCount = NSPasteboard.general.changeCount
                notice = "Portapapeles limpiado: contenía «\(hit)», bloqueado en «\(s.task.title)»."
                return
            }
        }

        for rule in activeRules {
            let blockedDomains = rule.webListMode == .blockListed ? rule.domains : ""
            if let hit = ClipboardGuardRules.violation(
                in: text,
                domains: blockedDomains,
                webListMode: .blockListed,
                webBlockAction: .redirect
            ) {
                NSPasteboard.general.clearContents()
                lastClipboardChangeCount = NSPasteboard.general.changeCount
                notice = "Portapapeles limpiado: contenía «\(hit)», bloqueado por «\(rule.name)»."
                return
            }
        }
    }

    func exportGeneralRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusDesk-reglas.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(workspace.generalRules)
            try data.write(to: url, options: .atomic)
            notice = "Se han exportado \(workspace.generalRules.count) reglas en \(url.lastPathComponent)."
        } catch {
            self.error = "No se pudieron exportar las reglas: \(error.localizedDescription)"
        }
    }

    func importGeneralRules() {
        guard writable else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let imported = try decoder.decode([GeneralBlockRule].self, from: data)
            let validImported = imported.filter(\.valid)
            guard !validImported.isEmpty else {
                self.error = "El archivo no contiene reglas generales válidas."
                return
            }
            var added = 0
            var updated = 0
            for var item in validImported {
                item.stopRequest = nil
                if let idx = workspace.generalRules.firstIndex(where: { $0.id == item.id }) {
                    let current = workspace.generalRules[idx]
                    if isRuleProtected(current), current.protection != .none,
                       GeneralBlockRule.loosening(current: current, proposed: item) != nil {
                        continue
                    }
                    workspace.generalRules[idx] = item
                    updated += 1
                } else {
                    workspace.generalRules.append(item)
                    added += 1
                }
            }
            workspace.recordAudit(
                category: "Importación de reglas",
                summary: "\(url.lastPathComponent) · " + "\(added) nuevas, \(updated) actualizadas"
            )
            _ = persist()
            refreshWitness()
            observe()
            notice = "Reglas importadas: \(added) nuevas y \(updated) actualizadas."
        } catch {
            self.error = "No se pudieron importar las reglas: \(error.localizedDescription)"
        }
    }

    func clearAuditLog() {
        guard writable else { return }
        if workspace.settings.protectActivityHistory && refuseWhileProtected("borrar el registro de auditoría") { return }
        workspace.auditLog.removeAll()
        _ = persist()
        notice = "Registro de auditoría vaciado."
    }
}
