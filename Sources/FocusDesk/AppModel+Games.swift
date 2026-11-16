import AppKit
import FocusCore

/// Game rules measured by time (every game except League of Legends, which has its own exact detector in
/// `tickLeagueMatchAndPostMatchGrace`). What to do each second is decided by `TimedMatchPlanner`; this file only looks
/// at what is running, counts matches and closes the game.
extension AppModel {
    /// Whether the app says it is a game in its Info.plist («Juegos» category). Cached: it never changes for a bundle.
    func appIsGameCategory(_ app: NSRunningApplication) -> Bool {
        guard let path = app.bundleURL?.path else { return false }
        if let cached = gameCategoryCache[path] { return cached }
        let category = (Bundle(path: path)?.infoDictionary?["LSApplicationCategoryType"] as? String ?? "").lowercased()
        let isGame = category.contains("games")
        gameCategoryCache[path] = isGame
        return isGame
    }

    /// True when `app` belongs to the game of `rule` (or, for «Otro juego», is one of the apps picked in the editor).
    func appBelongsToGame(_ app: NSRunningApplication, rule: GeneralBlockRule) -> Bool {
        guard let game = rule.game else { return false }
        let id = app.bundleIdentifier ?? ""
        if id == Bundle.main.bundleIdentifier || FocusRules.systemExemptBundleIDs.contains(id) { return false }
        if rule.blockApps, !id.isEmpty, rule.apps.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return true
        }
        guard game.id != GameCatalog.customID else { return false }
        return game.matches(
            bundleID: app.bundleIdentifier,
            bundlePath: app.bundleURL?.path,
            executablePath: app.executableURL?.path,
            localizedName: app.localizedName,
            isGameCategory: game.matchesAnyGame && appIsGameCategory(app)
        )
    }

    func runningGameApps(for rule: GeneralBlockRule) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && appBelongsToGame(app, rule: rule)
        }
    }

    /// True while the front browser tab is the game played from the cloud (GeForce NOW, Xbox Cloud…).
    func isPlayingGameOnWeb(_ rule: GeneralBlockRule, at instant: Date) -> Bool {
        guard let game = rule.game, !game.webEntries.isEmpty,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              WebRules.isBrowser(front),
              let page = lastObservedBrowserPage[front],
              instant.timeIntervalSince(page.at) <= 25 else { return false }
        return game.matchesWeb(host: page.host, path: page.path)
    }

    /// Why the game of `rule` is closed right now, in one sentence.
    func gameLockMessage(_ rule: GeneralBlockRule, at instant: Date) -> String {
        let name = rule.game?.name ?? rule.name
        let played = matchesToday(for: rule, at: instant)
        if rule.maxDailyMatches > 0 && played >= rule.maxDailyMatches {
            return "\(name) está bloqueado por hoy (\(played)/\(rule.maxDailyMatches) \(rule.matchUnitPlural))."
        }
        let needed = rule.requiredWorkSecondsForNextMatch(matchesToday: played)
        let worked = effectiveWorkedSeconds(for: rule, at: instant)
        let leftMin = max(1, Int(ceil((needed - worked) / 60)))
        return "\(name) está bloqueado: te faltan \(leftMin) min de estudio para la \(rule.matchUnitSingular) \(played + 1)/\(max(1, rule.maxDailyMatches))."
    }

    @discardableResult
    func terminateGameApps(for rule: GeneralBlockRule, reasonMessage: String? = nil) -> Bool {
        let running = runningGameApps(for: rule)
        guard !running.isEmpty else { return false }
        for app in running where !app.terminate() {
            app.forceTerminate()
        }
        // Games often ask «¿seguro que quieres salir?»: whatever is still there a moment later is forced.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in running where !app.isTerminated { app.forceTerminate() }
        }
        if let front = NSWorkspace.shared.frontmostApplication, running.contains(front) {
            activateFallbackApp(excluding: front.bundleIdentifier ?? "")
        }
        if let reasonMessage { notice = reasonMessage }
        return true
    }

    /// Runs every second: starts, warns, finishes and enforces timed matches.
    func tickTimedGameMatches(at instant: Date) {
        guard writable, !screenIsLocked else { return }
        let continuousNow = TrustedClock.continuousSeconds()
        for rule in workspace.generalRules where rule.enabled && rule.usesTimedMatches {
            let apps = runningGameApps(for: rule)
            let running = !apps.isEmpty || isPlayingGameOnWeb(rule, at: instant)
            if running { timedMatchLastSeen[rule.id] = instant }
            let since = timedMatchLastSeen[rule.id].map { instant.timeIntervalSince($0) } ?? .infinity
            let step = TimedMatchPlanner.step(
                rule: rule,
                gameRunning: running,
                secondsSinceGameSeen: since,
                workedTodaySeconds: effectiveWorkedSeconds(for: rule, at: instant),
                matchesToday: matchesToday(for: rule, at: instant),
                now: instant,
                continuous: continuousNow
            )
            switch step {
            case .idle:
                if !apps.isEmpty && isRuleEnforcing(rule, at: instant) {
                    terminateGameApps(for: rule, reasonMessage: gameLockMessage(rule, at: instant))
                }
            case .start:
                startTimedMatch(ruleID: rule.id, at: instant, continuous: continuousNow)
            case .playing:
                break
            case .overtime:
                warnTimedMatchOvertime(rule, at: instant)
            case .finish(let reason):
                finishTimedMatch(ruleID: rule.id, reason: reason, at: instant)
            }
        }
    }

    private func startTimedMatch(ruleID: UUID, at instant: Date, continuous: Double) {
        guard let idx = workspace.generalRules.firstIndex(where: { $0.id == ruleID }) else { return }
        workspace.generalRules[idx].startTimedMatch(wall: instant, continuous: continuous)
        timedMatchOvertimeWarned.remove(ruleID)
        let rule = workspace.generalRules[idx]
        let number = min(rule.maxDailyMatches, matchesToday(for: rule, at: instant) + 1)
        let unit = rule.matchUnitSingular
        workspace.recordAudit(
            category: "Partida empezada",
            summary: "«\(rule.name)» · \(unit.capitalized) \(number)/\(rule.maxDailyMatches) · \(rule.matchMinutes) min + \(rule.matchOvertimeMinutes) de prórroga",
            at: instant
        )
        _ = persist()
        refreshWitness()
        let overtime = rule.matchOvertimeMinutes > 0 ? " y \(rule.matchOvertimeMinutes) min de prórroga para acabarla" : ""
        let msg = "\(unit.capitalized) \(number)/\(rule.maxDailyMatches) de \(rule.game?.name ?? rule.name) en marcha: tienes \(rule.matchMinutes) min\(overtime). Si acabas antes, pulsa «He terminado» en la regla o cierra el juego."
        notice = msg
        if !preview {
            reminders.notify("\(unit.capitalized) \(number)/\(rule.maxDailyMatches) en marcha", body: msg, identifier: "game-start-" + rule.id.uuidString)
        }
    }

    private func warnTimedMatchOvertime(_ rule: GeneralBlockRule, at instant: Date) {
        guard !timedMatchOvertimeWarned.contains(rule.id) else { return }
        timedMatchOvertimeWarned.insert(rule.id)
        let left = max(1, Int(ceil(rule.timedMatchRemainingSeconds(at: instant) / 60)))
        let msg = "Se acabó el tiempo de esta \(rule.matchUnitSingular): termina la que estás jugando. Tienes \(left) min de prórroga antes de que se cierre \(rule.game?.name ?? "el juego")."
        notice = msg
        if !preview {
            reminders.notify("Prórroga · \(rule.game?.name ?? rule.name)", body: msg, identifier: "game-overtime-" + rule.id.uuidString)
        }
    }

    /// Ends the timed match being played, counts it and closes the game if there is no other one available now.
    func finishTimedMatch(ruleID: UUID, reason: TimedMatchPlanner.FinishReason, at instant: Date = Date()) {
        guard let idx = workspace.generalRules.firstIndex(where: { $0.id == ruleID }),
              workspace.generalRules[idx].activeMatchDeadline != nil else { return }
        workspace.generalRules[idx].endTimedMatch()
        timedMatchOvertimeWarned.remove(ruleID)
        let played = workspace.incrementMatches(for: ruleID, at: instant)
        let rule = workspace.generalRules[idx]
        let unit = rule.matchUnitSingular
        let how: String
        switch reason {
        case .timeUp: how = "se acabó la prórroga"
        case .gameClosed: how = "cerraste el juego"
        case .userFinished: how = "pulsaste «He terminado»"
        }
        workspace.recordAudit(
            category: "Partida terminada",
            summary: "«\(rule.name)» · \(unit.capitalized) \(played)/\(rule.maxDailyMatches) terminada (\(how))",
            at: instant
        )
        _ = persist()
        refreshWitness()

        let locked = isRuleEnforcing(rule, at: instant)
        if locked || reason == .userFinished {
            let tail = locked ? gameLockMessage(rule, at: instant) : "Te queda otra \(unit) disponible cuando quieras."
            let msg = "\(unit.capitalized) \(played)/\(rule.maxDailyMatches) terminada. \(tail)"
            terminateGameApps(for: rule)
            notice = msg
            if !preview {
                reminders.notify("\(unit.capitalized) \(played)/\(rule.maxDailyMatches) terminada", body: msg, identifier: "game-end-" + rule.id.uuidString)
            }
        } else {
            let msg = "\(unit.capitalized) \(played)/\(rule.maxDailyMatches) terminada. Tienes otra ganada: si sigues jugando, empieza a contar ya."
            notice = msg
            if !preview {
                reminders.notify("\(unit.capitalized) \(played)/\(rule.maxDailyMatches) terminada", body: msg, identifier: "game-end-" + rule.id.uuidString)
            }
        }
    }
}
