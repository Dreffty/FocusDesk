import Foundation

// MARK: - Juegos: «primero estudio, luego partida» para cualquier juego
//
// Una regla de juego es una regla `.workGoal` con `gameID`: el estudio desbloquea partidas y las partidas se cuentan.
// Lo único que cambia de un juego a otro es CÓMO se sabe que una partida ha terminado:
//
//  • `.exactLeague`: League of Legends abre un programa aparte solo mientras dura la partida (`GameClient`), así que
//    FocusDesk ve exactamente cuándo empieza y cuándo acaba (ver `LeagueMatchRules`).
//  • `.timed`: el resto de juegos usan el mismo programa en el menú y en partida, así que no se puede saber desde
//    fuera. La partida empieza cuando abres el juego y dura su tiempo típico; al acabar hay una prórroga para terminar
//    la partida en curso, y solo al final de la prórroga se cierra el juego. «He terminado» o cerrar el juego la
//    acaban antes.
//
// Para añadir un juego basta con añadir una ficha a `GameCatalog.all` (ver docs/JUEGOS.md).

/// How FocusDesk knows when a match of this game ends.
public enum GameMatchDetection: String, Codable, Sendable {
    /// Exact: a separate in-match process exists (League of Legends).
    case exactLeague
    /// By time: typical match length + overtime, finished early by «He terminado» or by closing the game.
    case timed

    public var label: String {
        switch self {
        case .exactLeague: return "Detección exacta"
        case .timed: return "Por tiempo con prórroga"
        }
    }

    public var explanation: String {
        switch self {
        case .exactLeague:
            return "FocusDesk ve cuándo empieza y cuándo acaba cada partida: nunca te saca a mitad y cierra el juego al terminar."
        case .timed:
            return "Este juego no avisa de cuándo acaba la partida. Empieza a contar al abrirlo; al llegar a la duración típica te avisa, te da la prórroga para acabar y solo entonces lo cierra. Si terminas antes, pulsa «He terminado» o cierra el juego."
        }
    }
}

/// One game FocusDesk knows: how to recognise it and how its matches are measured.
public struct GameDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: String
    public let detection: GameMatchDetection
    /// Typical length of one match (or one play session) in minutes, used by `.timed`.
    public let typicalMatchMinutes: Int
    /// «partida» for games with matches, «sesión» for open-world games (Minecraft, Roblox, WoW).
    public let unitSingular: String
    public let unitPlural: String
    /// Lower-cased bundle identifier prefixes («com.roblox.»).
    public let bundleIDPrefixes: [String]
    /// Lower-cased fragments of the app name («minecraft»).
    public let nameKeywords: [String]
    /// Lower-cased fragments of the app or executable path («/minecraft/»).
    public let pathFragments: [String]
    /// Webs where the game is played (cloud gaming), blocked while the rule is locked and counted as playing.
    public let webEntries: [String]
    /// When `true`, matches any game: known launchers, game library folders and apps whose category is «Juegos».
    public let matchesAnyGame: Bool
    /// One line shown under the game in the editor (e.g. «En Mac solo por la nube»).
    public let note: String

    public init(
        id: String,
        name: String,
        icon: String,
        detection: GameMatchDetection,
        typicalMatchMinutes: Int,
        unitSingular: String = "partida",
        unitPlural: String = "partidas",
        bundleIDPrefixes: [String] = [],
        nameKeywords: [String] = [],
        pathFragments: [String] = [],
        webEntries: [String] = [],
        matchesAnyGame: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.detection = detection
        self.typicalMatchMinutes = typicalMatchMinutes
        self.unitSingular = unitSingular
        self.unitPlural = unitPlural
        self.bundleIDPrefixes = bundleIDPrefixes.map { $0.lowercased() }
        self.nameKeywords = nameKeywords.map { $0.lowercased() }
        self.pathFragments = pathFragments.map { $0.lowercased() }
        self.webEntries = webEntries
        self.matchesAnyGame = matchesAnyGame
        self.note = note
    }

    /// True when a running app belongs to this game.
    /// `isGameCategory` is whether the app declares itself a game in its Info.plist (`LSApplicationCategoryType`).
    public func matches(
        bundleID: String?,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        localizedName: String? = nil,
        isGameCategory: Bool = false
    ) -> Bool {
        if detection == .exactLeague {
            return LeagueMatchRules.isLeagueOrRiotProcess(bundleID: bundleID, appPath: bundlePath, localizedName: localizedName)
        }
        let id = (bundleID ?? "").lowercased()
        if !id.isEmpty, bundleIDPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        if let name = localizedName?.lowercased(), !name.isEmpty, nameKeywords.contains(where: { name.contains($0) }) {
            return true
        }
        for path in [bundlePath, executablePath].compactMap({ $0?.lowercased() }) where !path.isEmpty {
            if pathFragments.contains(where: { path.contains($0) }) { return true }
        }
        if matchesAnyGame {
            if isGameCategory { return true }
            if GameLibraryRules.matchesGameApp(bundleID: bundleID ?? "", appPath: bundlePath ?? executablePath) != nil { return true }
        }
        return false
    }

    /// True when a browser page is this game played from the cloud.
    public func matchesWeb(host: String, path: String) -> Bool {
        webEntries.contains { FocusRules.entryMatches(host: host, path: path, entry: $0) }
    }
}

public enum GameCatalog {
    public static let leagueID = "lol"
    /// «Otro juego»: the user picks the app(s) in the editor; matches are measured by time.
    public static let customID = "otro"

    public static let all: [GameDefinition] = [
        GameDefinition(
            id: leagueID,
            name: "League of Legends",
            icon: "shield.lefthalf.filled",
            detection: .exactLeague,
            typicalMatchMinutes: 35,
            note: "También bloquea el cliente de Riot mientras no tengas partidas."
        ),
        GameDefinition(
            id: "fortnite",
            name: "Fortnite (nube)",
            icon: "cloud.fill",
            detection: .timed,
            typicalMatchMinutes: 25,
            bundleIDPrefixes: ["com.nvidia.gfnpc", "com.nvidia.geforcenow"],
            nameKeywords: ["geforce now", "fortnite"],
            pathFragments: ["/geforcenow.app", "/geforce now.app"],
            webEntries: ["play.geforcenow.com", "xbox.com/play", "xbox.com/*/play", "fortnite.com/play"],
            note: "En Mac, Fortnite solo se juega por la nube: bloquea GeForce NOW y Xbox Cloud (y con ellos cualquier juego en la nube)."
        ),
        GameDefinition(
            id: "minecraft",
            name: "Minecraft",
            icon: "cube.fill",
            detection: .timed,
            typicalMatchMinutes: 45,
            unitSingular: "sesión",
            unitPlural: "sesiones",
            bundleIDPrefixes: ["com.mojang.", "org.prismlauncher.", "org.multimc."],
            nameKeywords: ["minecraft", "tlauncher", "prism launcher", "multimc"],
            pathFragments: ["/minecraft/", "/minecraft.app", "tlauncher", "prismlauncher"],
            note: "Minecraft no tiene partidas: cuenta sesiones de juego."
        ),
        GameDefinition(
            id: "roblox",
            name: "Roblox",
            icon: "square.grid.3x3.fill",
            detection: .timed,
            typicalMatchMinutes: 30,
            unitSingular: "sesión",
            unitPlural: "sesiones",
            bundleIDPrefixes: ["com.roblox."],
            nameKeywords: ["roblox"],
            pathFragments: ["/roblox.app", "/robloxstudio.app"],
            webEntries: ["roblox.com"],
            note: "Cuenta sesiones de juego, sea cual sea la experiencia."
        ),
        GameDefinition(
            id: "dota2",
            name: "Dota 2",
            icon: "flame.fill",
            detection: .timed,
            typicalMatchMinutes: 45,
            bundleIDPrefixes: ["com.valvesoftware.dota2"],
            nameKeywords: ["dota 2", "dota2"],
            pathFragments: ["/dota 2 beta/", "/dota2.app"]
        ),
        GameDefinition(
            id: "wow",
            name: "World of Warcraft",
            icon: "sparkles",
            detection: .timed,
            typicalMatchMinutes: 60,
            unitSingular: "sesión",
            unitPlural: "sesiones",
            bundleIDPrefixes: ["com.blizzard.worldofwarcraft"],
            nameKeywords: ["world of warcraft"],
            pathFragments: ["/world of warcraft/"]
        ),
        GameDefinition(
            id: "cualquiera",
            name: "Cualquier juego",
            icon: "gamecontroller.fill",
            detection: .timed,
            typicalMatchMinutes: 40,
            unitSingular: "sesión",
            unitPlural: "sesiones",
            webEntries: ["play.geforcenow.com", "xbox.com/play", "xbox.com/*/play"],
            matchesAnyGame: true,
            note: "Steam, Epic, Battle.net, Roblox, CrossOver, juegos en la nube y cualquier app marcada como juego."
        ),
        GameDefinition(
            id: customID,
            name: "Otro juego",
            icon: "plus.app",
            detection: .timed,
            typicalMatchMinutes: 30,
            note: "Elige tú la app del juego en «Apps» más abajo."
        )
    ]

    public static func game(id: String?) -> GameDefinition? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

extension GeneralBlockRule {
    /// The game this rule is about, when it is a «primero estudio, luego partida» rule.
    public var game: GameDefinition? {
        guard kind == .workGoal else { return nil }
        return GameCatalog.game(id: gameID)
    }

    /// True for game rules whose matches are measured by time (every game except League of Legends).
    public var usesTimedMatches: Bool {
        guard let game, maxDailyMatches > 0 else { return false }
        return game.detection == .timed
    }

    public var matchUnitSingular: String { game?.unitSingular ?? "partida" }
    public var matchUnitPlural: String { game?.unitPlural ?? "partidas" }

    /// Total length of a timed match window: typical length + overtime.
    public var timedMatchTotalSeconds: TimeInterval {
        Double(max(1, matchMinutes) + max(0, matchOvertimeMinutes)) * 60
    }

    public func timedMatchRemainingSeconds(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        activeMatchDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous) ?? 0
    }

    /// True while a timed match is being played (its window, overtime included, has not run out).
    public func isInTimedMatch(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        usesTimedMatches && timedMatchRemainingSeconds(at: now, continuous: continuous) > 0
    }

    /// True once the typical match length is over and only the overtime is left.
    public func isInTimedMatchOvertime(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        guard isInTimedMatch(at: now, continuous: continuous) else { return false }
        return timedMatchRemainingSeconds(at: now, continuous: continuous) <= Double(max(0, matchOvertimeMinutes)) * 60
    }

    /// Seconds played in the current timed match.
    public func timedMatchElapsedSeconds(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        guard activeMatchDeadline != nil else { return 0 }
        return max(0, timedMatchTotalSeconds - timedMatchRemainingSeconds(at: now, continuous: continuous))
    }

    public mutating func startTimedMatch(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) {
        activeMatchDeadline = TrustedDeadline(seconds: timedMatchTotalSeconds, wall: wall, continuous: continuous)
    }

    public mutating func endTimedMatch() {
        activeMatchDeadline = nil
    }

    /// A new game rule for `game`, ready to open in the editor: 60 min of study per match, max 2 a day.
    public static func gameTemplate(_ game: GameDefinition) -> GeneralBlockRule {
        var rule = GeneralBlockRule(
            name: "1 h de estudio por \(game.unitSingular) de \(game.name) · máx. 2 al día",
            kind: .workGoal,
            goalMinutesRequired: 60,
            goalRewardMinutes: 0,
            maxDailyMatches: 2,
            deferBlockUntilMatchEnds: true,
            postMatchGraceSeconds: 60,
            verifyActiveStudy: true,
            oneMatchPerGoalBlock: true,
            blockApps: game.detection == .exactLeague,
            appListMode: .blockListed,
            apps: game.detection == .exactLeague ? LeagueMatchRules.defaultLoLApps : [],
            blockAction: .forceQuit,
            webListMode: .blockListed,
            domains: game.webEntries.joined(separator: ", "),
            webBlockAction: .redirect,
            motivationalMessage: "Cada \(game.unitSingular) de \(game.name) se gana con 60 min de estudio real.",
            protection: .challenge
        )
        rule.applyGame(game)
        return rule
    }

    /// Points the rule at another game, keeping study minutes, limits and protection.
    public mutating func applyGame(_ game: GameDefinition) {
        gameID = game.id
        matchMinutes = game.typicalMatchMinutes
        if maxDailyMatches == 0 { maxDailyMatches = 2 }
        deferBlockUntilMatchEnds = true
        if game.detection == .exactLeague {
            blockApps = true
            appListMode = .blockListed
            apps = LeagueMatchRules.defaultLoLApps
        }
        if !game.webEntries.isEmpty {
            webListMode = .blockListed
            domains = game.webEntries.joined(separator: ", ")
        }
    }
}

/// What a timed game rule has to do this second. Pure, so it is tested without any running game.
public enum TimedMatchPlanner {
    public enum FinishReason: Equatable, Sendable {
        case timeUp
        case gameClosed
        case userFinished
    }

    public enum Step: Equatable, Sendable {
        /// No match and nothing to do (the rule's normal blocking keeps the game closed while locked).
        case idle
        /// The game was opened while a match is available: start counting it.
        case start
        /// A match is running and there is time left before the overtime.
        case playing
        /// The typical length is over: warn once and let the overtime run.
        case overtime
        /// The match is over: count it and close the game if no more are available.
        case finish(FinishReason)
    }

    /// Closing the game ends the match only after this long away (a crash or a restart is not the end of a match).
    public static let closedToleranceSeconds: TimeInterval = 120
    /// ...and only once it has been played this long (opening and closing it to peek is not a match).
    public static let minPlayedSecondsToEndOnClose: TimeInterval = 300

    public static func step(
        rule: GeneralBlockRule,
        gameRunning: Bool,
        secondsSinceGameSeen: TimeInterval,
        workedTodaySeconds: TimeInterval,
        matchesToday: Int,
        now: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> Step {
        guard rule.enabled, rule.usesTimedMatches else { return .idle }
        if rule.activeMatchDeadline != nil {
            let remaining = rule.timedMatchRemainingSeconds(at: now, continuous: continuous)
            if remaining <= 0 { return .finish(.timeUp) }
            if !gameRunning,
               secondsSinceGameSeen >= closedToleranceSeconds,
               rule.timedMatchElapsedSeconds(at: now, continuous: continuous) >= minPlayedSecondsToEndOnClose {
                return .finish(.gameClosed)
            }
            return rule.isInTimedMatchOvertime(at: now, continuous: continuous) ? .overtime : .playing
        }
        guard gameRunning else { return .idle }
        let locked = rule.isEnforcing(
            at: now,
            workedTodaySeconds: workedTodaySeconds,
            matchesToday: matchesToday,
            continuous: continuous
        )
        return locked ? .idle : .start
    }
}
