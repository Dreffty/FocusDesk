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

public enum Ratchet {
    /// Judges `proposed` against `current` for a session that is being enforced right now.
    /// `current` is what the session is running with; `proposed` is what the editor wants to save.
    public static func judge(current: FocusTask, proposed: FocusTask) -> RatchetVerdict {
        if current.strict && !proposed.strict {
            return .refused("No se puede quitar el bloqueo de apps mientras la sesión está en marcha.")
        }
        if proposed.protection.strength < current.protection.strength {
            return .refused("No se puede rebajar la protección («\(current.protection.label)») con la sesión en marcha.")
        }
        if proposed.minutes < current.minutes {
            return .refused("No se puede acortar la sesión en marcha. Alargarla sí.")
        }
        if proposed.unlockChars < current.unlockChars {
            return .refused("El código de desbloqueo no puede acortarse ahora (eran \(current.unlockChars) caracteres).")
        }
        if proposed.stopDelayMinutes < current.stopDelayMinutes {
            return .refused("La espera para parar no puede acortarse ahora (eran \(current.stopDelayMinutes) minutos).")
        }
        if proposed.blockAction.strength < current.blockAction.strength {
            return .refused("No se puede suavizar qué hace FocusDesk con las apps que distraen mientras la sesión corre.")
        }
        if proposed.webBlockAction.strength < current.webBlockAction.strength {
            return .refused("No se puede suavizar el bloqueo de webs mientras la sesión corre.")
        }
        // The app list is a list of what IS allowed: adding to it widens the hole, removing narrows it.
        let currentApps = Set(current.apps.map(\.id))
        let proposedApps = Set(proposed.apps.map(\.id))
        if !proposedApps.subtracting(currentApps).isEmpty {
            return .refused("No se pueden añadir apps permitidas con la sesión en marcha. Quitarlas sí.")
        }
        if current.strict && proposedApps.isEmpty {
            return .refused("Sin apps permitidas el bloqueo no tendría a dónde devolverte. Deja al menos una.")
        }
        // Same for the domains that stay open while websites are blocked.
        if current.webBlockAction != .warn {
            let currentDomains = Set(FocusRules.parseDomains(current.domains).valid)
            let proposedDomains = Set(FocusRules.parseDomains(proposed.domains).valid)
            if !proposedDomains.subtracting(currentDomains).isEmpty {
                return .refused("No se pueden añadir dominios permitidos mientras la sesión bloquea webs.")
            }
        }
        if current.guardSystemPanes && !proposed.guardSystemPanes {
            return .refused("La protección de «Privacidad y seguridad» y «Fecha y hora» no se quita con la sesión en marcha.")
        }
        if current.punisherEnabled && !proposed.punisherEnabled {
            return .refused("El endurecimiento tras varios intentos seguidos no se quita con la sesión en marcha.")
        }
        return .accepted
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
public struct StopRequest: Codable, Equatable, Sendable {
    public var reason: StopReason
    public var deadline: TrustedDeadline
    public var armedAt: Date

    public init(reason: StopReason, minutes: Int, wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) {
        self.reason = reason
        self.deadline = TrustedDeadline(seconds: Double(max(1, minutes)) * 60, wall: wall, continuous: continuous)
        self.armedAt = wall
    }

    public func remaining(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> TimeInterval {
        deadline.remainingAfterPossibleReboot(wall: wall, continuous: continuous)
    }

    public func ready(wall: Date = Date(), continuous: Double = TrustedClock.continuousSeconds()) -> Bool {
        remaining(wall: wall, continuous: continuous) <= 0
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
            if let pending, pending.reason == reason {
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
        appRunning: Bool,
        watcherAge: TimeInterval,
        recentRelaunches: Int,
        now: Date = Date()
    ) -> Bool {
        guard !appRunning, recentRelaunches < maxRelaunches, let session else { return false }
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
    /// Browsers FocusDesk can read and steer. The value is how AppleScript names the active tab's document.
    public enum BrowserKind: String, Codable, Sendable {
        case safari
        case chromium
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
        "org.chromium.Chromium": .chromium
    ]

    public static func browserKind(for bundleID: String) -> BrowserKind? { browsers[bundleID] }
    public static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    /// Browsers that do not let another app read the address of their tabs. Websites cannot be blocked in them,
    /// so a task that blocks websites says so instead of pretending.
    public static let unreadableBrowsers: Set<String> = [
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "org.torproject.torbrowser",
        "net.waterfox.waterfox",
        "com.kagi.kagimacOS",
        "com.duckduckgo.macos.browser"
    ]

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
