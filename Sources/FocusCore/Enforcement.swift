import CryptoKit
import Foundation

// Everything in this file is pure logic with no AppKit: the rules that decide whether a session can be stopped,
// softened or escaped from. They are the part of FocusMe's design worth copying — a judge that is separate from
// the interface, so a mistaken click (or a changed system clock) cannot undo what you decided when you were calm.

// MARK: - Clock that cannot be wound forward

/// `Date()` follows the Mac's clock, so moving it forward two hours ends a two-hour block instantly.
/// `continuous` keeps counting across sleep and is immune to that, so every deadline is anchored to it and the
/// wall clock is only used to show times.
public enum TrustedClock {
    /// Seconds since boot, sleep included (`CLOCK_MONOTONIC` on Darwin is `mach_continuous_time`).
    public static func continuousSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// A jump of the system clock that the continuous clock did not see. Positive means the clock moved forward.
    public static func drift(wall: Date, continuous: Double, anchorWall: Date, anchorContinuous: Double) -> TimeInterval {
        let wallDelta = wall.timeIntervalSince(anchorWall)
        let realDelta = continuous - anchorContinuous
        return wallDelta - realDelta
    }

    /// Below this a drift is just NTP keeping the clock tidy; above it, somebody moved the clock.
    public static let suspiciousDrift: TimeInterval = 60
}

/// A deadline anchored to the continuous clock, with the wall-clock time kept only to show it.
public struct TrustedDeadline: Codable, Equatable, Sendable {
    public var continuousEnd: Double
    public var wallEnd: Date
    public var anchorWall: Date
    public var anchorContinuous: Double

    public init(seconds: TimeInterval, wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) {
        self.continuousEnd = continuous + max(0, seconds)
        self.wallEnd = wall.addingTimeInterval(max(0, seconds))
        self.anchorWall = wall
        self.anchorContinuous = continuous
    }

    public func remaining(continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        max(0, continuousEnd - continuous)
    }

    public func passed(continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        remaining(continuous: continuous) <= 0
    }

    /// The Mac was restarted, so the continuous clock started again from zero and the anchor is meaningless.
    /// The wall clock is all that is left; it is used, and the caller is told the guarantee was weaker this once.
    public func rebooted(continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        continuous < anchorContinuous
    }

    public func remainingAfterPossibleReboot(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        rebooted(continuous: continuous) ? max(0, wallEnd.timeIntervalSince(wall)) : remaining(continuous: continuous)
    }

    /// Seconds elapsed since this deadline passed (`0` while it has not passed yet).
    public func elapsedSincePassed(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        if rebooted(continuous: continuous) {
            return max(0, wall.timeIntervalSince(wallEnd))
        }
        return max(0, continuous - continuousEnd)
    }
}

// MARK: - How much a session defends itself

/// What FocusDesk asks for before letting you stop a session early. Chosen per task, when you are still calm.
public enum SessionProtection: String, Codable, CaseIterable, Sendable {
    /// Stop whenever you like. Good while you are trying out a schedule.
    case none
    /// Type a random string without pasting it: about half a minute of deliberate friction.
    case challenge
    /// Ask to stop, then wait: FocusDesk counts the wait, and the session keeps running meanwhile.
    case delay
    /// No early stop at all until the time runs out.
    case forced

    public var label: String {
        switch self {
        case .none: return "Se puede parar"
        case .challenge: return "Teclear un código"
        case .delay: return "Esperar unos minutos"
        case .forced: return "Hasta el final"
        }
    }

    public var explanation: String {
        switch self {
        case .none: return "Puedes pausar, cancelar o terminar cuando quieras."
        case .challenge: return "Para pausar o cancelar antes de tiempo tendrás que teclear un código aleatorio, sin pegarlo."
        case .delay: return "Pedir el final arranca una espera; la sesión sigue hasta que pasa. Puedes arrepentirte."
        case .forced: return "No se puede parar antes de tiempo. Solo el código de emergencia, y queda registrado."
        }
    }

    /// Where the way out of a session with this protection is, said wherever FocusDesk refuses something.
    public var wayOut: String {
        switch self {
        case .none: return ""
        case .challenge: return "Para pararla, pulsa Pausar o Cancelar y teclea el código."
        case .delay: return "Para pararla, pulsa Pausar o Cancelar y espera a que pase el tiempo."
        case .forced: return StopGate.emergencyHint
        }
    }

    /// Order from softest to hardest; the ratchet never lets a running session go down this list.
    public var strength: Int {
        switch self {
        case .none: return 0
        case .challenge: return 1
        case .delay: return 2
        case .forced: return 3
        }
    }
}

/// What happens to an app that is not in the task's list. Graduated, like FocusMe's `blockApp`: the gentle option
/// first, and never anything that loses your work unless you asked for it.
public enum AppBlockAction: String, Codable, CaseIterable, Sendable {
    /// Hide its windows and bring a work app back.
    case hide
    /// Ask the app to quit, the way ⌘Q does, so it can offer to save.
    case close
    /// Quit it without asking. Only for apps that ignore the polite request (launchers, games).
    case forceQuit

    public var label: String {
        switch self {
        case .hide: return "Ocultarla"
        case .close: return "Cerrarla"
        case .forceQuit: return "Forzar su cierre"
        }
    }

    public var explanation: String {
        switch self {
        case .hide: return "La esconde y te devuelve al trabajo. Nada se pierde."
        case .close: return "Le pide cerrarse como con ⌘Q: puede preguntarte si quieres guardar."
        case .forceQuit: return "La cierra sin preguntar. Útil con juegos y lanzadores que vuelven solos."
        }
    }

    public var strength: Int {
        switch self {
        case .hide: return 0
        case .close: return 1
        case .forceQuit: return 2
        }
    }

    /// What the punisher escalates to after too many attempts in a row.
    public var escalated: AppBlockAction {
        self == .hide ? .close : self
    }
}

/// What to do with a tab on a blocked site.
public enum WebBlockAction: String, Codable, CaseIterable, Sendable {
    /// Say so and write down the visit, but change nothing. What FocusDesk did until now.
    case warn
    /// Send only that tab to FocusDesk's own page, which says what is blocked and how long is left.
    case redirect
    /// Close only that tab, leaving the rest of the browser alone.
    case closeTab

    public var label: String {
        switch self {
        case .warn: return "Solo avisar"
        case .redirect: return "Llevar la pestaña a una página de bloqueo"
        case .closeTab: return "Cerrar esa pestaña"
        }
    }

    public var strength: Int {
        switch self {
        case .warn: return 0
        case .redirect: return 1
        case .closeTab: return 2
        }
    }
}

/// Whether the app list in a task or general rule is a whitelist (only those apps may stay open) or a blacklist
/// (only those apps are blocked while the rest of the Mac stays free). FocusMe's `appListType`.
public enum AppListMode: String, Codable, CaseIterable, Sendable {
    /// Only the apps in `apps` may stay in front; everything else is hidden or closed.
    case allowListed
    /// Only the apps in `apps` are hidden or closed; every other app stays open.
    case blockListed

    public var label: String {
        switch self {
        case .allowListed: return "Permitir solo estas apps (lista blanca)"
        case .blockListed: return "Bloquear estas apps (lista negra)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .allowListed: return "Permitir solo estas"
        case .blockListed: return "Bloquear estas"
        }
    }

    public var explanation: String {
        switch self {
        case .allowListed: return "Solo puedes usar las apps elegidas abajo; cualquier otra se oculta o se cierra."
        case .blockListed: return "Solo se bloquean las apps elegidas abajo; el resto del Mac queda libre."
        }
    }
}

/// Whether the website list in a task or general rule is a whitelist, a blacklist (domains or subpaths like
/// `youtube.com/shorts`), or blocks all websites. FocusMe's `urlListType`.
public enum WebListMode: String, Codable, CaseIterable, Sendable {
    /// Only the sites/paths in `domains` stay open.
    case allowListed
    /// Only the sites/paths in `domains` are blocked; the rest of the web stays open.
    case blockListed
    /// Every website in a browser is blocked.
    case blockAll

    public var label: String {
        switch self {
        case .allowListed: return "Permitir solo estas webs (lista blanca)"
        case .blockListed: return "Bloquear estas webs o rutas (lista negra)"
        case .blockAll: return "Bloquear todas las webs"
        }
    }

    public var shortLabel: String {
        switch self {
        case .allowListed: return "Permitir solo estas"
        case .blockListed: return "Bloquear estas"
        case .blockAll: return "Bloquear todas"
        }
    }
}

/// One-click distraction bundles (domains, subpaths and window title keywords) for the editors.
public enum DistractionPreset: String, CaseIterable, Identifiable, Sendable {
    case social
    case shortVideos
    case streaming
    case games

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .social: return "Redes sociales"
        case .shortVideos: return "Shorts y Reels"
        case .streaming: return "Vídeo y series"
        case .games: return "Juegos y tiendas"
        }
    }

    public var icon: String {
        switch self {
        case .social: return "bubble.left.and.bubble.right"
        case .shortVideos: return "play.rectangle.on.rectangle"
        case .streaming: return "tv"
        case .games: return "gamecontroller"
        }
    }

    public var domains: [String] {
        switch self {
        case .social:
            return ["x.com", "twitter.com", "instagram.com", "facebook.com", "tiktok.com", "reddit.com", "threads.net", "bsky.app"]
        case .shortVideos:
            return ["youtube.com/shorts", "instagram.com/reels", "tiktok.com", "facebook.com/reel"]
        case .streaming:
            return ["youtube.com", "netflix.com", "twitch.tv", "primevideo.com", "disneyplus.com", "max.com"]
        case .games:
            return ["store.steampowered.com", "steamcommunity.com", "epicgames.com", "itch.io", "roblox.com", "chess.com"]
        }
    }

    public var titleKeywords: [String] {
        switch self {
        case .social: return ["Instagram", "TikTok", "Reddit"]
        case .shortVideos: return ["Shorts", "Reels", "TikTok"]
        case .streaming: return ["Netflix", "Twitch", "Prime Video", "Disney+"]
        case .games: return ["Steam", "Epic Games"]
        }
    }
}

// MARK: - The challenge you have to type

public enum UnlockChallenge {
    /// No 0/O, 1/l/I: a typo you cannot even see is friction with no purpose.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")

    public static let lengthRange = 8...60

    public static func clampedLength(_ value: Int) -> Int {
        max(lengthRange.lowerBound, min(lengthRange.upperBound, value))
    }

    public static func make(length: Int) -> String {
        String((0..<clampedLength(length)).map { _ in alphabet.randomElement() ?? "A" })
    }

    /// Exact, including case: this is the whole point of the friction.
    public static func matches(typed: String, expected: String) -> Bool {
        !expected.isEmpty && typed == expected
    }

    /// How much of what you typed is still right, so the field can show where it went wrong.
    public static func correctPrefix(typed: String, expected: String) -> Int {
        var count = 0
        for (a, b) in zip(typed, expected) {
            if a != b { break }
            count += 1
        }
        return count
    }
}

// MARK: - The ratchet

/// A change to a running protected session, judged field by field. A ratchet turns one way: you can always make a
/// session harder on yourself, never easier, until it ends.
public enum RatchetVerdict: Equatable, Sendable {
    /// Nothing that matters to the block changed, or the change only makes it harder.
    case accepted
    /// Refused, with the reason to show.
    case refused(String)

    public var isAccepted: Bool { self == .accepted }
    public var reason: String? {
        if case .refused(let text) = self { return text }
        return nil
    }
}

/// One way a change makes a protected task easier to escape. Kept apart from the words, because the same change is
/// said one way while the session runs («No se puede acortar…») and another when it is about to start («Acortarla»).
public enum Loosening: Equatable, Sendable {
    case appBlockRemoved
    case weakerProtection(SessionProtection)
    case shorter
    case shorterCode(Int)
    case shorterWait(Int)
    case softerAppAction
    case softerWebAction
    case moreAllowedApps
    case noAllowedApps
    case moreAllowedDomains
    case systemPanesUnguarded
    case punisherRemoved
    case foldersUnblocked
    case appsUnblocked
    case domainsUnblocked
    case titleKeywordsRemoved

    /// What FocusDesk says when the session is running.
    public var whileRunning: String {
        switch self {
        case .appBlockRemoved: return "No se puede quitar el bloqueo de apps mientras la sesión está en marcha."
        case .weakerProtection(let current): return "No se puede rebajar la protección («\(current.label)») con la sesión en marcha."
        case .shorter: return "No se puede acortar la sesión en marcha. Alargarla sí."
        case .shorterCode(let chars): return "El código de desbloqueo no puede acortarse ahora (eran \(chars) caracteres)."
        case .shorterWait(let minutes): return "La espera para parar no puede acortarse ahora (eran \(minutes) minutos)."
        case .softerAppAction: return "No se puede suavizar qué hace FocusDesk con las apps que distraen mientras la sesión corre."
        case .softerWebAction: return "No se puede suavizar el bloqueo de webs mientras la sesión corre."
        case .moreAllowedApps: return "No se pueden añadir apps permitidas con la sesión en marcha. Quitarlas sí."
        case .noAllowedApps: return "Sin apps permitidas el bloqueo no tendría a dónde devolverte. Deja al menos una."
        case .moreAllowedDomains: return "No se pueden añadir dominios permitidos mientras la sesión bloquea webs."
        case .systemPanesUnguarded: return "La protección de «Privacidad y seguridad» y «Fecha y hora» no se quita con la sesión en marcha."
        case .punisherRemoved: return "El endurecimiento tras varios intentos seguidos no se quita con la sesión en marcha."
        case .foldersUnblocked: return "No se pueden desbloquear carpetas con la sesión en marcha. Bloquear más sí."
        case .appsUnblocked: return "No se pueden desbloquear apps ni pasar de lista blanca a lista negra con la sesión en marcha."
        case .domainsUnblocked: return "No se pueden desbloquear webs ni abrir más dominios mientras la sesión bloquea webs."
        case .titleKeywordsRemoved: return "No se pueden quitar palabras bloqueadas del título de ventana con la sesión en marcha."
        }
    }

    /// The same change named as an action, for a task that is about to start: «Rebajar su protección».
    public var asAction: String {
        switch self {
        case .appBlockRemoved: return "Quitarle el bloqueo de apps"
        case .weakerProtection: return "Rebajar su protección"
        case .shorter: return "Acortarla"
        case .shorterCode: return "Acortar su código de desbloqueo"
        case .shorterWait: return "Acortar su espera para parar"
        case .softerAppAction: return "Suavizar lo que hace con las apps que distraen"
        case .softerWebAction: return "Suavizar su bloqueo de webs"
        case .moreAllowedApps: return "Añadirle apps permitidas"
        case .noAllowedApps: return "Dejarla sin apps permitidas"
        case .moreAllowedDomains: return "Añadirle dominios permitidos"
        case .systemPanesUnguarded: return "Quitarle la protección de Ajustes"
        case .punisherRemoved: return "Quitarle el endurecimiento tras varios intentos"
        case .foldersUnblocked: return "Desbloquearle carpetas"
        case .appsUnblocked: return "Desbloquearle apps"
        case .domainsUnblocked: return "Desbloquearle webs"
        case .titleKeywordsRemoved: return "Quitarle palabras bloqueadas del título"
        }
    }
}

public enum Ratchet {
    /// Judges `proposed` against `current` for a session that is being enforced right now.
    /// `current` is what the session is running with; `proposed` is what the editor wants to save.
    public static func judge(current: FocusTask, proposed: FocusTask) -> RatchetVerdict {
        loosening(current: current, proposed: proposed).map { .refused($0.whileRunning) } ?? .accepted
    }

    /// The first field in which `proposed` is easier to escape than `current`, or nil when it is not.
    public static func loosening(current: FocusTask, proposed: FocusTask) -> Loosening? {
        if current.strict && !proposed.strict { return .appBlockRemoved }
        if proposed.protection.strength < current.protection.strength { return .weakerProtection(current.protection) }
        if proposed.minutes < current.minutes { return .shorter }
        if proposed.unlockChars < current.unlockChars { return .shorterCode(current.unlockChars) }
        if proposed.stopDelayMinutes < current.stopDelayMinutes { return .shorterWait(current.stopDelayMinutes) }
        if proposed.blockAction.strength < current.blockAction.strength { return .softerAppAction }
        if proposed.webBlockAction.strength < current.webBlockAction.strength { return .softerWebAction }
        let currentApps = Set(current.apps.map(\.id))
        let proposedApps = Set(proposed.apps.map(\.id))
        if current.appListMode == .allowListed && proposed.appListMode == .blockListed && current.strict {
            return .appsUnblocked
        }
        if current.appListMode == .allowListed {
            // The app list is a list of what IS allowed: adding to it widens the hole, removing narrows it.
            if !proposedApps.subtracting(currentApps).isEmpty { return .moreAllowedApps }
            if current.strict && proposedApps.isEmpty { return .noAllowedApps }
        } else {
            // In blacklist mode, removing an app from the blocked list opens a hole.
            if current.strict && !currentApps.isSubset(of: proposedApps) { return .appsUnblocked }
        }
        if current.webBlockAction != .warn {
            if current.webListMode == .blockAll && proposed.webListMode != .blockAll {
                return .domainsUnblocked
            }
            if current.webListMode == .allowListed && proposed.webListMode == .blockListed {
                return .domainsUnblocked
            }
            let currentDomains = Set(FocusRules.parseDomains(current.domains).valid)
            let proposedDomains = Set(FocusRules.parseDomains(proposed.domains).valid)
            if current.webListMode == .allowListed && proposed.webListMode == .allowListed {
                if !proposedDomains.subtracting(currentDomains).isEmpty { return .moreAllowedDomains }
            } else if current.webListMode == .blockListed && proposed.webListMode == .blockListed {
                if !currentDomains.isSubset(of: proposedDomains) { return .domainsUnblocked }
            }
        }
        let currentKeywords = Set(FocusRules.parseTitleKeywords(current.blockedTitleKeywords).map { $0.lowercased() })
        let proposedKeywords = Set(FocusRules.parseTitleKeywords(proposed.blockedTitleKeywords).map { $0.lowercased() })
        if !currentKeywords.isSubset(of: proposedKeywords) { return .titleKeywordsRemoved }
        if current.guardSystemPanes && !proposed.guardSystemPanes { return .systemPanesUnguarded }
        if current.punisherEnabled && !proposed.punisherEnabled { return .punisherRemoved }
        // Blocked folders are the opposite list: what is closed. Taking one out opens a hole.
        let blockedNow = Set(FolderRules.normalizeList(current.blockedFolders).map { $0.lowercased() })
        let blockedNext = Set(FolderRules.normalizeList(proposed.blockedFolders).map { $0.lowercased() })
        if !blockedNow.isSubset(of: blockedNext) { return .foldersUnblocked }
        return nil
    }
}

// MARK: - Protected before it starts

/// FocusMe's `activeProtectionRunUp`. At 8:55 a task that starts at 9:00 has «not started yet», and deleting it is
/// free: the exact moment the impulse wins. From `minutes` before its start until its planned end, a protected task
/// defends itself, and anything that puts it off or softens it costs what stopping it would cost — the code, the
/// wait or the emergency exit. Doing it earlier, for longer or more strictly stays free.
public enum RunUp {
    public static let defaultMinutes = 10
    /// What Ajustes offers; 0 switches it off.
    public static let choices = [0, 5, 10, 15, 30, 60]

    public static func clampedMinutes(_ value: Int) -> Int { max(0, min(120, value)) }

    /// The stretch of time in which `task` protects itself, or nil when it never does.
    public static func window(for task: FocusTask, minutes: Int) -> DateInterval? {
        let lead = clampedMinutes(minutes)
        guard lead > 0, task.protection != .none, task.isScheduled, !task.completed else { return nil }
        let from = task.scheduledAt.addingTimeInterval(-Double(lead) * 60)
        guard task.end > from else { return nil }
        return DateInterval(start: from, end: task.end)
    }

    /// True when `task` is inside its window and has not been worked on in it. A session started in the window and
    /// stopped through its own way out already paid; leaving the task afterwards is not charged twice.
    public static func isArmed(_ task: FocusTask, minutes: Int, now: Date, sessionStarts: [Date] = []) -> Bool {
        guard let window = window(for: task, minutes: minutes), now >= window.start, now < window.end else { return false }
        return !sessionStarts.contains { $0 >= window.start && $0 < window.end }
    }

    /// What `proposed` would do to an armed task, named as an action («Retrasarla»), or nil when it only makes the
    /// task sooner, longer or stricter. `nil` as `proposed` means deleting it.
    public static func loosening(current: FocusTask, proposed: FocusTask?, calendar: Calendar = .current) -> String? {
        guard let proposed else { return "Borrarla" }
        if !proposed.isScheduled { return "Pasarla a la bandeja" }
        if proposed.completed && !current.completed { return "Marcarla como hecha sin hacerla" }
        let day = FocusRules.dayKey(for: current.scheduledAt, calendar: calendar)
        if proposed.skippedDates.contains(day) && !current.skippedDates.contains(day) { return "Saltársela" }
        // Half a minute of slack: rounding a time in the editor is not putting the task off.
        if proposed.scheduledAt > current.scheduledAt.addingTimeInterval(30) { return "Retrasarla" }
        if current.autoStart && !proposed.autoStart { return "Quitarle el inicio automático" }
        return Ratchet.loosening(current: current, proposed: proposed)?.asAction
    }
}

// MARK: - Folders that close when they are opened

/// FocusMe's «Finder locations»: sometimes the distraction is a folder — films, comics, installers — and not an app
/// or a website. Paths are compared folder by whole folder and without caring about case, like APFS does.
public enum FolderRules {
    /// «~/Series/» → «/Users/luis/Series». Symbolic links are resolved, so another path to the same folder is the
    /// same folder.
    public static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        // Links are only resolved in parts that exist, so resolve the deepest folder that does and put the rest
        // back on top: «atajo/ep1.mp4» through a link to «Series» has to come out as «Series/ep1.mp4».
        var existing = URL(fileURLWithPath: expanded).standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in rest { resolved.appendPathComponent(component) }
        var result = resolved.path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Normalized, without empties or repeats, in the order given.
    public static func normalizeList(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths {
            let clean = normalize(path)
            guard !clean.isEmpty, seen.insert(clean.lowercased()).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    /// The blocked folder that is `path` or contains it. «Series» blocks «Series/T1/ep1.mp4», not «Series 2».
    public static func blockingFolder(for path: String, in folders: [String]) -> String? {
        let target = normalize(path).lowercased()
        guard !target.isEmpty else { return nil }
        return folders.first { folder in
            let blocked = normalize(folder).lowercased()
            return !blocked.isEmpty && (target == blocked || target.hasPrefix(blocked + "/"))
        }
    }

    /// Why a folder cannot be blocked, or nil. Closing these would close everything, FocusDesk's own data included.
    public static func problem(with path: String, home: String = NSHomeDirectory()) -> String? {
        let clean = normalize(path)
        guard !clean.isEmpty else { return "Elige una carpeta." }
        let lowered = clean.lowercased()
        let homeFolder = normalize(home).lowercased()
        let vital: Set<String> = ["/", "/users", "/system", "/applications", "/library", "/volumes", "/private",
                                  homeFolder, homeFolder + "/library", homeFolder + "/applications"]
        if vital.contains(lowered) {
            return "«\(name(of: clean))» no se puede bloquear: el Mac la necesita para funcionar."
        }
        if homeFolder.hasPrefix(lowered + "/") {
            return "«\(name(of: clean))» contiene tu carpeta de usuario: bloquearla lo bloquearía todo."
        }
        return nil
    }

    public static func name(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}

// MARK: - Asking to stop

/// What FocusDesk answers when you ask to pause, cancel or finish a protected session early.
public enum StopDecision: Equatable, Sendable {
    /// Go ahead.
    case allowed
    /// Type this string first.
    case challenge(String)
    /// The wait just started; this is how long it is.
    case waitStarted(TimeInterval)
    /// A wait is already running; this is what is left of it.
    case waiting(TimeInterval)
    /// The wait finished: the stop goes through.
    case waitFinished
    /// Not possible, with the reason.
    case refused(String)
}

/// Why the session is being stopped. Finishing on time is never protected: the protection exists to stop you
/// escaping early, not to keep you working past the end.
public enum StopReason: String, Codable, Equatable, Sendable {
    case pause
    case cancel
    case finishEarly

    public var verb: String {
        switch self {
        case .pause: return "pausar"
        case .cancel: return "cancelar"
        case .finishEarly: return "terminar antes de tiempo"
        }
    }
}

/// The state of a pending "I want to stop" request, kept with the session so quitting the app does not clear it.
/// Includes FocusMe's `inactiveDelayLength` confirmation window (`confirmWindowSeconds`): once the wait finishes,
/// you have a few minutes to confirm the stop; if you keep working instead, the request expires and the lock re-arms.
public struct StopRequest: Codable, Equatable, Sendable {
    public static let defaultConfirmWindowSeconds: TimeInterval = 180
    public var reason: StopReason
    public var deadline: TrustedDeadline
    public var armedAt: Date
    public var confirmWindowSeconds: TimeInterval

    public init(
        reason: StopReason,
        minutes: Int,
        confirmWindowSeconds: TimeInterval = StopRequest.defaultConfirmWindowSeconds,
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        self.reason = reason
        self.deadline = TrustedDeadline(seconds: Double(max(1, minutes)) * 60, wall: wall, continuous: continuous)
        self.armedAt = wall
        self.confirmWindowSeconds = max(30, confirmWindowSeconds)
    }

    enum CodingKeys: String, CodingKey {
        case reason, deadline, armedAt, confirmWindowSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = try c.decode(StopReason.self, forKey: .reason)
        deadline = try c.decode(TrustedDeadline.self, forKey: .deadline)
        armedAt = try c.decodeIfPresent(Date.self, forKey: .armedAt) ?? Date()
        confirmWindowSeconds = max(30, try c.decodeIfPresent(TimeInterval.self, forKey: .confirmWindowSeconds) ?? Self.defaultConfirmWindowSeconds)
    }

    public func remaining(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        deadline.remainingAfterPossibleReboot(wall: wall, continuous: continuous)
    }

    public func ready(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        remaining(wall: wall, continuous: continuous) <= 0 && !expired(wall: wall, continuous: continuous)
    }

    /// True when the wait finished and the confirmation window (`confirmWindowSeconds`) also elapsed without the user stopping.
    public func expired(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        guard remaining(wall: wall, continuous: continuous) <= 0 else { return false }
        return deadline.elapsedSincePassed(wall: wall, continuous: continuous) > confirmWindowSeconds
    }

    /// Seconds left in the confirmation window once `ready()` is true.
    public func confirmWindowRemaining(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        guard remaining(wall: wall, continuous: continuous) <= 0 else { return confirmWindowSeconds }
        return max(0, confirmWindowSeconds - deadline.elapsedSincePassed(wall: wall, continuous: continuous))
    }
}

public enum StopGate {
    /// Decides what has to happen before a protected session can stop.
    /// `timeLeft` is what the countdown still has: with none left, nothing is protected any more.
    public static func decide(
        protection: SessionProtection,
        reason: StopReason,
        timeLeft: TimeInterval,
        unlockChars: Int,
        stopDelayMinutes: Int,
        pending: StopRequest?,
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> StopDecision {
        guard timeLeft > 0 else { return .allowed }
        switch protection {
        case .none:
            return .allowed
        case .challenge:
            return .challenge(UnlockChallenge.make(length: unlockChars))
        case .delay:
            if let pending, pending.reason == reason, !pending.expired(wall: wall, continuous: continuous) {
                return pending.ready(wall: wall, continuous: continuous)
                    ? .waitFinished
                    : .waiting(pending.remaining(wall: wall, continuous: continuous))
            }
            return .waitStarted(Double(max(1, stopDelayMinutes)) * 60)
        case .forced:
            let left = FocusRules.clock(timeLeft)
            return .refused("«Hasta el final»: no se puede \(reason.verb) esta sesión. Le quedan \(left). \(emergencyHint)")
        }
    }

    /// Every refusal says where the way out is: a block nobody can find the exit of is a trap, not a block.
    public static let emergencyHint = "Si de verdad pasa algo, usa «Emergencia» (el escudo junto a Pausar): 60 caracteres y queda anotada."
}

// MARK: - Closed by the Mac, not by the user

/// The reason macOS gives when it asks every app to quit. A restart or a shutdown must never be stopped by a
/// session: that is how somebody ends up holding the power button and losing work in every other app.
public enum SystemQuit {
    /// `kAEQuitReason` values (AERegistry.h): quit all, shutdown, restart, log out and their confirmation dialogs.
    public static let reasonCodes: Set<UInt32> = [
        fourCharCode("quia"), fourCharCode("shut"), fourCharCode("rest"),
        fourCharCode("rlgo"), fourCharCode("logo"), fourCharCode("rrst"), fourCharCode("rsdn")
    ]

    public static func isSystemQuit(reasonCode: UInt32?) -> Bool {
        guard let reasonCode else { return false }
        return reasonCodes.contains(reasonCode)
    }

    static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - Coming back after FocusDesk went away

/// What the login-item watcher decides when it finds FocusDesk is not running. Kept pure so the rules that bring
/// the app back — and, above all, the ones that stop it from coming back in a loop — can be tested.
public enum RelaunchDecision {
    /// At most this many relaunches inside `window`: a FocusDesk that crashes on launch must not bounce forever.
    public static let maxRelaunches = 3
    public static let window: TimeInterval = 180
    /// A watcher younger than this has just been started by a log-in, not lived through a log-out.
    public static let startupGrace: TimeInterval = 90

    public static func shouldRelaunch(
        session: WorkSession?,
        hasActiveProtectedRule: Bool = false,
        appRunning: Bool,
        watcherAge: TimeInterval,
        recentRelaunches: Int,
        now: Date = Date()
    ) -> Bool {
        guard !appRunning, recentRelaunches < maxRelaunches else { return false }
        if hasActiveProtectedRule && watcherAge >= startupGrace { return true }
        guard let session else { return false }
        // Killed or crashed mid-session: what was saved last still says it was running.
        if session.runningSince != nil { return session.shouldResumeAfterRelaunch(now: now) }
        // Closed by a restart or a log-out: only right after logging back in. While the Mac is logging out the
        // watcher is old, and relaunching then would get in the way of the very restart this exists to allow.
        if session.resumeOnLaunchUntil != nil, watcherAge < startupGrace {
            return session.shouldResumeAfterRelaunch(now: now)
        }
        return false
    }
}

// MARK: - The punisher

/// Trying the same blocked app or site over and over is the impulse winning. After a few tries in a short window,
/// the block gets harder for a while — FocusMe's `punisher`, with a plain explanation instead of a silent change.
public struct DistractionPunisher: Codable, Equatable, Sendable {
    /// Attempts inside `window` that set it off.
    public var maxAttempts: Int
    public var window: TimeInterval
    /// How long the harder block lasts.
    public var duration: TimeInterval
    /// Continuous-clock instants of the recent attempts.
    public var recent: [Double]
    public var activeUntil: Double?
    /// How many times it has gone off in this session, for the history.
    public var timesTriggered: Int

    public init(maxAttempts: Int = 4, window: TimeInterval = 180, duration: TimeInterval = 600) {
        self.maxAttempts = max(2, maxAttempts)
        self.window = max(30, window)
        self.duration = max(60, duration)
        self.recent = []
        self.activeUntil = nil
        self.timesTriggered = 0
    }

    public func isActive(at continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        guard let activeUntil else { return false }
        return continuous < activeUntil
    }

    public func remaining(at continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        guard let activeUntil else { return 0 }
        return max(0, activeUntil - continuous)
    }

    /// Records one blocked attempt. Returns true the moment the punisher switches on.
    @discardableResult
    public mutating func register(at continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        recent.removeAll { continuous - $0 > window }
        recent.append(continuous)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        guard !isActive(at: continuous), recent.count >= maxAttempts else { return false }
        activeUntil = continuous + duration
        timesTriggered += 1
        recent.removeAll()
        return true
    }

    public mutating func clear() {
        recent.removeAll()
        activeUntil = nil
    }
}

// MARK: - The witness in the Keychain

/// A fingerprint of the running protected session. The app stores it outside its own data file (in the Keychain),
/// so closing FocusDesk and editing — or deleting — `workspace.json` does not quietly end a block.
public struct SessionWitness: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var taskTitle: String
    public var protection: SessionProtection
    public var deadline: TrustedDeadline
    public var digest: String

    public init(sessionID: UUID, taskTitle: String, protection: SessionProtection, deadline: TrustedDeadline) {
        self.sessionID = sessionID
        self.taskTitle = taskTitle
        self.protection = protection
        self.deadline = deadline
        self.digest = Self.digest(sessionID: sessionID, taskTitle: taskTitle, protection: protection, deadline: deadline)
    }

    public var intact: Bool {
        digest == Self.digest(sessionID: sessionID, taskTitle: taskTitle, protection: protection, deadline: deadline)
    }

    /// Still worth enforcing: untampered, protected and with time left.
    public func live(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        intact && protection != .none && deadline.remainingAfterPossibleReboot(wall: wall, continuous: continuous) > 0
    }

    public func remaining(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        deadline.remainingAfterPossibleReboot(wall: wall, continuous: continuous)
    }

    static func digest(sessionID: UUID, taskTitle: String, protection: SessionProtection, deadline: TrustedDeadline) -> String {
        let material = [
            sessionID.uuidString,
            taskTitle,
            protection.rawValue,
            String(format: "%.0f", deadline.continuousEnd),
            String(format: "%.0f", deadline.wallEnd.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Which websites and windows count

public enum WebRules {
    /// Browsers FocusDesk can read and steer.
    public enum BrowserKind: String, Codable, Equatable, Sendable {
        case safari
        case chromium
        /// Browsers whose address bar is read through macOS Accessibility (`AXUIElement`) and whose active tab can be closed or navigated (Firefox, Zen, DuckDuckGo, Waterfox).
        case accessibility
    }

    public static let browsers: [String: BrowserKind] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.operasoftware.Opera": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.duckduckgo.macos.browser": .accessibility,
        "org.mozilla.firefox": .accessibility,
        "org.mozilla.firefoxdeveloperedition": .accessibility,
        "org.mozilla.nightly": .accessibility,
        "app.zen-browser.zen": .accessibility,
        "net.waterfox.waterfox": .accessibility
    ]

    public static func browserKind(for bundleID: String) -> BrowserKind? { browsers[bundleID] }
    public static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    /// Browsers that do not expose their address bar via AppleScript or Accessibility.
    public static let unreadableBrowsers: Set<String> = [
        "org.torproject.torbrowser",
        "com.kagi.kagimacOS"
    ]

    /// Normalizes a custom productive redirect URL (`websiteRedirectUrl` in FocusMe), e.g. `"notion.so"` -> `https://notion.so`.
    public static func normalizedRedirectURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// A site saved as an app from Safari's File › Add to Dock: its own bundle, its address out of reach.
    public static func looksLikeSafariWebApp(bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.Safari.WebApp")
    }

    /// Bundle ids that are a Chromium web app (a "PWA") rather than a real application: Chrome, Brave and Edge
    /// all name them this way, and each one wraps a single site.
    public static func looksLikeChromiumWebApp(bundleID: String) -> Bool {
        bundleID.contains(".app.") && (
            bundleID.hasPrefix("com.google.Chrome") ||
            bundleID.hasPrefix("com.brave.Browser") ||
            bundleID.hasPrefix("com.microsoft.edgemac") ||
            bundleID.hasPrefix("org.chromium.Chromium")
        )
    }
}

/// Auto-expiring temporary exception for a specific website/subpath or app bundle ID (FocusMe's `setAllowExpiryMinutes`).
/// Automatically stops applying the instant `deadline` expires, so a 5-minute check never turns into a 2-hour distraction.
public struct TemporaryAllowEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Normalized domain/subpath (`"youtube.com"`) or app bundle ID (`"com.tinyspeck.slackmacgap"`).
    public var target: String
    public var isAppBundleID: Bool
    public var label: String
    public var deadline: TrustedDeadline

    public init(
        id: UUID = UUID(),
        target: String,
        isAppBundleID: Bool = false,
        label: String? = nil,
        minutes: Int = 5,
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        self.id = id
        let cleanTarget = isAppBundleID
            ? target.trimmingCharacters(in: .whitespacesAndNewlines)
            : (FocusRules.normalizeDomainEntry(target) ?? target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        self.target = cleanTarget
        self.isAppBundleID = isAppBundleID
        self.label = label ?? cleanTarget
        self.deadline = TrustedDeadline(seconds: Double(max(1, min(120, minutes))) * 60, wall: wall, continuous: continuous)
    }

    public func remaining(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        deadline.remainingAfterPossibleReboot(wall: wall, continuous: continuous)
    }

    public func isActive(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        remaining(wall: wall, continuous: continuous) > 0
    }
}

/// Fingerprint + backup of enabled protected `GeneralBlockRule`s kept in the Keychain (`SettingsWitness` in FocusMe),
/// so quitting FocusDesk when a scheduled/daily rule is not yet enforcing and deleting it from `workspace.json` is caught and restored.
public struct ProtectedRulesWitness: Codable, Equatable, Sendable {
    public var rules: [GeneralBlockRule]
    public var savedAt: Date
    public var digest: String

    public init(rules: [GeneralBlockRule], savedAt: Date = Date()) {
        let protected = rules.filter { $0.enabled && $0.protection != .none }
        self.rules = protected
        self.savedAt = savedAt
        self.digest = Self.computeDigest(rules: protected)
    }

    public var intact: Bool {
        digest == Self.computeDigest(rules: rules)
    }

    public var isEmpty: Bool {
        rules.isEmpty
    }

    static func computeDigest(rules: [GeneralBlockRule]) -> String {
        let material = rules
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.name):\($0.kind.rawValue):\($0.protection.rawValue):\($0.domains)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Panes of System Settings that end a block if you reach them: Accessibility lives under one, the clock under
/// another. The rest of System Settings (Wi-Fi, sound, displays) must keep working during a session.
public enum GuardedSettingsPane: String, CaseIterable, Sendable {
    case privacy
    case dateTime
    case users

    /// Matched against the selected row of the sidebar, in Spanish and English.
    public var names: [String] {
        switch self {
        case .privacy: return ["privacidad y seguridad", "privacy & security", "privacy and security", "seguridad y privacidad"]
        case .dateTime: return ["fecha y hora", "date & time", "date and time"]
        case .users: return ["usuarios y grupos", "users & groups", "users and groups"]
        }
    }

    public var explanation: String {
        switch self {
        case .privacy: return "Desde «Privacidad y seguridad» se puede quitar el permiso que FocusDesk necesita para bloquear."
        case .dateTime: return "Desde «Fecha y hora» se puede adelantar el reloj del Mac para acabar la sesión antes."
        case .users: return "Desde «Usuarios y grupos» se puede crear otro usuario y saltarse el bloqueo."
        }
    }

    public static func match(selectedRow: String) -> GuardedSettingsPane? {
        let normalized = selectedRow
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return allCases.first { pane in
            pane.names.contains { candidate in
                let folded = candidate.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
                return normalized == folded || normalized.contains(folded)
            }
        }
    }
}

// MARK: - General blocking rules & daily usage timers

/// How a general block rule is triggered: a daily usage timer/budget, a work-goal reward, launch limits with cooldown, a direct countdown, a recurring schedule, or 24/7.
public enum GeneralRuleKind: String, Codable, CaseIterable, Sendable {
    /// Allows up to `dailyLimitMinutes` per day on the rule's apps/sites/titles, counting down in real time; once exhausted, blocks for the rest of the day.
    case dailyLimit
    /// Keeps targets blocked until you complete `goalMinutesRequired` of focused task sessions today (or unlocks `goalRewardMinutes` per `goalMinutesRequired` worked). FocusMe's `tickAsTimeGoal`.
    case workGoal
    /// Limits how many times per day (`maxDailyLaunches`) you may open the targets, how long each visit lasts (`maxLaunchDurationMinutes`), and enforces a cooldown (`launchCooldownMinutes`) between visits. FocusMe's `tickAsLaunchLimit`.
    case launchLimit
    /// Blocks immediately for a chosen countdown (`countdownMinutes` or a quick preset).
    case countdown
    /// Blocks automatically during a recurring weekday time window (`startMinutes`...`endMinutes`).
    case schedule
    /// Blocks permanently while the rule is switched on.
    case alwaysOn

    public var label: String {
        switch self {
        case .dailyLimit: return "Temporizador de uso diario (presupuesto)"
        case .workGoal: return "Primero el trabajo, luego el ocio (meta / recompensa)"
        case .launchLimit: return "Límite de aperturas diarias y enfriamiento"
        case .countdown: return "Temporizador de bloqueo directo"
        case .schedule: return "Horario automático"
        case .alwaysOn: return "Siempre activo (24/7)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .dailyLimit: return "Límite diario"
        case .workGoal: return "Meta de enfoque"
        case .launchLimit: return "Aperturas"
        case .countdown: return "Temporizador"
        case .schedule: return "Horario"
        case .alwaysOn: return "24/7"
        }
    }

    public var icon: String {
        switch self {
        case .dailyLimit: return "hourglass"
        case .workGoal: return "trophy"
        case .launchLimit: return "door.left.hand.closed"
        case .countdown: return "timer"
        case .schedule: return "calendar.badge.clock"
        case .alwaysOn: return "lock.shield"
        }
    }

    public var explanation: String {
        switch self {
        case .dailyLimit:
            return "Cuenta el tiempo real que pasas hoy en esas apps o webs. Mientras queda presupuesto puedes usarlas; al llegar a 00:00 se bloquean hasta mañana."
        case .workGoal:
            return "Mantiene bloqueadas las distracciones hasta que trabajes en tus tareas de hoy el tiempo objetivo (o te concede minutos de recompensa por cada bloque trabajado)."
        case .launchLimit:
            return "Limita cuántas veces al día puedes abrir una app o web, cuánto dura cada visita y obliga a un tiempo de enfriamiento entre una visita y la siguiente."
        case .countdown:
            return "Bloquea de inmediato durante el tiempo que elijas (15 min, 30 min, 1 h, 2 h o resto del día) sin tener que crear una tarea en la agenda."
        case .schedule:
            return "Se activa y desactiva solo entre las horas y los días de la semana elegidos (admite tramos nocturnos como 23:00–07:00)."
        case .alwaysOn:
            return "Mantiene el bloqueo activo de forma permanente mientras la regla esté encendida."
        }
    }
}

/// A standalone FocusMe-style plan/rule that works independently of agenda sessions.
public struct GeneralBlockRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var kind: GeneralRuleKind
    /// Daily usage budget in minutes when `kind == .dailyLimit` (1...720).
    public var dailyLimitMinutes: Int
    /// Focused task minutes required today when `kind == .workGoal` (5...720).
    public var goalMinutesRequired: Int
    /// Reward minutes unlocked per `goalMinutesRequired` worked today (`0` = unlimited for the rest of today once goal is reached).
    public var goalRewardMinutes: Int
    /// Maximum number of launches/visits allowed per day when `kind == .launchLimit` (1...50).
    public var maxDailyLaunches: Int
    /// Maximum duration in minutes of each launch visit when `kind == .launchLimit` (1...120).
    public var maxLaunchDurationMinutes: Int
    /// Mandatory cooldown in minutes between launch visits when `kind == .launchLimit` (0...360).
    public var launchCooldownMinutes: Int
    /// Deadline of the currently open launch visit (`kind == .launchLimit`).
    public var activeLaunchDeadline: TrustedDeadline?
    /// Deadline of the mandatory cooldown after a launch visit (`kind == .launchLimit`).
    public var launchCooldownDeadline: TrustedDeadline?
    /// Default countdown duration in minutes when `kind == .countdown` (5...720).
    public var countdownMinutes: Int
    /// Active monotonic + wall-clock deadline when `kind == .countdown`.
    public var activeDeadline: TrustedDeadline?
    /// Calendar weekday numbers (`1` = Sunday ... `7` = Saturday) when `kind == .schedule`.
    public var scheduleDays: Set<Int>
    /// Minutes from midnight (`0...1439`) when the schedule starts.
    public var startMinutes: Int
    /// Minutes from midnight (`0...1439`) when the schedule ends. If `<= startMinutes`, spans midnight.
    public var endMinutes: Int
    public var blockApps: Bool
    public var appListMode: AppListMode
    public var apps: [AllowedApp]
    public var blockAction: AppBlockAction
    public var webListMode: WebListMode
    public var domains: String
    public var webBlockAction: WebBlockAction
    /// Optional productive URL (`https://...`) to redirect blocked tabs to instead of the local block page (`websiteRedirectUrl` in FocusMe).
    public var customRedirectURL: String
    /// Custom motivational message or quote shown on the block page.
    public var motivationalMessage: String
    public var blockedTitleKeywords: String
    public var blockedFolders: [String]
    public var protection: SessionProtection
    public var unlockChars: Int
    public var stopDelayMinutes: Int
    public var guardSystemPanes: Bool
    public var punisherEnabled: Bool
    /// Number of short micro-pauses allowed per day (`0` = disabled, `1...10`). FocusMe's `pauseCount`.
    public var dailyMicroPausesAllowed: Int
    /// Duration in minutes of each micro-pause before the rule automatically re-locks (`1...30`). FocusMe's `pauseLength`.
    public var microPauseMinutes: Int
    /// Active micro-pause deadline; while remaining > 0, `isEnforcing` is false and re-locks automatically when it expires.
    public var activeMicroPauseDeadline: TrustedDeadline?
    public var stopRequest: StopRequest?
    public var punisher: DistractionPunisher

    public init(
        id: UUID = UUID(),
        name: String = "",
        enabled: Bool = true,
        kind: GeneralRuleKind = .dailyLimit,
        dailyLimitMinutes: Int = 20,
        goalMinutesRequired: Int = 60,
        goalRewardMinutes: Int = 0,
        maxDailyLaunches: Int = 5,
        maxLaunchDurationMinutes: Int = 5,
        launchCooldownMinutes: Int = 30,
        activeLaunchDeadline: TrustedDeadline? = nil,
        launchCooldownDeadline: TrustedDeadline? = nil,
        countdownMinutes: Int = 60,
        activeDeadline: TrustedDeadline? = nil,
        scheduleDays: Set<Int> = [1, 2, 3, 4, 5, 6, 7],
        startMinutes: Int = 9 * 60,
        endMinutes: Int = 19 * 60,
        blockApps: Bool = false,
        appListMode: AppListMode = .blockListed,
        apps: [AllowedApp] = [],
        blockAction: AppBlockAction = .hide,
        webListMode: WebListMode = .blockListed,
        domains: String = "",
        webBlockAction: WebBlockAction = .redirect,
        customRedirectURL: String = "",
        motivationalMessage: String = "",
        blockedTitleKeywords: String = "",
        blockedFolders: [String] = [],
        protection: SessionProtection = .challenge,
        unlockChars: Int = 24,
        stopDelayMinutes: Int = 5,
        guardSystemPanes: Bool = true,
        punisherEnabled: Bool = true,
        dailyMicroPausesAllowed: Int = 2,
        microPauseMinutes: Int = 5,
        activeMicroPauseDeadline: TrustedDeadline? = nil,
        stopRequest: StopRequest? = nil,
        punisher: DistractionPunisher = DistractionPunisher()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.dailyLimitMinutes = max(1, min(720, dailyLimitMinutes))
        self.goalMinutesRequired = max(5, min(720, goalMinutesRequired))
        self.goalRewardMinutes = max(0, min(360, goalRewardMinutes))
        self.maxDailyLaunches = max(1, min(50, maxDailyLaunches))
        self.maxLaunchDurationMinutes = max(1, min(120, maxLaunchDurationMinutes))
        self.launchCooldownMinutes = max(0, min(360, launchCooldownMinutes))
        self.activeLaunchDeadline = activeLaunchDeadline
        self.launchCooldownDeadline = launchCooldownDeadline
        self.countdownMinutes = max(5, min(720, countdownMinutes))
        self.activeDeadline = activeDeadline
        self.scheduleDays = scheduleDays.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : scheduleDays
        self.startMinutes = max(0, min(1439, startMinutes))
        self.endMinutes = max(0, min(1439, endMinutes))
        self.blockApps = blockApps
        self.appListMode = appListMode
        self.apps = apps
        self.blockAction = blockAction
        self.webListMode = webListMode
        self.domains = FocusRules.normalizeDomains(domains)
        self.webBlockAction = webBlockAction
        self.customRedirectURL = customRedirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.motivationalMessage = motivationalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.blockedTitleKeywords = FocusRules.normalizeTitleKeywords(blockedTitleKeywords)
        self.blockedFolders = FolderRules.normalizeList(blockedFolders)
        self.protection = protection
        self.unlockChars = UnlockChallenge.clampedLength(unlockChars)
        self.stopDelayMinutes = max(1, min(120, stopDelayMinutes))
        self.guardSystemPanes = guardSystemPanes
        self.punisherEnabled = punisherEnabled
        self.dailyMicroPausesAllowed = max(0, min(10, dailyMicroPausesAllowed))
        self.microPauseMinutes = max(1, min(30, microPauseMinutes))
        self.activeMicroPauseDeadline = activeMicroPauseDeadline
        self.stopRequest = stopRequest
        self.punisher = punisher
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind, dailyLimitMinutes, countdownMinutes, activeDeadline
        case goalMinutesRequired, goalRewardMinutes
        case maxDailyLaunches, maxLaunchDurationMinutes, launchCooldownMinutes, activeLaunchDeadline, launchCooldownDeadline
        case scheduleDays, startMinutes, endMinutes
        case blockApps, appListMode, apps, blockAction
        case webListMode, domains, webBlockAction, customRedirectURL, motivationalMessage
        case blockedTitleKeywords, blockedFolders
        case protection, unlockChars, stopDelayMinutes, guardSystemPanes, punisherEnabled
        case dailyMicroPausesAllowed, microPauseMinutes, activeMicroPauseDeadline
        case stopRequest, punisher
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Regla general"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decodeIfPresent(GeneralRuleKind.self, forKey: .kind) ?? .dailyLimit
        dailyLimitMinutes = max(1, min(720, try c.decodeIfPresent(Int.self, forKey: .dailyLimitMinutes) ?? 20))
        goalMinutesRequired = max(5, min(720, try c.decodeIfPresent(Int.self, forKey: .goalMinutesRequired) ?? 60))
        goalRewardMinutes = max(0, min(360, try c.decodeIfPresent(Int.self, forKey: .goalRewardMinutes) ?? 0))
        maxDailyLaunches = max(1, min(50, try c.decodeIfPresent(Int.self, forKey: .maxDailyLaunches) ?? 5))
        maxLaunchDurationMinutes = max(1, min(120, try c.decodeIfPresent(Int.self, forKey: .maxLaunchDurationMinutes) ?? 5))
        launchCooldownMinutes = max(0, min(360, try c.decodeIfPresent(Int.self, forKey: .launchCooldownMinutes) ?? 30))
        activeLaunchDeadline = try c.decodeIfPresent(TrustedDeadline.self, forKey: .activeLaunchDeadline)
        launchCooldownDeadline = try c.decodeIfPresent(TrustedDeadline.self, forKey: .launchCooldownDeadline)
        countdownMinutes = max(5, min(720, try c.decodeIfPresent(Int.self, forKey: .countdownMinutes) ?? 60))
        activeDeadline = try c.decodeIfPresent(TrustedDeadline.self, forKey: .activeDeadline)
        let decodedDays = try c.decodeIfPresent(Set<Int>.self, forKey: .scheduleDays) ?? [1, 2, 3, 4, 5, 6, 7]
        scheduleDays = decodedDays.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : decodedDays
        startMinutes = max(0, min(1439, try c.decodeIfPresent(Int.self, forKey: .startMinutes) ?? (9 * 60)))
        endMinutes = max(0, min(1439, try c.decodeIfPresent(Int.self, forKey: .endMinutes) ?? (19 * 60)))
        blockApps = try c.decodeIfPresent(Bool.self, forKey: .blockApps) ?? false
        appListMode = try c.decodeIfPresent(AppListMode.self, forKey: .appListMode) ?? .blockListed
        apps = try c.decodeIfPresent([AllowedApp].self, forKey: .apps) ?? []
        blockAction = try c.decodeIfPresent(AppBlockAction.self, forKey: .blockAction) ?? .hide
        webListMode = try c.decodeIfPresent(WebListMode.self, forKey: .webListMode) ?? .blockListed
        domains = try c.decodeIfPresent(String.self, forKey: .domains) ?? ""
        webBlockAction = try c.decodeIfPresent(WebBlockAction.self, forKey: .webBlockAction) ?? .redirect
        customRedirectURL = (try c.decodeIfPresent(String.self, forKey: .customRedirectURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        motivationalMessage = (try c.decodeIfPresent(String.self, forKey: .motivationalMessage) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        blockedTitleKeywords = try c.decodeIfPresent(String.self, forKey: .blockedTitleKeywords) ?? ""
        blockedFolders = FolderRules.normalizeList(try c.decodeIfPresent([String].self, forKey: .blockedFolders) ?? [])
        protection = try c.decodeIfPresent(SessionProtection.self, forKey: .protection) ?? .challenge
        unlockChars = UnlockChallenge.clampedLength(try c.decodeIfPresent(Int.self, forKey: .unlockChars) ?? 24)
        stopDelayMinutes = max(1, min(120, try c.decodeIfPresent(Int.self, forKey: .stopDelayMinutes) ?? 5))
        guardSystemPanes = try c.decodeIfPresent(Bool.self, forKey: .guardSystemPanes) ?? true
        punisherEnabled = try c.decodeIfPresent(Bool.self, forKey: .punisherEnabled) ?? true
        dailyMicroPausesAllowed = max(0, min(10, try c.decodeIfPresent(Int.self, forKey: .dailyMicroPausesAllowed) ?? 2))
        microPauseMinutes = max(1, min(30, try c.decodeIfPresent(Int.self, forKey: .microPauseMinutes) ?? 5))
        activeMicroPauseDeadline = try c.decodeIfPresent(TrustedDeadline.self, forKey: .activeMicroPauseDeadline)
        stopRequest = try c.decodeIfPresent(StopRequest.self, forKey: .stopRequest)
        punisher = try c.decodeIfPresent(DistractionPunisher.self, forKey: .punisher) ?? DistractionPunisher()
    }

    public var hasTargets: Bool {
        (blockApps && !apps.isEmpty)
            || (webBlockAction != .warn && (webListMode == .blockAll || !FocusRules.parseDomains(domains).valid.isEmpty))
            || !FocusRules.parseTitleKeywords(blockedTitleKeywords).isEmpty
            || !blockedFolders.isEmpty
    }

    public var valid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let validApps = !blockApps || !apps.isEmpty
        let validSchedule = kind != .schedule || (!scheduleDays.isEmpty && startMinutes != endMinutes)
        return hasName && validApps && validSchedule && hasTargets
    }

    /// True when `now` falls inside the rule's recurring weekday schedule (including overnight windows).
    public func isScheduleActive(at now: Date, calendar: Calendar = .current) -> Bool {
        guard !scheduleDays.isEmpty, startMinutes != endMinutes else { return false }
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        let todayWeekday = comps.weekday ?? 2
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinutes < endMinutes {
            return scheduleDays.contains(todayWeekday) && minuteOfDay >= startMinutes && minuteOfDay < endMinutes
        } else {
            // Overnight window (e.g. 23:00 to 07:00): evening half belongs to today's weekday, morning half to yesterday's.
            if minuteOfDay >= startMinutes {
                return scheduleDays.contains(todayWeekday)
            } else if minuteOfDay < endMinutes {
                let yesterdayWeekday = todayWeekday == 1 ? 7 : (todayWeekday - 1)
                return scheduleDays.contains(yesterdayWeekday)
            }
            return false
        }
    }

    /// True while a temporary micro-pause is running on this rule.
    public func isMicroPaused(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        microPauseRemainingSeconds(at: now, continuous: continuous) > 0
    }

    public func microPauseRemainingSeconds(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        activeMicroPauseDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous) ?? 0
    }

    public mutating func startMicroPause(
        minutes: Int? = nil,
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        let chosen = max(1, min(30, minutes ?? microPauseMinutes))
        activeMicroPauseDeadline = TrustedDeadline(seconds: Double(chosen) * 60, wall: wall, continuous: continuous)
    }

    /// Daily budget in seconds when `kind == .dailyLimit`.
    public var dailyBudgetSeconds: TimeInterval {
        Double(max(1, dailyLimitMinutes)) * 60
    }

    /// Remaining seconds of today's allowance when `kind == .dailyLimit`.
    public func remainingQuotaSeconds(usedTodaySeconds: TimeInterval) -> TimeInterval {
        max(0, dailyBudgetSeconds - max(0, usedTodaySeconds))
    }

    public func remainingDailyBudgetSeconds(usedTodaySeconds: TimeInterval) -> TimeInterval {
        remainingQuotaSeconds(usedTodaySeconds: usedTodaySeconds)
    }

    /// Required focused work seconds today when `kind == .workGoal`.
    public var goalRequiredSeconds: TimeInterval {
        Double(max(5, goalMinutesRequired)) * 60
    }

    /// Earned leisure budget today in seconds when `kind == .workGoal`.
    /// Returns `nil` when `goalRewardMinutes == 0` and the work goal is met (meaning unlimited for the rest of today).
    /// Returns `0` while `workedTodaySeconds < goalRequiredSeconds`.
    public func earnedGoalBudgetSeconds(workedTodaySeconds: TimeInterval) -> TimeInterval? {
        guard workedTodaySeconds >= goalRequiredSeconds else { return 0 }
        guard goalRewardMinutes > 0 else { return nil }
        let blocks = max(1, Int(workedTodaySeconds / goalRequiredSeconds))
        return Double(blocks * goalRewardMinutes * 60)
    }

    /// Remaining reward seconds today when `kind == .workGoal` and `goalRewardMinutes > 0`.
    public func remainingGoalRewardSeconds(workedTodaySeconds: TimeInterval, usedTodaySeconds: TimeInterval) -> TimeInterval {
        guard let budget = earnedGoalBudgetSeconds(workedTodaySeconds: workedTodaySeconds) else { return 0 }
        return max(0, budget - max(0, usedTodaySeconds))
    }

    /// True while a `.launchLimit` rule is inside an active visit window (`activeLaunchDeadline`).
    public func isInLaunchVisit(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        launchVisitRemainingSeconds(at: now, continuous: continuous) > 0
    }

    public func isLaunchVisitActive(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        isInLaunchVisit(at: now, continuous: continuous)
    }

    public func launchVisitRemainingSeconds(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        activeLaunchDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous) ?? 0
    }

    /// True while a `.launchLimit` rule has finished its visit and is in its mandatory cooldown (`launchCooldownDeadline`).
    public func isInLaunchCooldown(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        guard !isInLaunchVisit(at: now, continuous: continuous) else { return false }
        return launchCooldownRemainingSeconds(at: now, continuous: continuous) > 0
    }

    public func launchCooldownRemainingSeconds(at now: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        guard let launchCooldownDeadline else { return 0 }
        let total = launchCooldownDeadline.remainingAfterPossibleReboot(wall: now, continuous: continuous)
        let visitLeft = launchVisitRemainingSeconds(at: now, continuous: continuous)
        return max(0, total - visitLeft)
    }

    /// Starts one allowed launch visit (`maxLaunchDurationMinutes`) and schedules the mandatory cooldown right after it.
    public mutating func beginLaunchVisit(
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        let visitSeconds = Double(max(1, maxLaunchDurationMinutes)) * 60
        activeLaunchDeadline = TrustedDeadline(seconds: visitSeconds, wall: wall, continuous: continuous)
        if launchCooldownMinutes > 0 {
            let cooldownSeconds = Double(launchCooldownMinutes) * 60
            launchCooldownDeadline = TrustedDeadline(seconds: visitSeconds + cooldownSeconds, wall: wall, continuous: continuous)
        } else {
            launchCooldownDeadline = nil
        }
    }

    /// Ends the current launch visit early and starts the mandatory cooldown immediately.
    public mutating func endLaunchVisitAndStartCooldown(
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        activeLaunchDeadline = nil
        if launchCooldownMinutes > 0 {
            launchCooldownDeadline = TrustedDeadline(seconds: Double(launchCooldownMinutes) * 60, wall: wall, continuous: continuous)
        } else {
            launchCooldownDeadline = nil
        }
    }

    /// True while a `.dailyLimit`, `.workGoal` (with finite reward) or `.launchLimit` rule is enabled and actively counting down usage/visit time.
    public func isTrackingQuota(
        at now: Date = Date(),
        usedTodaySeconds: TimeInterval,
        workedTodaySeconds: TimeInterval = 0,
        launchesToday: Int = 0,
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .dailyLimit:
            return usedTodaySeconds < dailyBudgetSeconds
        case .workGoal:
            guard let budget = earnedGoalBudgetSeconds(workedTodaySeconds: workedTodaySeconds) else { return false }
            return budget > 0 && usedTodaySeconds < budget
        case .launchLimit:
            return isInLaunchVisit(at: now, continuous: continuous) || (!isInLaunchCooldown(at: now, continuous: continuous) && launchesToday < maxDailyLaunches)
        case .countdown, .schedule, .alwaysOn:
            return false
        }
    }

    /// True when this rule is actively blocking right now.
    public func isEnforcing(
        at now: Date = Date(),
        usedTodaySeconds: TimeInterval = 0,
        workedTodaySeconds: TimeInterval = 0,
        launchesToday: Int = 0,
        continuous: Double = TrustedClock.continuousSeconds(),
        calendar: Calendar = .current
    ) -> Bool {
        guard enabled, hasTargets else { return false }
        if isMicroPaused(at: now, continuous: continuous) { return false }
        switch kind {
        case .alwaysOn:
            return true
        case .countdown:
            guard let activeDeadline else { return false }
            return activeDeadline.remainingAfterPossibleReboot(wall: now, continuous: continuous) > 0
        case .schedule:
            return isScheduleActive(at: now, calendar: calendar)
        case .dailyLimit:
            return usedTodaySeconds >= dailyBudgetSeconds
        case .workGoal:
            guard let budget = earnedGoalBudgetSeconds(workedTodaySeconds: workedTodaySeconds) else { return false }
            return usedTodaySeconds >= budget
        case .launchLimit:
            if isInLaunchVisit(at: now, continuous: continuous) { return false }
            if isInLaunchCooldown(at: now, continuous: continuous) { return true }
            return launchesToday >= maxDailyLaunches
        }
    }

    /// Seconds left until the current enforcement window ends (countdown end, cooldown end, schedule end, or midnight).
    public func remainingLockSeconds(
        at now: Date = Date(),
        usedTodaySeconds: TimeInterval = 0,
        workedTodaySeconds: TimeInterval = 0,
        launchesToday: Int = 0,
        continuous: Double = TrustedClock.continuousSeconds(),
        calendar: Calendar = .current
    ) -> TimeInterval {
        guard isEnforcing(
            at: now,
            usedTodaySeconds: usedTodaySeconds,
            workedTodaySeconds: workedTodaySeconds,
            launchesToday: launchesToday,
            continuous: continuous,
            calendar: calendar
        ) else {
            return 0
        }
        switch kind {
        case .countdown:
            return activeDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous) ?? 0
        case .launchLimit:
            let cooldownLeft = launchCooldownRemainingSeconds(at: now, continuous: continuous)
            if cooldownLeft > 0 && launchesToday < maxDailyLaunches {
                return cooldownLeft
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
                return max(60, tomorrow.timeIntervalSince(now))
            }
            return 3600
        case .schedule:
            let comps = calendar.dateComponents([.hour, .minute, .second], from: now)
            let nowSeconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
            let endSeconds = endMinutes * 60
            if endSeconds > nowSeconds {
                return TimeInterval(endSeconds - nowSeconds)
            } else {
                return TimeInterval(86400 - nowSeconds + endSeconds)
            }
        case .dailyLimit, .workGoal, .alwaysOn:
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
                return max(60, tomorrow.timeIntervalSince(now))
            }
            return 3600
        }
    }

    public mutating func startCountdown(
        minutes: Int? = nil,
        wall: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) {
        let chosen = max(1, min(1440, minutes ?? countdownMinutes))
        if minutes != nil { countdownMinutes = max(5, min(720, chosen)) }
        kind = .countdown
        enabled = true
        stopRequest = nil
        activeMicroPauseDeadline = nil
        activeDeadline = TrustedDeadline(seconds: Double(chosen) * 60, wall: wall, continuous: continuous)
    }

    @discardableResult
    public mutating func registerBlock(at continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        guard punisherEnabled else { return false }
        return punisher.register(at: continuous)
    }

    public func activeBlockAction(at continuous: Double = TrustedClock.continuousSeconds()) -> AppBlockAction {
        punisherEnabled && punisher.isActive(at: continuous) ? blockAction.escalated : blockAction
    }

    /// Formatted schedule string (`09:00–19:00`).
    public var scheduleLabel: String {
        String(
            format: "%02d:%02d–%02d:%02d",
            startMinutes / 60, startMinutes % 60,
            endMinutes / 60, endMinutes % 60
        )
    }

    /// Judges whether `proposed` (or `nil` for deletion) weakens an actively enforcing general rule.
    public static func loosening(
        current: GeneralBlockRule,
        proposed: GeneralBlockRule?,
        now: Date = Date(),
        continuous: Double = TrustedClock.continuousSeconds()
    ) -> String? {
        guard let proposed else { return "borrar la regla «\(current.name)»" }
        if current.enabled && !proposed.enabled { return "desactivar la regla «\(current.name)»" }
        if proposed.protection.strength < current.protection.strength {
            return "rebajar la protección de «\(current.name)»"
        }
        if proposed.unlockChars < current.unlockChars {
            return "acortar el código de «\(current.name)»"
        }
        if proposed.stopDelayMinutes < current.stopDelayMinutes {
            return "acortar la espera de «\(current.name)»"
        }
        if proposed.kind != current.kind {
            return "cambiar el modo de activación de «\(current.name)»"
        }
        if current.kind == .dailyLimit && proposed.dailyLimitMinutes > current.dailyLimitMinutes {
            return "ampliar el límite diario de «\(current.name)» una vez agotado"
        }
        if current.kind == .workGoal {
            if proposed.goalMinutesRequired < current.goalMinutesRequired {
                return "rebajar la meta de enfoque de «\(current.name)»"
            }
            if current.goalRewardMinutes > 0 && (proposed.goalRewardMinutes == 0 || proposed.goalRewardMinutes > current.goalRewardMinutes) {
                return "ampliar la recompensa de «\(current.name)»"
            }
        }
        if current.kind == .launchLimit {
            if proposed.maxDailyLaunches > current.maxDailyLaunches {
                return "aumentar el límite de aperturas de «\(current.name)»"
            }
            if proposed.maxLaunchDurationMinutes > current.maxLaunchDurationMinutes {
                return "alargar la duración por visita de «\(current.name)»"
            }
            if proposed.launchCooldownMinutes < current.launchCooldownMinutes {
                return "acortar el enfriamiento entre visitas de «\(current.name)»"
            }
        }
        if proposed.dailyMicroPausesAllowed > current.dailyMicroPausesAllowed || proposed.microPauseMinutes > current.microPauseMinutes {
            return "aumentar las micro-pausas de «\(current.name)» mientras está bloqueando"
        }
        if current.kind == .countdown,
           let curEnd = current.activeDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous),
           let nextEnd = proposed.activeDeadline?.remainingAfterPossibleReboot(wall: now, continuous: continuous),
           nextEnd + 5 < curEnd {
            return "acortar el temporizador de «\(current.name)»"
        }
        if current.kind == .schedule && (proposed.scheduleDays != current.scheduleDays || proposed.startMinutes != current.startMinutes || proposed.endMinutes != current.endMinutes) {
            return "cambiar el horario de «\(current.name)» mientras está activo"
        }
        if current.blockApps && !proposed.blockApps {
            return "quitar el bloqueo de apps en «\(current.name)»"
        }
        if current.blockApps {
            let curApps = Set(current.apps.map(\.id))
            let nextApps = Set(proposed.apps.map(\.id))
            if current.appListMode == .allowListed && (proposed.appListMode != .allowListed || !nextApps.subtracting(curApps).isEmpty) {
                return "abrir más apps en «\(current.name)»"
            }
            if current.appListMode == .blockListed && !curApps.isSubset(of: nextApps) {
                return "desbloquear apps en «\(current.name)»"
            }
        }
        if proposed.blockAction.strength < current.blockAction.strength {
            return "suavizar el cierre de apps en «\(current.name)»"
        }
        if proposed.webBlockAction.strength < current.webBlockAction.strength {
            return "suavizar el bloqueo web en «\(current.name)»"
        }
        if current.webBlockAction != .warn {
            let curDomains = Set(FocusRules.parseDomains(current.domains).valid)
            let nextDomains = Set(FocusRules.parseDomains(proposed.domains).valid)
            if current.webListMode == .blockAll && proposed.webListMode != .blockAll {
                return "abrir webs en «\(current.name)»"
            }
            if current.webListMode == .allowListed && (proposed.webListMode != .allowListed || !nextDomains.subtracting(curDomains).isEmpty) {
                return "permitir más webs en «\(current.name)»"
            }
            if current.webListMode == .blockListed && !curDomains.isSubset(of: nextDomains) {
                return "desbloquear webs en «\(current.name)»"
            }
        }
        let curKeywords = Set(FocusRules.parseTitleKeywords(current.blockedTitleKeywords).map { $0.lowercased() })
        let nextKeywords = Set(FocusRules.parseTitleKeywords(proposed.blockedTitleKeywords).map { $0.lowercased() })
        if !curKeywords.isSubset(of: nextKeywords) {
            return "quitar palabras bloqueadas en «\(current.name)»"
        }
        let curFolders = Set(FolderRules.normalizeList(current.blockedFolders).map { $0.lowercased() })
        let nextFolders = Set(FolderRules.normalizeList(proposed.blockedFolders).map { $0.lowercased() })
        if !curFolders.isSubset(of: nextFolders) {
            return "desbloquear carpetas en «\(current.name)»"
        }
        if current.guardSystemPanes && !proposed.guardSystemPanes {
            return "quitar la protección de Ajustes en «\(current.name)»"
        }
        if current.punisherEnabled && !proposed.punisherEnabled {
            return "quitar el endurecimiento en «\(current.name)»"
        }
        return nil
    }

    public static let defaults: [GeneralBlockRule] = [
        GeneralBlockRule(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222201")!,
            name: "Redes y vídeos cortos · 20 min al día",
            enabled: false,
            kind: .dailyLimit,
            dailyLimitMinutes: 20,
            webListMode: .blockListed,
            domains: "youtube.com/shorts, instagram.com, tiktok.com, x.com, reddit.com",
            webBlockAction: .redirect,
            motivationalMessage: "Tu atención vale más que el scroll infinito.",
            blockedTitleKeywords: "Shorts, Reels, TikTok",
            protection: .challenge
        ),
        GeneralBlockRule(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222202")!,
            name: "Noche sin pantallas de ocio",
            enabled: false,
            kind: .schedule,
            scheduleDays: [1, 2, 3, 4, 5, 6, 7],
            startMinutes: 22 * 60 + 30,
            endMinutes: 7 * 60 + 30,
            webListMode: .blockListed,
            domains: "youtube.com, netflix.com, twitch.tv, x.com, instagram.com, tiktok.com",
            webBlockAction: .redirect,
            motivationalMessage: "Hora de descansar: mañana rendirás el doble.",
            blockedTitleKeywords: "Netflix, Twitch, Shorts",
            protection: .delay
        ),
        GeneralBlockRule(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222203")!,
            name: "Primero 60 min de enfoque · luego ocio",
            enabled: false,
            kind: .workGoal,
            goalMinutesRequired: 60,
            goalRewardMinutes: 30,
            webListMode: .blockListed,
            domains: "youtube.com, reddit.com, twitch.tv, x.com",
            webBlockAction: .redirect,
            motivationalMessage: "Completa primero tu bloque de enfoque de hoy para desbloquear tu recompensa.",
            blockedTitleKeywords: "YouTube, Reddit, Twitch",
            protection: .challenge
        ),
        GeneralBlockRule(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222204")!,
            name: "X y Reddit · máx. 4 visitas de 5 min (30 min enfriamiento)",
            enabled: false,
            kind: .launchLimit,
            maxDailyLaunches: 4,
            maxLaunchDurationMinutes: 5,
            launchCooldownMinutes: 30,
            webListMode: .blockListed,
            domains: "x.com, twitter.com, reddit.com",
            webBlockAction: .redirect,
            motivationalMessage: "Evita abrir pestañas por impulso cada pocos minutos.",
            protection: .challenge
        )
    ]
}
