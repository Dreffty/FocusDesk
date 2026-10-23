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

    var title: String {
        if emergency { return "Salida de emergencia" }
        switch reason {
        case .pause: return "Pausar la sesión"
        case .cancel: return "Cancelar la sesión"
        case .finishEarly: return "Terminar antes de tiempo"
        }
    }

    var correctSoFar: Int { UnlockChallenge.correctPrefix(typed: typed, expected: expected) }
    var complete: Bool { UnlockChallenge.matches(typed: typed, expected: expected) }
}

extension AppModel {

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
            pendingStop = PendingStopChallenge(reason: reason, expected: code)
            showWindow?()
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
            let length = challenge.emergency ? 60 : (session?.task.unlockChars ?? 24)
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
    /// The demo mode (`--preview`) always lets go: trying out a locked session must not trap anyone in a demo.
    func canQuitNow() -> Bool {
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
            pendingStop = PendingStopChallenge(reason: .pause, expected: code, quitAfter: true)
            showWindow?()
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
        pendingStop = nil
        notice = "Sigues con la tarea."
    }

    /// The way out of a session set to «Hasta el final»: sixty characters, no paste, and a line in the history.
    func requestEmergencyExit() {
        guard let s = session, s.endedAt == nil else { return }
        pendingStop = PendingStopChallenge(reason: .cancel, expected: UnlockChallenge.make(length: 60), emergency: true)
        notice = "«\(s.task.title)» está en «Hasta el final». La salida de emergencia existe, pero cuesta 60 caracteres y queda registrada."
        showWindow?()
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
            let action = FocusRules.safeAction(
                workspace.session?.activeBlockAction() ?? s.task.blockAction,
                for: id
            )
            let verb: String
            switch action {
            case .hide:
                distracting.hide()
                verb = "la he ocultado"
            case .close:
                // Like ⌘Q: the app can still offer to save.
                distracting.terminate()
                verb = "la he cerrado"
            case .forceQuit:
                distracting.forceTerminate()
                verb = "la he cerrado a la fuerza"
            }
            let ok = target.activate(options: [])
            strictTracker.recordRedirectAttempt(succeeded: ok)
            if punisherJustFired, let until = workspace.session?.punisher.remaining() {
                notice = "Van \(s.punisher.maxAttempts) intentos seguidos. Durante \(FocusRules.clock(until)) FocusDesk cerrará estas apps en vez de ocultarlas."
            } else {
                notice = ok
                    ? "\(distractingName) no está entre las apps de esta tarea: \(verb) y vuelves a \(target.localizedName ?? "la app permitida")."
                    : "No se pudo volver a \(target.localizedName ?? "la app permitida"). Puedes pausar en cualquier momento."
            }
            if isNewInterruption, !preview { notifyDistraction(notice ?? "", session: s) }
            scheduleStrictRecheck(after: 0.8)
            return false
        case .pauseSession(let reason):
            // The safety valve: nowhere to send the user back to. Pausing here needs no code, or the session
            // would be stuck with no allowed app and no way out.
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
        workspace.session?.registerBlock()
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
        guard outside else { blockedHostEpisode = nil; return }

        switch s.task.webBlockAction {
        case .warn:
            if newVisit {
                notice = "\(host) no está en los dominios de la tarea. El control de webs es informativo."
                if !preview { notifyDistraction(notice ?? "", session: s) }
            }
        case .redirect, .closeTab:
            // One action per visit: redirecting lands on FocusDesk's page, which must not be blocked in turn.
            guard blockedHostEpisode != host else { return }
            blockedHostEpisode = host
            let punisherJustFired = workspace.session?.registerBlock() ?? false
            let hardened = punisherJustFired || (workspace.session?.punisher.isActive() ?? false)
            let action: WebBlockAction = hardened && s.task.webBlockAction == .redirect ? .closeTab : s.task.webBlockAction
            if action == .closeTab {
                webInspector.closeActiveTab(bundleID: bundleID) { [weak self] ok in
                    guard let self else { return }
                    self.notice = ok
                        ? "\(host) no entra en esta tarea: he cerrado esa pestaña. El resto del navegador sigue como estaba."
                        : "\(host) no entra en esta tarea, pero no pude cerrar la pestaña. Revisa el permiso de Automatización."
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
        guard let host = blocked.first, blockedHostEpisode != host else { return }
        blockedHostEpisode = host
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
