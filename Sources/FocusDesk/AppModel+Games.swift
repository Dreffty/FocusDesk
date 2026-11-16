import AppKit
import FocusCore
import Network

/// Game rules measured by time (every game except League of Legends and Valve GSI exact games).
/// What to do each second is decided by `TimedMatchPlanner`; this file looks at what is running,
/// receives Valve Game State Integration events, counts matches and closes the game.
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
            stepTimedMatch(for: rule, allowTimedFallback: false, at: instant, continuousNow: continuousNow)
        }
    }

    private func stepTimedMatch(
        for rule: GeneralBlockRule,
        allowTimedFallback: Bool,
        at instant: Date,
        continuousNow: Double
    ) {
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
            allowTimedFallback: allowTimedFallback,
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

    // MARK: - Valve Game State Integration (CS2 & Dota 2)

    func startValveGSIServerIfNeeded() {
        guard !preview, workspace.generalRules.contains(where: { $0.enabled && $0.usesExactValveGSI }) else { return }
        ValveGSIConfig.installIfPossible()
        guard valveGSIServer == nil else { return }
        let server = ValveGSIServer(port: ValveGSI.port) { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handleValveGSIPayload(data)
            }
        }
        server.start()
        valveGSIServer = server
    }

    func handleValveGSIPayload(_ data: Data, at instant: Date = Date()) {
        guard writable, !screenIsLocked, let event = ValveGSI.parse(jsonData: data) else { return }
        let continuousNow = TrustedClock.continuousSeconds()
        valveLastEventAt[event.gameID] = instant
        for idx in workspace.generalRules.indices where workspace.generalRules[idx].enabled && workspace.generalRules[idx].gameID == event.gameID {
            if workspace.generalRules[idx].activeMatchDeadline != nil {
                workspace.generalRules[idx].endTimedMatch()
            }
            valveUnconnectedSince.removeValue(forKey: workspace.generalRules[idx].id)
        }

        let matchingRules = workspace.generalRules.filter { $0.enabled && $0.usesExactValveGSI && $0.gameID == event.gameID }
        guard !matchingRules.isEmpty else { return }
        let gameName = GameCatalog.game(id: event.gameID)?.name ?? event.gameID

        switch event.phase {
        case .live, .intermission:
            if valveMatchActive[event.gameID] != true {
                for rule in matchingRules {
                    let played = matchesToday(for: rule, at: instant)
                    let worked = effectiveWorkedSeconds(for: rule, at: instant)
                    let needed = rule.requiredWorkSecondsForNextMatch(matchesToday: played)
                    let blocked = (rule.maxDailyMatches > 0 && played >= rule.maxDailyMatches) || worked < needed
                    if blocked {
                        terminateGameApps(for: rule, reasonMessage: gameLockMessage(rule, at: instant))
                        return
                    }
                }
                valveMatchActive[event.gameID] = true
                valveMatchStartedContinuous[event.gameID] = continuousNow
                if let first = matchingRules.first {
                    let currentMatchNum = min(max(1, first.maxDailyMatches), matchesToday(for: first, at: instant) + 1)
                    notice = "Partida \(currentMatchNum)/\(max(1, first.maxDailyMatches)) de \(gameName) en curso · FocusDesk no te sacará a mitad."
                }
            }
        case .gameover:
            if valveMatchActive[event.gameID] == true {
                finishExactValveMatch(gameID: event.gameID, at: instant, continuousNow: continuousNow)
            }
        case .menu:
            if valveMatchActive[event.gameID] == true,
               let started = valveMatchStartedContinuous[event.gameID],
               continuousNow - started >= LeagueMatchRules.minCountedMatchDurationSeconds {
                finishExactValveMatch(gameID: event.gameID, at: instant, continuousNow: continuousNow)
            } else {
                valveMatchActive[event.gameID] = false
                valveMatchStartedContinuous.removeValue(forKey: event.gameID)
            }
        }
    }

    private func finishExactValveMatch(gameID: String, at instant: Date, continuousNow: Double) {
        valveMatchActive[gameID] = false
        valveMatchStartedContinuous.removeValue(forKey: gameID)
        let gameName = GameCatalog.game(id: gameID)?.name ?? gameID

        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, rule.usesExactValveGSI, rule.gameID == gameID else { continue }
            let newMatches = workspace.incrementMatches(for: rule.id, at: instant)
            let worked = effectiveWorkedSeconds(for: rule, at: instant)
            let matchLimitReached = rule.maxDailyMatches > 0 && newMatches >= rule.maxDailyMatches
            let needsMoreWork = rule.isWaitingForMoreWork(workedTodaySeconds: worked, matchesToday: newMatches)

            if matchLimitReached || needsMoreWork {
                workspace.generalRules[idx].startPostMatchGrace(wall: instant, continuous: continuousNow)
                postMatchGraceArmedRules.insert(rule.id)
                let graceSec = workspace.generalRules[idx].postMatchGraceSeconds
                workspace.recordAudit(
                    category: "Partida terminada (Valve)",
                    summary: "«\(rule.name)» · Partida \(newMatches)/\(max(1, rule.maxDailyMatches)) terminada · Margen de \(graceSec)s iniciado",
                    at: instant
                )
                _ = persist()
                refreshWitness()
                let tail = needsMoreWork && !matchLimitReached
                    ? "hasta que estudies más"
                    : "por hoy"
                let msg = "Partida \(newMatches)/\(max(1, rule.maxDailyMatches)) de \(gameName) terminada. Tienes \(graceSec)s de margen antes de cerrarlo \(tail)."
                notice = msg
                if !preview {
                    reminders.notify("Partida terminada · \(gameName)", body: msg, identifier: "valve-grace-" + rule.id.uuidString)
                }
            } else {
                _ = persist()
                let left = max(0, rule.maxDailyMatches - newMatches)
                let msg = "Partida \(newMatches)/\(rule.maxDailyMatches) de \(gameName) completada. Te \(left == 1 ? "queda 1 disponible" : "quedan \(left) disponibles")."
                notice = msg
                if !preview {
                    reminders.notify("Partida \(newMatches)/\(rule.maxDailyMatches) terminada", body: msg, identifier: "valve-match-" + rule.id.uuidString)
                }
            }
        }
    }

    /// Enforces Valve GSI rules and falls back to timed counting if Steam's `.cfg` has not sent events after 60s of running.
    func tickValveGSIGames(at instant: Date) {
        guard writable, !screenIsLocked else { return }
        let continuousNow = TrustedClock.continuousSeconds()
        for idx in workspace.generalRules.indices {
            let rule = workspace.generalRules[idx]
            guard rule.enabled, rule.usesExactValveGSI, let gameID = rule.gameID else { continue }

            if rule.isInPostMatchGrace(at: instant, continuous: continuousNow) {
                postMatchGraceArmedRules.insert(rule.id)
                continue
            }
            if postMatchGraceArmedRules.contains(rule.id) {
                postMatchGraceArmedRules.remove(rule.id)
                workspace.generalRules[idx].activePostMatchGraceDeadline = nil
                _ = persist()
                refreshWitness()
                let gameName = rule.game?.name ?? rule.name
                let msg = "Margen finalizado: FocusDesk ha cerrado \(gameName)."
                _ = terminateGameApps(for: workspace.generalRules[idx], reasonMessage: msg)
                if !preview {
                    reminders.notify("\(gameName) cerrado", body: msg, identifier: "valve-closed-" + rule.id.uuidString)
                }
                continue
            }

            let apps = runningGameApps(for: rule)
            let gsiConnected = valveLastEventAt[gameID].map { instant.timeIntervalSince($0) <= 600 } ?? false
            if gsiConnected {
                valveUnconnectedSince.removeValue(forKey: rule.id)
                if valveMatchActive[gameID] != true && !apps.isEmpty && isRuleEnforcing(rule, at: instant) {
                    terminateGameApps(for: rule, reasonMessage: gameLockMessage(rule, at: instant))
                }
                continue
            }

            if apps.isEmpty && rule.activeMatchDeadline == nil {
                valveUnconnectedSince.removeValue(forKey: rule.id)
                continue
            }
            if !apps.isEmpty && rule.activeMatchDeadline == nil && isRuleEnforcing(rule, at: instant) {
                terminateGameApps(for: rule, reasonMessage: gameLockMessage(rule, at: instant))
                continue
            }
            if rule.activeMatchDeadline == nil {
                let firstSeen = valveUnconnectedSince[rule.id] ?? instant
                valveUnconnectedSince[rule.id] = firstSeen
                guard instant.timeIntervalSince(firstSeen) >= 60 else { continue }
            }
            stepTimedMatch(for: rule, allowTimedFallback: true, at: instant, continuousNow: continuousNow)
        }
    }
}

/// Writes `gamestate_integration_focusdesk.cfg` into installed macOS Steam libraries for CS2 and Dota 2.
enum ValveGSIConfig {
    static func installIfPossible() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let defaultSteamApps = home.appendingPathComponent("Library/Application Support/Steam/steamapps")
        var libraryRoots: [URL] = [defaultSteamApps]

        let vdfURL = defaultSteamApps.appendingPathComponent("libraryfolders.vdf")
        if let vdf = try? String(contentsOf: vdfURL, encoding: .utf8) {
            for line in vdf.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\"path\"") {
                    let parts = trimmed.split(separator: "\"")
                    if parts.count >= 4 {
                        let libPath = String(parts[3]).replacingOccurrences(of: "\\\\", with: "\\")
                        libraryRoots.append(URL(fileURLWithPath: libPath).appendingPathComponent("steamapps"))
                    }
                }
            }
        }

        let relativeCfgDirs = [
            "common/Counter-Strike Global Offensive/game/csgo/cfg",
            "common/Counter-Strike Global Offensive/csgo/cfg",
            "common/dota 2 beta/game/dota/cfg"
        ]
        for root in libraryRoots {
            for rel in relativeCfgDirs {
                let cfgDir = root.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: cfgDir.path, isDirectory: &isDir), isDir.boolValue {
                    let fileURL = cfgDir.appendingPathComponent(ValveGSI.configFilename)
                    let current = try? String(contentsOf: fileURL, encoding: .utf8)
                    if current != ValveGSI.configContents {
                        try? ValveGSI.configContents.write(to: fileURL, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }
}

/// Minimal HTTP localhost listener receiving POST JSON updates from Valve Game State Integration.
final class ValveGSIServer {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.articdia.focusdesk.valvegsi")
    private let onPayload: @Sendable (Data) -> Void
    private var listener: NWListener?

    init(port: UInt16, onPayload: @escaping @Sendable (Data) -> Void) {
        self.port = port
        self.onPayload = onPayload
    }

    func start() {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let listener = try? NWListener(using: params) else { return }
        let callback = onPayload
        listener.newConnectionHandler = { [weak self] connection in
            guard let queue = self?.queue else { connection.cancel(); return }
            let handler = ValveHTTPConnection(connection: connection, queue: queue, onPayload: callback)
            handler.start()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class ValveHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let onPayload: @Sendable (Data) -> Void
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue, onPayload: @escaping @Sendable (Data) -> Void) {
        self.connection = connection
        self.queue = queue
        self.onPayload = onPayload
    }

    func start() {
        connection.start(queue: queue)
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
            }
            if let body = self.extractCompletedBody() {
                let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                self.connection.send(content: response, completion: .contentProcessed { _ in
                    self.connection.cancel()
                })
                self.onPayload(body)
                return
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receiveNext()
        }
    }

    private func extractCompletedBody() -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var contentLength: Int?
        for line in headerText.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
                break
            }
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.count - bodyStart
        if let expected = contentLength {
            guard available >= expected else { return nil }
            return buffer.subdata(in: bodyStart..<(bodyStart + expected))
        }
        return buffer.subdata(in: bodyStart..<buffer.count)
    }
}
